'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const zlib = require('zlib');
const crypto = require('crypto');
const installer = require('../npm/install');

// --- tiny tar writer (same as tar.test.js) ----------------------------------
function tarHeader(name, size, typeflag) {
  const h = Buffer.alloc(512, 0);
  h.write(name, 0, Math.min(name.length, 100), 'utf8');
  h.write('0000644\0', 100, 8, 'utf8');
  h.write('0000000\0', 108, 8, 'utf8');
  h.write('0000000\0', 116, 8, 'utf8');
  h.write(size.toString(8).padStart(11, '0') + '\0', 124, 12, 'utf8');
  h.write('00000000000\0', 136, 12, 'utf8');
  h[156] = typeflag.charCodeAt(0);
  h.write('ustar\0', 257, 6, 'utf8');
  h.write('00', 263, 2, 'utf8');
  h.write('        ', 148, 8, 'utf8');
  let sum = 0;
  for (const b of h) sum += b;
  h.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'utf8');
  return h;
}
function makeTgz(entries) {
  const parts = [];
  for (const e of entries) {
    const data = e.data ? Buffer.from(e.data) : Buffer.alloc(0);
    parts.push(tarHeader(e.name, data.length, e.dir ? '5' : '0'));
    if (data.length) {
      parts.push(data);
      const pad = (512 - (data.length % 512)) % 512;
      if (pad) parts.push(Buffer.alloc(pad, 0));
    }
  }
  parts.push(Buffer.alloc(1024, 0));
  return zlib.gzipSync(Buffer.concat(parts));
}

// --- fake registry -----------------------------------------------------------
function buildRegistry(base) {
  // packages: left-pad-mini@1.0.0 depends on nothing; dep-a@2.0.0 depends on dep-b ^1.0.0
  const depB = makeTgz([
    { name: 'package/package.json', data: JSON.stringify({ name: 'dep-b', version: '1.0.0', main: 'index.js' }) },
    { name: 'package/index.js', data: 'module.exports = "b1";\n' },
  ]);
  const depA = makeTgz([
    { name: 'package/package.json', data: JSON.stringify({ name: 'dep-a', version: '2.0.0', main: 'index.js', dependencies: { 'dep-b': '^1.0.0' } }) },
    { name: 'package/index.js', data: 'module.exports = require("dep-b") + "-a2";\n' },
  ]);
  const mini = makeTgz([
    { name: 'package/package.json', data: JSON.stringify({ name: 'mini', version: '1.0.0', main: 'index.js', bin: { mini: 'cli.js' } }) },
    { name: 'package/index.js', data: 'module.exports = 42;\n' },
    { name: 'package/cli.js', data: 'console.log("mini cli ok");\n' },
  ]);
  // Conflict set: A depends on C@1, B depends on C@2, root depends on C@2.
  const depC1 = makeTgz([
    { name: 'package/package.json', data: JSON.stringify({ name: 'dep-c', version: '1.0.0', main: 'index.js' }) },
    { name: 'package/index.js', data: 'module.exports = "c1";\n' },
  ]);
  const depC2 = makeTgz([
    { name: 'package/package.json', data: JSON.stringify({ name: 'dep-c', version: '2.0.0', main: 'index.js' }) },
    { name: 'package/index.js', data: 'module.exports = "c2";\n' },
  ]);
  const conA = makeTgz([
    { name: 'package/package.json', data: JSON.stringify({ name: 'con-a', version: '1.0.0', main: 'index.js', dependencies: { 'dep-c': '^1.0.0' } }) },
    { name: 'package/index.js', data: 'module.exports = require("dep-c");\n' },
  ]);
  const conB = makeTgz([
    { name: 'package/package.json', data: JSON.stringify({ name: 'con-b', version: '1.0.0', main: 'index.js', dependencies: { 'dep-c': '^2.0.0' } }) },
    { name: 'package/index.js', data: 'module.exports = require("dep-c");\n' },
  ]);
  const tarballs = {
    'dep-b': depB, 'dep-a': depA, mini,
    'dep-c@1.0.0': depC1, 'dep-c@2.0.0': depC2,
    'con-a': conA, 'con-b': conB,
  };
  const multiMeta = (name, versions) => ({
    name,
    'dist-tags': { latest: versions[versions.length - 1].version },
    versions: Object.fromEntries(versions.map((v) => {
      const key = versions.length > 1 ? `${name}@${v.version}` : name;
      return [v.version, {
        name, version: v.version,
        dependencies: v.dependencies,
        dist: {
          tarball: `${base}/${key}/-/${name}-${v.version}.tgz`,
          integrity: 'sha512-' + crypto.createHash('sha512').update(tarballs[key]).digest('base64'),
        },
      }];
    })),
  });
  const meta = (name, version, deps) => ({
    name,
    'dist-tags': { latest: version },
    versions: {
      [version]: {
        name, version,
        dependencies: deps,
        dist: {
          tarball: `${base}/${name}/-/${name}-${version}.tgz`,
          integrity: 'sha512-' + crypto.createHash('sha512').update(tarballs[name]).digest('base64'),
        },
      },
    },
  });
  const docs = {
    'dep-a': meta('dep-a', '2.0.0', { 'dep-b': '^1.0.0' }),
    'dep-b': meta('dep-b', '1.0.0', undefined),
    mini: meta('mini', '1.0.0', undefined),
    'dep-c': multiMeta('dep-c', [{ version: '1.0.0' }, { version: '2.0.0' }]),
    'con-a': multiMeta('con-a', [{ version: '1.0.0', dependencies: { 'dep-c': '^1.0.0' } }]),
    'con-b': multiMeta('con-b', [{ version: '1.0.0', dependencies: { 'dep-c': '^2.0.0' } }]),
  };
  return { docs, tarballs };
}

