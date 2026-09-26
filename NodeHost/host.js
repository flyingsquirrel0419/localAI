// NodeHost — in-process Node.js runtime host for the LocalAI iOS app.
//
// WHY: nodejs-mobile can call node_start() only ONCE per app process, forbids
// child_process spawn/exec and process.exit, and runs JIT-less. So the app
// starts this ONE long-lived host at launch; every "node x.js" / "npm ..."
// command from the agent is executed INSIDE this host in a worker_threads
// Worker (real Node 18 API, supported by nodejs-mobile).
//
// TRANSPORT: TCP server on 127.0.0.1. Port + auth token come from env
// LOCALAI_HOST_PORT / LOCALAI_HOST_TOKEN. If LOCALAI_HOST_PORT is unset/0,
// an ephemeral port is chosen and written (with the token) as JSON
// {"port":N,"token":"..."} to the file named by LOCALAI_HOST_PORTFILE.
//
// PROTOCOL: newline-delimited JSON, one request per line:
//   {"id":"<uuid>","token":"<token>","cmd":"node"|"npm"|"cancel"|"ping",
//    "args":[...], "cwd":"/abs/path", "env":{"K":"V"}, "timeoutMs":30000}
// Responses, one per line:
//   {"id","type":"stdout","data":"..."}        streamed output
//   {"id","type":"stderr","data":"..."}
//   {"id","type":"exit","code":0,"durationMs":123}
//   {"id","type":"error","message":"..."}      protocol-level failure
//   {"id","type":"pong"}                       reply to "ping"
// "cancel" takes {"id":"<target-id>","token":...} (its own id is ignored).
//
// EXIT CODES: process.exit(n) inside a script ends only its worker with code n.
// Cancellation -> 130 (SIGINT convention), timeout -> 124 (timeout(1)).
//
// LIMITATIONS:
// - Workers cannot chdir(); process.cwd() is patched to report the request's
//   cwd and scripts are loaded by absolute path, so relative-path fs calls made
//   through patched path resolution work, but anything capturing the real
//   process cwd (rare) will see the host cwd.
// - child_process is unavailable inside workers (clear thrown error), EXCEPT
//   `node <file.js>` / spawn of process.execPath with a JS file, which is
//   emulated with another Worker (best effort: stdio pipes, exit/close events;
//   no signals, no shell:true).
// - npm install never runs install scripts; packages needing native addons
//   (binding.gyp / gypfile) are reported with the exact user-facing message and
//   installed as-is (they will fail at require time if they truly need a
//   prebuilt binary).
// - No symlinks for node_modules/.bin: small JS shim files are written instead
//   and resolved by the npm-run bin resolver.
'use strict';

const net = require('net');
const fs = require('fs');
const path = require('path');
const { runNode } = require('./lib/runner');
const npmCli = require('./npm/cli');

const PORT = parseInt(process.env.LOCALAI_HOST_PORT || '0', 10);
const TOKEN = process.env.LOCALAI_HOST_TOKEN || '';
const PORTFILE = process.env.LOCALAI_HOST_PORTFILE || '';

/** @type {Map<string, {cancel: () => void}>} live command id -> handle */
const active = new Map();

function send(stream, obj) {
  if (stream.destroyed) return;
  stream.write(JSON.stringify(obj) + '\n');
}

/** Constant-time string compare. Returns false for length-mismatched inputs. */
function tokensEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  if (!a.length) return false; // empty token is never valid
  const ba = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  return require('crypto').timingSafeEqual(ba, bb);
}

function makeEmitter(stream, id) {
  return {
    stdout: (data) => send(stream, { id, type: 'stdout', data }),
    stderr: (data) => send(stream, { id, type: 'stderr', data }),
  };
}

