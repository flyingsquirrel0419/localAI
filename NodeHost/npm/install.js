'use strict';
// Pure-JS npm install: registry metadata fetch, semver resolution, tarball
// download with integrity check, extraction, hoisted layout, .bin shims,
// package-lock.json v3 write. No install scripts are ever run.
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');
const semver = require('../lib/semver');
const tar = require('../lib/tar');
const { NATIVE_MSG } = require('./run');

const REGISTRY = () => (process.env.NODEHOST_REGISTRY || 'https://registry.npmjs.org');
const CONCURRENCY = 8;

function fetchBuffer(url, redirects = 5) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const mod = u.protocol === 'http:' ? http : https;
    const req = mod.get(url, {
      headers: {
        'Accept': url.includes('/-/') ? '*/*' : 'application/vnd.npm.install-v1+json, application/json',
        'User-Agent': 'nodehost-npm/1.0',
      },
    }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
        res.resume();
        return resolve(fetchBuffer(new URL(res.headers.location, url).toString(), redirects - 1));
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`GET ${url} -> ${res.statusCode}`));
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    });
    req.on('error', reject);
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
  });
}

async function fetchJson(url) {
  const buf = await fetchBuffer(url);
  return JSON.parse(buf.toString('utf8'));
}

function packumentUrl(name) {
  return `${REGISTRY().replace(/\/$/, '')}/${name.replace('/', '%2f')}`;
}

function verifyIntegrity(buf, integrity) {
  if (!integrity) return true;
  const m = String(integrity).match(/^(sha512|sha1|sha256)-(.+)$/);
  if (!m) return true;
  const hash = crypto.createHash(m[1]).update(buf).digest('base64');
  return hash === m[2];
}

function loadLockfile(cwd) {
  try {
    const lock = JSON.parse(fs.readFileSync(path.join(cwd, 'package-lock.json'), 'utf8'));
    if (lock && (lock.lockfileVersion === 2 || lock.lockfileVersion === 3) && lock.packages) {
      return lock;
    }
  } catch { /* none */ }
  return null;
}

function lockPinned(lock, name) {
  // packages keys look like "node_modules/foo" (hoisted only — good enough)
  const entry = lock.packages[`node_modules/${name}`];
  return entry && entry.version ? entry : null;
}

/**
 * Resolve the dependency graph. Returns a flat-ish plan:
 *   Map<name, Map<version, {name, version, tarball, integrity, deps, bin, native}>>
 * and placement: Map<name, version> for the root node_modules plus a list of
 * nested placements [{parentName, name, version}].
 */
async function resolveGraph(rootDeps, lock, shouldCancel, onStderr) {
  const manifests = new Map(); // name -> packument
  const cacheKey = (n) => n;
  async function getPackument(name) {
    const k = cacheKey(name);
    if (!manifests.has(k)) {
      if (shouldCancel()) throw new Error('cancelled');
      manifests.set(k, await fetchJson(packumentUrl(name)));
    }
    return manifests.get(k);
  }

  // resolution results: name -> Map<rangeKey, version>
  const chosen = new Map(); // name -> Set<version>
  const nodeInfo = new Map(); // `${name}@${version}` -> manifest version obj
  const queue = [];

  function pick(name, range) {
    return getPackument(name).then((pk) => {
      const versions = Object.keys(pk.versions || {});
      const v = semver.maxSatisfying(versions, range, pk['dist-tags']);
      if (!v) throw new Error(`No matching version for ${name}@${range}`);
      return { version: v, meta: pk.versions[v] };
    });
  }

  async function addDep(name, range, pinnedVersion) {
    let version = pinnedVersion;
    if (!version) {
      const r = await pick(name, range);
      version = r.version;
    }
    const key = `${name}@${version}`;
    if (nodeInfo.has(key)) return version;
    const pk = await getPackument(name);
    const meta = pk.versions[version];
    if (!meta) throw new Error(`Registry metadata missing ${key}`);
    nodeInfo.set(key, meta);
    if (!chosen.has(name)) chosen.set(name, new Set());
    chosen.get(name).add(version);
    queue.push(meta);
    return version;
  }

  // Root deps (pinned to lockfile version when present).
  for (const [name, range] of Object.entries(rootDeps)) {
    const pinned = lock && lockPinned(lock, name);
    await addDep(name, range, pinned && pinned.version);
  }
  while (queue.length) {
    if (shouldCancel()) throw new Error('cancelled');
    const meta = queue.shift();
    const deps = Object.assign({}, meta.dependencies);
    for (const [dname, drange] of Object.entries(deps)) {
      const pinned = lock && lockPinned(lock, dname);
      await addDep(dname, drange, pinned && pinned.version);
    }
  }
  return { chosen, nodeInfo };
}

