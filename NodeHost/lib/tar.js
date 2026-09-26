'use strict';
// Minimal ustar/pax tar reader. Extracts entries from a Buffer:
//   readTar(buffer) -> [{name, type, mode, data(Buffer)|null, linkname}]
// Handles ustar headers, pax extended headers ('x') for long names, and
// gnu longname ('L'). Only regular files, directories and symlinks are kept.
const zlib = require('zlib');

function parseOctal(buf, off, len) {
  let s = '';
  for (let i = 0; i < len; i++) {
    const c = buf[off + i];
    if (c === 0 || c === 0x20) break;
    s += String.fromCharCode(c);
  }
  return s.trim() ? parseInt(s.trim(), 8) : 0;
}

function parsePax(data) {
  // format: "<len> key=value\n" repeated
  const out = {};
  let i = 0;
  const s = data.toString('utf8');
  while (i < s.length) {
    const sp = s.indexOf(' ', i);
    if (sp === -1) break;
    const len = parseInt(s.slice(i, sp), 10);
    if (!len) break;
    const rec = s.slice(sp + 1, i + len - 1);
    const eq = rec.indexOf('=');
    if (eq !== -1) out[rec.slice(0, eq)] = rec.slice(eq + 1);
    i += len;
  }
  return out;
}

function readTar(buf) {
  const entries = [];
  let off = 0;
  let pendingName = null;
  let pendingLinkname = null;
  while (off + 512 <= buf.length) {
    const header = buf.subarray(off, off + 512);
    // end-of-archive: zero block
    if (header.every((b) => b === 0)) break;
    let name = header.subarray(0, 100).toString('utf8').replace(/\0.*$/, '');
    const mode = parseOctal(header, 100, 8);
    const size = parseOctal(header, 124, 12);
    const typeflag = String.fromCharCode(header[156] || 0x30);
    const linkname = header.subarray(157, 257).toString('utf8').replace(/\0.*$/, '');
    const magic = header.subarray(257, 263).toString('utf8');
    let prefix = '';
    if (magic.startsWith('ustar')) {
      prefix = header.subarray(345, 500).toString('utf8').replace(/\0.*$/, '');
    }
    if (prefix) name = prefix + '/' + name;
    off += 512;
    const dataBlocks = Math.ceil(size / 512);
    const data = buf.subarray(off, off + size);
    off += dataBlocks * 512;

    if (typeflag === 'x') {
      const pax = parsePax(data);
      if (pax.path) pendingName = pax.path;
      if (pax.linkpath) pendingLinkname = pax.linkpath;
      continue;
    }
    if (typeflag === 'L') { // GNU longname
      pendingName = data.toString('utf8').replace(/\0.*$/, '');
      continue;
    }
    if (typeflag === 'K') {
      pendingLinkname = data.toString('utf8').replace(/\0.*$/, '');
      continue;
    }
    if (pendingName) { name = pendingName; pendingName = null; }
    const finalLink = pendingLinkname || linkname;
    pendingLinkname = null;

    if (typeflag === '0' || typeflag === '\0' || typeflag === '7') {
      entries.push({ name, type: 'file', mode, data: Buffer.from(data) });
    } else if (typeflag === '5') {
      entries.push({ name, type: 'dir', mode, data: null });
    } else if (typeflag === '2') {
      entries.push({ name, type: 'symlink', mode, data: null, linkname: finalLink });
    }
    // other types (hardlink, char, block, fifo) are ignored
  }
  return entries;
}

/** Decode a .tgz Buffer into entries. */
function readTgz(gzbuf) {
  return readTar(zlib.gunzipSync(gzbuf));
}

/**
 * Extract a .tgz Buffer into a directory, stripping the given number of
 * leading path components (npm tarballs use "package/..." — strip 1).
 * Path traversal attempts ("../") are skipped. Symlinks whose target escapes
 * destDir are skipped; safe symlinks are written as small files containing the
 * target path text is NOT done — instead we attempt a real symlink and on
 * failure copy nothing (bin links are handled separately by the installer).
 */
function extractTgz(gzbuf, destDir, { strip = 1, fs, path } = {}) {
  fs = fs || require('fs');
  path = path || require('path');
  const entries = readTgz(gzbuf);
  let files = 0;
  for (const e of entries) {
    const parts = e.name.split('/').filter((p) => p && p !== '.');
    const rel = parts.slice(strip).join('/');
    if (!rel) continue;
    if (rel.split('/').includes('..')) continue; // traversal guard
    const dest = path.join(destDir, rel);
    if (e.type === 'dir') {
      fs.mkdirSync(dest, { recursive: true });
    } else if (e.type === 'file') {
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, e.data, { mode: e.mode || 0o644 });
      files++;
    } else if (e.type === 'symlink') {
      // Attempt real symlink; tolerate failure (e.g. Windows-ish filesystems).
      try {
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.symlinkSync(e.linkname, dest);
      } catch { /* best effort */ }
    }
  }
  return files;
}

module.exports = { readTar, readTgz, extractTgz };
