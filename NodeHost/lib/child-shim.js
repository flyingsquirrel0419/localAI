'use strict';
// child_process shim for the mobile runtime.
//
// Every method throws a clear error — EXCEPT spawn/execFile/fork targeting
// `node <file.js>` or process.execPath with a JS file, which is emulated with
// a nested worker_threads Worker. Best effort: piped stdio streams, 'exit' and
// 'close' events, kill(). Not supported: shell:true, signals, detached, IPC.
const { EventEmitter } = require('events');
const { PassThrough } = require('stream');
const path = require('path');
const { Worker } = require('worker_threads');

const NOT_AVAILABLE = (method) =>
  new Error(`child_process is not available in the mobile runtime (${method})`);

function install(Module, context) {
  const realLoad = Module._load;
  Module._load = function (request, parent, isMain) {
    if (request === 'child_process' || request === 'node:child_process') {
      return makeChildProcessModule(context);
    }
    return realLoad.apply(this, arguments);
  };
}

function looksLikeNode(cmd, execPath) {
  if (typeof cmd !== 'string') return false;
  if (cmd === execPath) return true;
  const base = path.basename(cmd);
  return base === 'node' || base === 'node.exe';
}

function extractScript(args) {
  if (!Array.isArray(args)) args = [];
  // Skip common node flags before the script (very small subset).
  const skipWithValue = new Set(['-r', '--require', '--loader', '-e', '--eval', '-p', '--print']);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (skipWithValue.has(a)) { i++; continue; }
    if (a.startsWith('-')) continue;
    return { script: a, rest: args.slice(i + 1) };
  }
  return null;
}

function emulatedSpawn(cmd, args, options, context, method) {
  if (!looksLikeNode(cmd, context.execPath)) throw NOT_AVAILABLE(method);
  const found = extractScript(args);
  if (!found || !found.script.endsWith('.js')) throw NOT_AVAILABLE(method);
  const opts = options || {};
  const cwd = typeof opts.cwd === 'string' ? opts.cwd : context.cwd;
  const script = path.isAbsolute(found.script) ? found.script : path.resolve(cwd, found.script);

  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.stdio = [child.stdin, child.stdout, child.stderr];
  child.pid = 0;
  child.killed = false;
  child.exitCode = null;
  child.signalCode = null;
  child.spawnargs = [cmd, ...args];

  const worker = new Worker(path.join(__dirname, 'worker.js'), {
    workerData: {
      script,
      args: found.rest,
      cwd,
      env: Object.assign({}, process.env, opts.env || {}),
      execPath: context.execPath,
    },
    stdout: true,
    stderr: true,
    stdin: true,
  });
  worker.stdout.on('data', (d) => child.stdout.emit('data', d));
  worker.stderr.on('data', (d) => child.stderr.emit('data', d));
  worker.stdout.on('end', () => child.stdout.emit('end'));
  worker.stderr.on('end', () => child.stderr.emit('end'));
  child.stdin.on('data', (d) => worker.stdin.write(d));
  child.stdin.on('end', () => worker.stdin.end());
  worker.on('error', (err) => child.emit('error', err));
  worker.on('exit', (code) => {
    child.exitCode = code;
    child.emit('exit', code, null);
    child.emit('close', code, null);
  });
  child.kill = () => {
    child.killed = true;
    worker.terminate();
    return true;
  };
  child.unref = () => {};
  child.ref = () => {};
  queueMicrotask(() => child.emit('spawn'));
  return child;
}

function makeChildProcessModule(context) {
  return {
    spawn(cmd, args, options) {
      return emulatedSpawn(cmd, args, options, context, 'spawn');
    },
    execFile(cmd, args, options, callback) {
      if (typeof options === 'function') { callback = options; options = undefined; }
      const child = emulatedSpawn(cmd, args, options, context, 'execFile');
      let out = '', err = '';
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { err += d; });
      child.on('error', (e) => callback && callback(e, out, err));
      child.on('close', (code) => {
        if (!callback) return;
        if (code === 0) callback(null, out, err);
        else {
          const e = new Error(`Command failed: ${cmd} ${(args || []).join(' ')}`);
          e.code = code;
          callback(e, out, err);
        }
      });
      return child;
    },
    fork(modulePath, args, options) {
      return emulatedSpawn(context.execPath, [modulePath, ...(args || [])], options, context, 'fork');
    },
    exec() { throw NOT_AVAILABLE('exec'); },
    execSync() { throw NOT_AVAILABLE('execSync'); },
    execFileSync() { throw NOT_AVAILABLE('execFileSync'); },
    spawnSync() { throw NOT_AVAILABLE('spawnSync'); },
  };
}

module.exports = { install };