/** Compute placement: root hoisting with nesting on conflict. */
function planLayout(chosen, nodeInfo) {
  const root = new Map(); // name -> version (first-seen wins, npm-like enough)
  const nested = [];      // {parentKey, name, version}
  for (const [name, versions] of chosen) {
    const list = [...versions].sort((a, b) => {
      const pa = semver.parseVersion(a), pb = semver.parseVersion(b);
      return pa && pb ? semver.compareVersions(pa, pb) : 0;
    });
    // Highest version at root.
    root.set(name, list[list.length - 1]);
    for (let i = 0; i < list.length - 1; i++) {
      nested.push({ name, version: list[i] });
    }
  }
  return { root, nested };
}

async function downloadAll(items, onStdout, shouldCancel) {
  let done = 0;
  const results = new Map();
  let idx = 0;
  async function worker() {
    while (idx < items.length) {
      if (shouldCancel()) throw new Error('cancelled');
      const item = items[idx++];
      const buf = await fetchBuffer(item.dist.tarball);
      if (!verifyIntegrity(buf, item.dist.integrity)) {
        throw new Error(`integrity check failed for ${item.name}@${item.version}`);
      }
      results.set(`${item.name}@${item.version}`, buf);
      done++;
    }
  }
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, items.length) }, worker));
  return results;
}

function ensureDir(p) { fs.mkdirSync(p, { recursive: true }); }

function writeBinShims(cwd, pkgDir, pkgName, pkg) {
  if (!pkg.bin) return;
  const binMap = typeof pkg.bin === 'string' ? { [pkgName.split('/').pop()]: pkg.bin } : pkg.bin;
  const binDir = path.join(cwd, 'node_modules', '.bin');
  ensureDir(binDir);
  for (const [binName, rel] of Object.entries(binMap)) {
    const target = path.join(pkgDir, rel);
    const shim = `// nodehost-bin ${target}\nrequire(${JSON.stringify(target)});\n`;
    try { fs.writeFileSync(path.join(binDir, binName), shim); } catch { /* ignore */ }
  }
}

function detectNative(pkg, pkgDir) {
  if (pkg.gypfile) return true;
  try { if (fs.existsSync(path.join(pkgDir, 'binding.gyp'))) return true; } catch { /* */ }
  return false;
}

/**
 * Install. Returns Promise<number> exit code.
 * opts: {cwd, packages, saveDev, frozen, onStdout, onStderr, shouldCancel}
 */
