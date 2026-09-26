'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HOST = path.join(__dirname, '..', 'host.js');
const TOKEN = 'test-token-123';

let proc;
let port;

function connect() {
  return net.createConnection({ port, host: '127.0.0.1' });
}

function makeClient() {
  const stream = connect();
  stream.setEncoding('utf8');
  let buf = '';
  const waiters = [];
  const messages = [];
  stream.on('data', (chunk) => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line.trim()) continue;
      const msg = JSON.parse(line);
      messages.push(msg);
      for (const w of [...waiters]) {
        if (w.pred(msg)) {
          waiters.splice(waiters.indexOf(w), 1);
          w.resolve(msg);
        }
      }
    }
  });
  return {
    stream,
    messages,
    send(obj) { stream.write(JSON.stringify(obj) + '\n'); },
    waitFor(pred, timeoutMs = 10000) {
      // check already-received
      for (const m of messages) if (pred(m)) return Promise.resolve(m);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('waitFor timeout')), timeoutMs);
        waiters.push({ pred, resolve: (m) => { clearTimeout(t); resolve(m); } });
      });
    },
    close() { stream.destroy(); },
  };
}

async function runToExit(client, req) {
  client.send(req);
  const msgs = [];
  const sub = setInterval(() => {}, 1000);
  clearInterval(sub);
  const exit = await client.waitFor((m) => m.id === req.id && (m.type === 'exit' || m.type === 'error'));
  const io = client.messages.filter((m) => m.id === req.id && (m.type === 'stdout' || m.type === 'stderr'));
  return { exit, io };
}

before(async () => {
  proc = spawn(process.execPath, [HOST], {
    env: { ...process.env, LOCALAI_HOST_PORT: '0', LOCALAI_HOST_TOKEN: TOKEN, LOCALAI_HOST_PORTFILE: '' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  port = await new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('host did not become ready: ' + out)), 10000);
    proc.stdout.on('data', (d) => {
      out += d.toString();
      const m = out.match(/NODEHOST_READY (\d+)/);
      if (m) { clearTimeout(t); resolve(+m[1]); }
    });
    proc.stderr.on('data', (d) => { out += d.toString(); });
  });
});

after(() => {
  if (proc) proc.kill();
});

test('ping', async () => {
  const c = makeClient();
  c.send({ id: 'p1', token: TOKEN, cmd: 'ping' });
  const msg = await c.waitFor((m) => m.id === 'p1' && m.type === 'pong');
  assert.ok(msg);
  c.close();
});

test('bad token rejected', async () => {
  const c = makeClient();
  c.send({ id: 'x1', token: 'wrong', cmd: 'ping' });
  const msg = await c.waitFor((m) => m.id === 'x1' && m.type === 'error');
  assert.match(msg.message, /unauthorized/);
  c.close();
});

