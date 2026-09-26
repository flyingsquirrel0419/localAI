'use strict';
// Real-network test: npm install from registry.npmjs.org.
// Only runs when NODEHOST_NETWORK_TESTS=1.
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ENABLED = process.env.NODEHOST_NETWORK_TESTS === '1';

test('npm install is-number@7.0.0 and ms@2.1.3 from real registry', { skip: !ENABLED }, async () => {
  delete process.env.NODEHOST_REGISTRY; // force real registry
  const installer = require('../npm/install');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-net-'));
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({
    name: 'net-test', version: '1.0.0',
    dependencies: { 'is-number': '7.0.0', ms: '2.1.3' },
  }));
  let stdout = '', stderr = '';
  const code = await installer.install({
    cwd: dir, packages: [],
    onStdout: (d) => { stdout += d; }, onStderr: (d) => { stderr += d; },
  });
  assert.strictEqual(code, 0, 'install failed: ' + stderr);
  assert.match(stdout, /added 2 packages in [\d.]+s/);
  const isNumber = require(path.join(dir, 'node_modules', 'is-number'));
  assert.strictEqual(isNumber(7), true);
  assert.strictEqual(isNumber('x'), false);
  const ms = require(path.join(dir, 'node_modules', 'ms'));
  assert.strictEqual(ms('2 days'), 172800000);
  const lock = JSON.parse(fs.readFileSync(path.join(dir, 'package-lock.json'), 'utf8'));
  assert.strictEqual(lock.packages['node_modules/is-number'].version, '7.0.0');
  fs.rmSync(dir, { recursive: true, force: true });
});