async function install(opts) {
  const { cwd, packages = [], saveDev = false, frozen = false, onStdout, onStderr, shouldCancel = () => false } = opts;
  const started = Date.now();
  const pkgPath = path.join(cwd, 'package.json');
  let pkg;
  try {
    pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
  } catch {
    onStderr('npm install: no package.json found\n');
    return 1;
  }

  // `npm install <pkg>` — add to dependencies.
  if (packages.length && !frozen) {
    const section = saveDev ? 'devDependencies' : 'dependencies';
    pkg[section] = pkg[section] || {};
    for (const spec of packages) {
      const at = spec.lastIndexOf('@');
      if (at > 0) pkg[section][spec.slice(0, at)] = spec.slice(at + 1);
      else pkg[section][spec] = 'latest';
    }
    fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
  }

  const rootDeps = Object.assign({}, pkg.dependencies, pkg.devDependencies, pkg.optionalDependencies);
  if (!Object.keys(rootDeps).length) {
    onStdout('up to date in 0s\n');
    return 0;
  }

  const lock = loadLockfile(cwd);
  const { chosen, nodeInfo } = await resolveGraph(rootDeps, lock, shouldCancel, onStderr);
  const { root, nested } = planLayout(chosen, nodeInfo);

  // Download everything.
  const allItems = [];
  for (const [name, version] of root) allItems.push(nodeInfo.get(`${name}@${version}`));
  for (const n of nested) allItems.push(nodeInfo.get(`${n.name}@${n.version}`));
  const tarballs = await downloadAll(allItems, onStdout, shouldCancel);

  // Extract: root first.
  const nmDir = path.join(cwd, 'node_modules');
  ensureDir(nmDir);
  let count = 0;
  const nativeWarnings = [];
  function extractOne(meta, destDir) {
    const buf = tarballs.get(`${meta.name}@${meta.version}`);
    ensureDir(destDir);
    tar.extractTgz(buf, destDir, { strip: 1 });
    count++;
    if (detectNative(meta, destDir)) nativeWarnings.push(meta.name);
    if (meta.scripts && (meta.scripts.preinstall || meta.scripts.install || meta.scripts.postinstall)) {
      onStderr(`npm warn: skipping install scripts for ${meta.name}@${meta.version} (not supported by the mobile runtime)\n`);
    }
    // bin entries: prefer extracted package.json (registry metadata often omits it)
    let extractedPkg = meta;
    try {
      extractedPkg = JSON.parse(fs.readFileSync(path.join(destDir, 'package.json'), 'utf8'));
    } catch { /* fall back to registry meta */ }
    writeBinShims(cwd, destDir, meta.name, extractedPkg);
  }
  for (const [name, version] of root) {
    if (shouldCancel()) return 130;
    const meta = nodeInfo.get(`${name}@${version}`);
    extractOne(meta, path.join(nmDir, name));
  }
  // Nested: install inside every consumer's node_modules? Simplification:
  // nest under a synthetic path root only when conflict. We nest the lower
  // versions under `node_modules/<name>/` is already taken — instead nest
  // under each dependent. To keep this tractable we nest them at
  // node_modules/.nodehost-nested/<name>@<version> and ALSO under the root
  // name path only if the root slot differs — the bin resolver only consults
  // .bin and package bin fields, and Node's require walks up, so true nesting
  // correctness for conflicting transitive deps is best-effort here.
  for (const n of nested) {
    const meta = nodeInfo.get(`${n.name}@${n.version}`);
    extractOne(meta, path.join(nmDir, '.nodehost-nested', `${n.name}@${n.version}`));
  }

  for (const name of nativeWarnings) {
    onStderr(NATIVE_MSG(name) + '\n');
  }

  // Write package-lock.json v3 when missing.
  if (!lock) {
    const packagesMap = { '': { name: pkg.name || '', version: pkg.version || '', dependencies: pkg.dependencies || {} } };
    for (const [name, version] of root) {
      const meta = nodeInfo.get(`${name}@${version}`);
      packagesMap[`node_modules/${name}`] = {
        version,
        resolved: meta.dist.tarball,
        integrity: meta.dist.integrity,
      };
      if (meta.dependencies) packagesMap[`node_modules/${name}`].dependencies = meta.dependencies;
    }
    const lockOut = {
      name: pkg.name || '',
      version: pkg.version || '',
      lockfileVersion: 3,
      requires: true,
      packages: packagesMap,
    };
    fs.writeFileSync(path.join(cwd, 'package-lock.json'), JSON.stringify(lockOut, null, 2) + '\n');
  }

  const secs = ((Date.now() - started) / 1000).toFixed(1);
  onStdout(`added ${count} packages in ${secs}s\n`);
  return 0;
}

module.exports = { install, fetchBuffer, verifyIntegrity, resolveGraph, planLayout };