async function handleCommand(req, stream) {
  const { id, cmd, args = [], cwd, env = {}, timeoutMs } = req;
  const emit = makeEmitter(stream, id);
  const started = Date.now();
  const finish = (code) => {
    active.delete(id);
    send(stream, { id, type: 'exit', code, durationMs: Date.now() - started });
  };
  const fail = (message) => {
    active.delete(id);
    send(stream, { id, type: 'error', message });
  };

  if (cmd === 'ping') {
    send(stream, { id, type: 'pong' });
    return;
  }
  if (cmd === 'cancel') {
    const target = active.get(req.target || req.cancelId || args[0]);
    if (target) {
      target.cancel();
      send(stream, { id, type: 'exit', code: 0, durationMs: 0 });
    } else {
      fail('no active command with that id');
    }
    return;
  }

  if (!cwd || typeof cwd !== 'string') {
    fail('cwd is required');
    return;
  }
  try {
    fs.accessSync(cwd, fs.constants.R_OK);
  } catch {
    fail(`cwd does not exist: ${cwd}`);
    return;
  }

  if (cmd === 'node') {
    if (!args.length) {
      fail('node: missing script argument');
      return;
    }
    const handle = runNode({
      script: args[0],
      scriptArgs: args.slice(1),
      cwd,
      env,
      timeoutMs,
      onStdout: emit.stdout,
      onStderr: emit.stderr,
      onExit: finish,
    });
    active.set(id, handle);
    return;
  }

  if (cmd === 'npm') {
    try {
      const handle = npmCli.run({
        args, cwd, env, timeoutMs,
        onStdout: emit.stdout,
        onStderr: emit.stderr,
        onExit: finish,
      });
      // npm install resolves asynchronously; run() returns a handle whose
      // cancel is safe to call at any time.
      active.set(id, handle);
    } catch (err) {
      fail(String((err && err.message) || err));
    }
    return;
  }

  fail(`unknown cmd: ${cmd}`);
}

function onConnection(stream) {
  stream.setEncoding('utf8');
  let buf = '';
  stream.on('data', (chunk) => {
    buf += chunk;
    let idx;
    while ((idx = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      if (!line.trim()) continue;
      let req;
      try {
        req = JSON.parse(line);
      } catch {
        send(stream, { id: null, type: 'error', message: 'invalid JSON' });
        continue;
      }
      // Constant-time compare; an empty TOKEN (misconfiguration) means we
      // refuse ALL requests rather than silently running unauthenticated.
      if (!tokensEqual(req.token, TOKEN)) {
        send(stream, { id: req.id || null, type: 'error', message: 'unauthorized' });
        continue;
      }
      handleCommand(req, stream).catch((err) => {
        send(stream, { id: req.id || null, type: 'error', message: String((err && err.message) || err) });
      });
    }
  });
  // Half-open sockets from a dying app are fine; just drop errors.
  stream.on('error', () => {});
}

function main() {
  const server = net.createServer(onConnection);
  server.on('error', (err) => {
    process.stderr.write(`NodeHost listen error: ${err.message}\n`);
    // Never exit: wait for the app to kill us.
  });
  server.listen(PORT, '127.0.0.1', () => {
    const addr = server.address();
    if (PORTFILE) {
      try {
        fs.writeFileSync(PORTFILE, JSON.stringify({ port: addr.port, token: TOKEN }));
      } catch (err) {
        process.stderr.write(`NodeHost: could not write portfile: ${err.message}\n`);
      }
    }
    // Machine-readable ready line for the Swift side / tests.
    process.stdout.write(`NODEHOST_READY ${addr.port}\n`);
  });
  // Swallow uncaught errors from a single bad command so the host survives.
  process.on('uncaughtException', (err) => {
    process.stderr.write(`NodeHost uncaughtException: ${err && err.stack || err}\n`);
  });
  process.on('unhandledRejection', (err) => {
    process.stderr.write(`NodeHost unhandledRejection: ${err && err.stack || err}\n`);
  });
}

if (require.main === module) main();
module.exports = { main };