test('node runs a script and streams output', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.writeFileSync(path.join(dir, 'hello.js'), 'console.log("hello from worker"); console.error("oops");');
  const c = makeClient();
  const { exit, io } = await runToExit(c, {
    id: 'n1', token: TOKEN, cmd: 'node', args: ['hello.js'], cwd: dir,
  });
  assert.strictEqual(exit.type, 'exit');
  assert.strictEqual(exit.code, 0);
  const stdout = io.filter((m) => m.type === 'stdout').map((m) => m.data).join('');
  const stderr = io.filter((m) => m.type === 'stderr').map((m) => m.data).join('');
  assert.match(stdout, /hello from worker/);
  assert.match(stderr, /oops/);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('process.exit code propagates', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.writeFileSync(path.join(dir, 'fail.js'), 'process.exit(3);');
  const c = makeClient();
  const { exit } = await runToExit(c, { id: 'n2', token: TOKEN, cmd: 'node', args: ['fail.js'], cwd: dir });
  assert.strictEqual(exit.code, 3);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('timeout terminates with 124', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.writeFileSync(path.join(dir, 'spin.js'), 'setInterval(() => {}, 1000);');
  const c = makeClient();
  const { exit } = await runToExit(c, {
    id: 'n3', token: TOKEN, cmd: 'node', args: ['spin.js'], cwd: dir, timeoutMs: 500,
  });
  assert.strictEqual(exit.code, 124);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('cancel terminates with 130', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.writeFileSync(path.join(dir, 'spin.js'), 'setInterval(() => {}, 1000);');
  const c = makeClient();
  c.send({ id: 'n4', token: TOKEN, cmd: 'node', args: ['spin.js'], cwd: dir });
  // give it a moment to start, then cancel
  await new Promise((r) => setTimeout(r, 200));
  c.send({ id: 'c4', token: TOKEN, cmd: 'cancel', args: ['n4'] });
  const exit = await c.waitFor((m) => m.id === 'n4' && m.type === 'exit');
  assert.strictEqual(exit.code, 130);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('child_process shim throws for non-node spawns', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.writeFileSync(path.join(dir, 'usespawn.js'), `
    try {
      require('child_process').execSync('ls');
      console.log('NO ERROR');
    } catch (e) {
      console.log('ERR: ' + e.message);
    }
  `);
  const c = makeClient();
  const { exit, io } = await runToExit(c, { id: 'n5', token: TOKEN, cmd: 'node', args: ['usespawn.js'], cwd: dir });
  assert.strictEqual(exit.code, 0);
  const stdout = io.filter((m) => m.type === 'stdout').map((m) => m.data).join('');
  assert.match(stdout, /ERR: child_process is not available in the mobile runtime \(execSync\)/);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('child_process spawn of node file is emulated', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.writeFileSync(path.join(dir, 'child.js'), 'console.log("child says hi");');
  fs.writeFileSync(path.join(dir, 'parent.js'), `
    const { spawn } = require('child_process');
    const c = spawn(process.execPath, ['child.js']);
    c.stdout.on('data', d => process.stdout.write('GOT:' + d));
    c.on('close', (code) => { console.log('child closed ' + code); });
  `);
  const c = makeClient();
  const { exit, io } = await runToExit(c, { id: 'n6', token: TOKEN, cmd: 'node', args: ['parent.js'], cwd: dir });
  assert.strictEqual(exit.code, 0);
  const stdout = io.filter((m) => m.type === 'stdout').map((m) => m.data).join('');
  assert.match(stdout, /GOT:child says hi/);
  assert.match(stdout, /child closed 0/);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('npm run with pre/post, && and echo', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({
    name: 'demo',
    scripts: {
      prebuild: 'echo pre-step',
      build: 'node -e-ignored || echo recovered && echo post-and',
      postbuild: 'echo done-all',
    },
  }));
  // node -e-ignored will fail (file not found) -> || runs echo recovered -> && echo post-and
  const c = makeClient();
  const { exit, io } = await runToExit(c, {
    id: 'r1', token: TOKEN, cmd: 'npm', args: ['run', 'build'], cwd: dir,
  });
  const stdout = io.filter((m) => m.type === 'stdout').map((m) => m.data).join('');
  assert.match(stdout, /pre-step/);
  assert.match(stdout, /recovered/);
  assert.match(stdout, /post-and/);
  assert.match(stdout, /done-all/);
  assert.strictEqual(exit.code, 0);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('npm run resolves .bin shim', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.mkdirSync(path.join(dir, 'node_modules', '.bin'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'node_modules', 'tool'), { recursive: true });
  const toolMain = path.join(dir, 'node_modules', 'tool', 'cli.js');
  fs.writeFileSync(toolMain, 'console.log("tool ran with " + process.argv.slice(2).join(","));');
  fs.writeFileSync(path.join(dir, 'node_modules', 'tool', 'package.json'),
    JSON.stringify({ name: 'tool', version: '1.0.0', bin: { tool: 'cli.js' } }));
  fs.writeFileSync(path.join(dir, 'node_modules', '.bin', 'tool'),
    `// nodehost-bin ${toolMain}\nrequire(${JSON.stringify(toolMain)});\n`);
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({
    name: 'demo2', scripts: { go: 'tool a b' },
  }));
  const c = makeClient();
  const { exit, io } = await runToExit(c, { id: 'r2', token: TOKEN, cmd: 'npm', args: ['run', 'go'], cwd: dir });
  const stdout = io.filter((m) => m.type === 'stdout').map((m) => m.data).join('');
  assert.match(stdout, /tool ran with a,b/);
  assert.strictEqual(exit.code, 0);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('npm --version', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-e2e-'));
  fs.writeFileSync(path.join(dir, 'package.json'), '{}');
  const c = makeClient();
  const { exit, io } = await runToExit(c, { id: 'v1', token: TOKEN, cmd: 'npm', args: ['--version'], cwd: dir });
  assert.strictEqual(exit.code, 0);
  const stdout = io.filter((m) => m.type === 'stdout').map((m) => m.data).join('');
  assert.match(stdout, /nodehost/);
  c.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('buggy fixture: npm test fails with the seeded bug', async () => {
  const dir = path.join(__dirname, 'fixtures', 'buggy-project');
  const c = makeClient();
  const { exit, io } = await runToExit(c, { id: 'b1', token: TOKEN, cmd: 'npm', args: ['test'], cwd: dir });
  assert.strictEqual(exit.code, 1);
  const stdout = io.filter((m) => m.type === 'stdout').map((m) => m.data).join('');
  assert.match(stdout, /FAIL - sum\(1, 2\)/);
  c.close();
});
