'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const zlib = require('zlib');
const tar = require('../lib/tar');

// Minimal tar writer for tests (ustar, files and dirs only).
function tarHeader(name, size, typeflag, linkname) {
  const h = Buffer.alloc(512, 0);
  h.write(name, 0, Math.min(name.length, 100), 'utf8');
  h.write('0000644\0', 100, 8, 'utf8');           // mode
  h.write('0000000\0', 108, 8, 'utf8');           // uid
  h.write('0000000\0', 116, 8, 'utf8');           // gid
  h.write(size.toString(8).padStart(11, '0') + '\0', 124, 12, 'utf8');
  h.write('00000000000\0', 136, 12, 'utf8');      // mtime
  h[156] = typeflag.charCodeAt(0);
  if (linkname) h.write(linkname, 157, Math.min(linkname.length, 100), 'utf8');
  h.write('ustar\0', 257, 6, 'utf8');
  h.write('00', 263, 2, 'utf8');
  // checksum
  h.write('        ', 148, 8, 'utf8');
  let sum = 0;
  for (const b of h) sum += b;
  h.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'utf8');
  return h;
}

function makeTar(entries) {
  const parts = [];
  for (const e of entries) {
    const data = e.data ? Buffer.from(e.data) : Buffer.alloc(0);
    parts.push(tarHeader(e.name, data.length, e.dir ? '5' : e.symlink ? '2' : '0', e.linkname));
    if (data.length) {
      parts.push(data);
      const pad = (512 - (data.length % 512)) % 512;
      if (pad) parts.push(Buffer.alloc(pad, 0));
    }
  }
  parts.push(Buffer.alloc(1024, 0));
  return Buffer.concat(parts);
}

test('readTar reads files and dirs', () => {
  const buf = makeTar([
    { name: 'package/', dir: true },
    { name: 'package/index.js', data: 'module.exports = 1;\n' },
    { name: 'package/package.json', data: '{"name":"x"}' },
  ]);
  const entries = tar.readTar(buf);
  assert.strictEqual(entries.length, 3);
  assert.strictEqual(entries[0].type, 'dir');
  assert.strictEqual(entries[1].name, 'package/index.js');
  assert.strictEqual(entries[1].data.toString(), 'module.exports = 1;\n');
});

test('readTgz gunzips', () => {
  const buf = makeTar([{ name: 'package/a.txt', data: 'hello' }]);
  const gz = zlib.gzipSync(buf);
  const entries = tar.readTgz(gz);
  assert.strictEqual(entries.length, 1);
  assert.strictEqual(entries[0].data.toString(), 'hello');
});

test('extractTgz strips prefix and guards traversal', () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-tar-'));
  const buf = makeTar([
    { name: 'package/lib/x.js', data: '// x' },
    { name: 'package/../evil.txt', data: 'no' },
  ]);
  const n = tar.extractTgz(zlib.gzipSync(buf), dir, { strip: 1 });
  assert.strictEqual(n, 1);
  assert.strictEqual(fs.readFileSync(path.join(dir, 'lib/x.js'), 'utf8'), '// x');
  assert.ok(!fs.existsSync(path.join(dir, '..', 'evil.txt')));
  fs.rmSync(dir, { recursive: true, force: true });
});

// H3: symlinks whose target escapes the extraction root are skipped.
test('extractTgz skips symlink with absolute target', () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-tar-'));
  const buf = makeTar([
    { name: 'package/real.txt', data: 'ok' },
    { name: 'package/evil-link', symlink: true, linkname: '/etc/passwd' },
  ]);
  tar.extractTgz(zlib.gzipSync(buf), dir, { strip: 1 });
  assert.ok(fs.existsSync(path.join(dir, 'real.txt')));
  assert.ok(!fs.existsSync(path.join(dir, 'evil-link')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('extractTgz skips symlink with ../ escaping target', () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-tar-'));
  const buf = makeTar([
    { name: 'package/sub/real.txt', data: 'ok' },
    { name: 'package/sub/esc-link', symlink: true, linkname: '../../../outside.txt' },
  ]);
  tar.extractTgz(zlib.gzipSync(buf), dir, { strip: 1 });
  assert.ok(fs.existsSync(path.join(dir, 'sub', 'real.txt')));
  assert.ok(!fs.existsSync(path.join(dir, 'sub', 'esc-link')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('extractTgz keeps symlink that stays inside root', () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-tar-'));
  const buf = makeTar([
    { name: 'package/target.txt', data: 'contents' },
    { name: 'package/good-link', symlink: true, linkname: 'target.txt' },
  ]);
  tar.extractTgz(zlib.gzipSync(buf), dir, { strip: 1 });
  const linkPath = path.join(dir, 'good-link');
  assert.ok(fs.existsSync(linkPath) || fs.lstatSync(linkPath, { throwIfNoEntry: false })?.isSymbolicLink());
  fs.rmSync(dir, { recursive: true, force: true });
});
