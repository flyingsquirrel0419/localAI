'use strict';
// H2: npm-run builtin command confinement — rm/cp/mkdir must not touch paths
// outside the script cwd, and rm must never remove the cwd itself.
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { runScript } = require('../npm/run');

function runNpmScript(cwd, name) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    runScript({
      name,
      cwd,
      env: {},
      onStdout: (s) => { stdout += s; },
      onStderr: (s) => { stderr += s; },
      onExit: (code) => resolve({ code, stdout, stderr }),
      timeoutMs: 5000,
    });
  });
}

function makeProject(script) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-run-'));
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({
    name: 'confine-test', scripts: { go: script },
  }));
  return dir;
}

test('rm refuses to remove outside cwd', async () => {
  const dir = makeProject('rm -rf ../sibling');
  const { code, stderr } = await runNpmScript(dir, 'go');
  assert.strictEqual(code, 1);
  assert.match(stderr, /refusing to remove outside cwd/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('rm refuses to remove the working directory itself', async () => {
  const dir = makeProject('rm -rf .');
  const { code, stderr } = await runNpmScript(dir, 'go');
  assert.strictEqual(code, 1);
  assert.match(stderr, /refusing to remove the working directory/);
  assert.ok(fs.existsSync(path.join(dir, 'package.json')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('rm removes an inside path', async () => {
  const dir = makeProject('rm -rf sub');
  fs.mkdirSync(path.join(dir, 'sub'));
  fs.writeFileSync(path.join(dir, 'sub', 'f.txt'), 'x');
  const { code } = await runNpmScript(dir, 'go');
  assert.strictEqual(code, 0);
  assert.ok(!fs.existsSync(path.join(dir, 'sub')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('mkdir refuses to create outside cwd', async () => {
  const dir = makeProject('mkdir ../escape');
  const { code, stderr } = await runNpmScript(dir, 'go');
  assert.strictEqual(code, 1);
  assert.match(stderr, /refusing to create outside cwd/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('cp refuses to read from outside cwd', async () => {
  const dir = makeProject('cp ../secret.txt copy.txt');
  const { code, stderr } = await runNpmScript(dir, 'go');
  assert.strictEqual(code, 1);
  assert.match(stderr, /refusing to read outside cwd/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('cp refuses to write outside cwd', async () => {
  const dir = makeProject('cp inside.txt ../out.txt');
  fs.writeFileSync(path.join(dir, 'inside.txt'), 'data');
  const { code, stderr } = await runNpmScript(dir, 'go');
  assert.strictEqual(code, 1);
  assert.match(stderr, /refusing to write outside cwd/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('cp copies within cwd', async () => {
  const dir = makeProject('cp inside.txt copy.txt');
  fs.writeFileSync(path.join(dir, 'inside.txt'), 'data');
  const { code } = await runNpmScript(dir, 'go');
  assert.strictEqual(code, 0);
  assert.strictEqual(fs.readFileSync(path.join(dir, 'copy.txt'), 'utf8'), 'data');
  fs.rmSync(dir, { recursive: true, force: true });
});