let server;
let base;
let registry;

before(async () => {
  await new Promise((resolve) => {
    server = http.createServer((req, res) => {
      const u = new URL(req.url, 'http://x');
      const parts = u.pathname.split('/').filter(Boolean);
      if (parts.length === 1 && registry.docs[parts[0]]) {
        res.setHeader('content-type', 'application/json');
        res.end(JSON.stringify(registry.docs[parts[0]]));
        return;
      }
      if (parts.length === 3 && parts[1] === '-' && registry.tarballs[parts[0]]) {
        res.setHeader('content-type', 'application/octet-stream');
        res.end(registry.tarballs[parts[0]]);
        return;
      }
      res.statusCode = 404;
      res.end('not found');
    });
    server.listen(0, '127.0.0.1', () => {
      base = `http://127.0.0.1:${server.address().port}`;
      registry = buildRegistry(base);
      process.env.NODEHOST_REGISTRY = base;
      resolve();
    });
  });
});

after(() => {
  delete process.env.NODEHOST_REGISTRY;
  if (server) server.close();
});

test('install from fake registry: transitive deps, .bin shim, lockfile', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-inst-'));
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({
    name: 'app', version: '1.0.0',
    dependencies: { 'dep-a': '^2.0.0', mini: '^1.0.0' },
  }, null, 2));
  let stdout = '', stderr = '';
  const code = await installer.install({
    cwd: dir, packages: [], onStdout: (d) => { stdout += d; }, onStderr: (d) => { stderr += d; },
  });
  assert.strictEqual(code, 0, stderr);
  assert.match(stdout, /added 3 packages/);
  // files exist
  assert.ok(fs.existsSync(path.join(dir, 'node_modules', 'dep-a', 'index.js')));
  assert.ok(fs.existsSync(path.join(dir, 'node_modules', 'dep-b', 'index.js')));
  assert.ok(fs.existsSync(path.join(dir, 'node_modules', 'mini', 'cli.js')));
  // require resolution works
  const depA = require(path.join(dir, 'node_modules', 'dep-a'));
  assert.strictEqual(depA, 'b1-a2');
  // bin shim
  const shim = fs.readFileSync(path.join(dir, 'node_modules', '.bin', 'mini'), 'utf8');
  assert.match(shim, /nodehost-bin/);
  // lockfile v3 written
  const lock = JSON.parse(fs.readFileSync(path.join(dir, 'package-lock.json'), 'utf8'));
  assert.strictEqual(lock.lockfileVersion, 3);
  assert.strictEqual(lock.packages['node_modules/dep-a'].version, '2.0.0');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('version conflict nests per-dependent (npm-style)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-conflict-'));
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({
    name: 'app-conflict', version: '1.0.0',
    dependencies: { 'con-a': '^1.0.0', 'con-b': '^1.0.0', 'dep-c': '^2.0.0' },
  }, null, 2));
  let stderr = '';
  const code = await installer.install({
    cwd: dir, packages: [], onStdout: () => {}, onStderr: (d) => { stderr += d; },
  });
  assert.strictEqual(code, 0, stderr);

  // Root gets C@2 (highest, and what the root asked for).
  const rootC = require(path.join(dir, 'node_modules', 'dep-c'));
  assert.strictEqual(rootC, 'c2');
  // con-a declared C@^1 — it must get 1.0.0 from its own node_modules.
  const aSees = require(path.join(dir, 'node_modules', 'con-a'));
  assert.strictEqual(aSees, 'c1', 'con-a must resolve dep-c@1 via nested node_modules');
  // con-b declared C@^2 — satisfied by the root copy.
  const bSees = require(path.join(dir, 'node_modules', 'con-b'));
  assert.strictEqual(bSees, 'c2');
  // The nested copy physically exists at the npm-style location.
  const nestedPkg = JSON.parse(fs.readFileSync(
    path.join(dir, 'node_modules', 'con-a', 'node_modules', 'dep-c', 'package.json'), 'utf8'));
  assert.strictEqual(nestedPkg.version, '1.0.0');
  // No legacy synthetic nest dir.
  assert.ok(!fs.existsSync(path.join(dir, 'node_modules', '.nodehost-nested')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('integrity mismatch fails', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-inst-'));
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({
    name: 'app2', dependencies: { 'dep-b': '^1.0.0' },
  }));
  // corrupt the registry tarball
  const orig = registry.tarballs['dep-b'];
  registry.tarballs['dep-b'] = Buffer.concat([orig.slice(0, -10), Buffer.from('CORRUPTED!')]);
  let stderr = '';
  const code = await installer.install({
    cwd: dir, packages: [], onStdout: () => {}, onStderr: (d) => { stderr += d; },
  }).catch(() => 1);
  registry.tarballs['dep-b'] = orig;
  assert.strictEqual(code, 1);
  fs.rmSync(dir, { recursive: true, force: true });
});
