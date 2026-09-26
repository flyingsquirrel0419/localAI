'use strict';
// npm run emulation: package.json scripts, pre/post hooks, shell-words parsing,
// builtin commands, node_modules/.bin resolution (including our JS shim bins).
const fs = require('fs');
const path = require('path');
const shellwords = require('../lib/shellwords');
const { runNode } = require('../lib/runner');

const NATIVE_MSG = (name) =>
  `This package requires a native Node addon that is not supported by the current mobile runtime. (${name})`;

function readPackageJson(dir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
  } catch {
    return null;
  }
}

/** Resolve a bin name to an absolute JS file. Understands .bin shim files. */
function resolveBin(cwd, name) {
  const binPath = path.join(cwd, 'node_modules', '.bin', name);
  if (fs.existsSync(binPath)) {
    const content = fs.readFileSync(binPath, 'utf8');
    // Our shim format: first line "// nodehost-bin <relative-or-abs-target>"
    const m = content.match(/^\/\/ nodehost-bin (.+)$/m);
    if (m) {
      const target = m[1].trim();
      return path.isAbsolute(target) ? target : path.resolve(path.dirname(binPath), target);
    }
    // Symlink-style or plain script: use it directly.
    return binPath;
  }
  // Fall back: look for a package with a matching bin field.
  const nm = path.join(cwd, 'node_modules');
  let entries = [];
  try { entries = fs.readdirSync(nm); } catch { return null; }
  for (const entry of entries) {
    if (entry.startsWith('.')) continue;
    const candidates = entry.startsWith('@')
      ? safeReaddir(path.join(nm, entry)).map((c) => path.join(entry, c))
      : [entry];
    for (const pkgName of candidates) {
      const pkg = readPackageJson(path.join(nm, pkgName));
      if (!pkg || !pkg.bin) continue;
      const binMap = typeof pkg.bin === 'string' ? { [pkg.name]: pkg.bin } : pkg.bin;
      if (binMap[name]) {
        return path.join(nm, pkgName, binMap[name]);
      }
    }
  }
  return null;
}

function safeReaddir(p) {
  try { return fs.readdirSync(p); } catch { return []; }
}

/**
 * Run one parsed shell segment. Returns a Promise<number> exit code.
 */
function runSegment(seg, ctx) {
  const { cwd, env, onStdout, onStderr, timeoutMs, extraArgs } = ctx;
  const mergedEnv = Object.assign({}, env, seg.env);
  const argv = [...seg.argv];
  if (!argv.length) return Promise.resolve(0);
  if (extraArgs && extraArgs.length) argv.push(...extraArgs);
  const [cmd, ...rest] = argv;

  switch (cmd) {
    case 'echo': {
      onStdout(rest.join(' ').replace(/^-n\s*/, '') + '\n');
      return Promise.resolve(0);
    }
    case 'true': return Promise.resolve(0);
    case 'false': return Promise.resolve(1);
    case 'exit': return Promise.resolve(parseInt(rest[0] || '0', 10));
    case 'rm': {
      const recursive = rest.includes('-rf') || rest.includes('-r') || rest.includes('-f');
      const targets = rest.filter((a) => !a.startsWith('-'));
      for (const t of targets) {
        const abs = path.resolve(cwd, t);
        if (!abs.startsWith(path.resolve(cwd) + path.sep) && abs !== path.resolve(cwd)) {
          onStderr(`rm: refusing to remove outside cwd: ${t}\n`);
          return Promise.resolve(1);
        }
        try { fs.rmSync(abs, { recursive, force: true }); } catch { /* force */ }
      }
      return Promise.resolve(0);
    }
    case 'mkdir': {
      const p = rest.includes('-p');
      for (const t of rest.filter((a) => !a.startsWith('-'))) {
        try { fs.mkdirSync(path.resolve(cwd, t), { recursive: p }); } catch (e) {
          onStderr(`mkdir: ${e.message}\n`);
          return Promise.resolve(1);
        }
      }
      return Promise.resolve(0);
    }
    case 'cp': {
      const recursive = rest.includes('-r') || rest.includes('-R');
      const files = rest.filter((a) => !a.startsWith('-'));
      if (files.length < 2) { onStderr('cp: missing operand\n'); return Promise.resolve(1); }
      const dest = path.resolve(cwd, files[files.length - 1]);
      for (const src of files.slice(0, -1)) {
        try {
          fs.cpSync(path.resolve(cwd, src), dest, { recursive });
        } catch (e) { onStderr(`cp: ${e.message}\n`); return Promise.resolve(1); }
      }
      return Promise.resolve(0);
    }
    case 'node': {
      if (!rest.length) { onStderr('node: missing script\n'); return Promise.resolve(1); }
      return runToExit({
        script: rest[0], scriptArgs: rest.slice(1), cwd, env: mergedEnv,
        timeoutMs, onStdout, onStderr,
      });
    }
    default: {
      const binFile = resolveBin(cwd, cmd);
      if (binFile) {
        return runToExit({
          script: binFile, scriptArgs: rest, cwd, env: mergedEnv,
          timeoutMs, onStdout, onStderr,
        });
      }
      onStderr(`Command '${cmd}' is not supported by the mobile runtime\n`);
      return Promise.resolve(127);
    }
  }
}

function runToExit(opts) {
  return new Promise((resolve) => {
    runNode({
      ...opts,
      onExit: (code) => resolve(code),
    });
  });
}

/**
 * Run an npm script (with pre/post). Returns handle synchronously; completion
 * via opts.onExit(code).
 */
function runScript(opts) {
  const { name, extra = [], cwd, env = {}, onStdout, onStderr, onExit, timeoutMs } = opts;
  const pkg = readPackageJson(cwd);
  const fail = (msg, code = 1) => {
    onStderr(msg + '\n');
    queueMicrotask(() => onExit(code));
    return { cancel() {} };
  };
  if (!pkg) return fail(`npm: no package.json in ${cwd}`);
  const scripts = pkg.scripts || {};
  if (!name || !scripts[name]) {
    return fail(`npm: missing script: ${name || '(none)'}`);
  }

  const lifecycleEnv = Object.assign({}, env, {
    npm_lifecycle_event: name,
    npm_package_name: pkg.name || '',
  });

  const chain = [];
  if (scripts['pre' + name]) chain.push({ script: scripts['pre' + name], extra: [] });
  chain.push({ script: scripts[name], extra });
  if (scripts['post' + name]) chain.push({ script: scripts['post' + name], extra: [] });

  // Cancellation: the current segment's worker handle.
  let currentHandle = null;
  let cancelled = false;

  const p = (async () => {
    for (const step of chain) {
      const segments = shellwords.parse(step.script);
      for (let i = 0; i < segments.length; i++) {
        if (cancelled) return 130;
        const seg = segments[i];
        const prev = segments[i - 1];
        if (prev) {
          // handled below via lastCode
        }
        const code = await runSegmentTracked(seg, {
          cwd, env: lifecycleEnv, onStdout, onStderr, timeoutMs,
          extraArgs: step.extra,
        });
        const op = seg.op;
        if (op === '&&' && code !== 0) return code;
        if (op === '||' && code === 0) {
          // skip until next non-|| boundary
          while (i + 1 < segments.length && segments[i].op === '||') i++;
          // we also must skip the NEXT segment: the one after ||
          // (handled because we just consumed it)
          continue;
        }
        if (code !== 0 && (op === ';' || op === null)) {
          // npm semantics: failing last segment fails the script
          if (i === segments.length - 1) return code;
          // mid-chain failure with ';' continues
        }
      }
    }
    return 0;
  })();

  function runSegmentTracked(seg, ctx) {
    return new Promise((resolve) => {
      const h = runSegment(seg, {
        ...ctx,
        onStdout, onStderr,
      });
      if (h && typeof h.then === 'function') {
        // runSegment is promise-based; cancellation hooks at worker level via
        // ctx. For simplicity cancellation terminates at segment boundaries.
        h.then(resolve);
      } else {
        resolve(0);
      }
    });
  }

  p.then((code) => onExit(cancelled ? 130 : code), (err) => {
    onStderr(`npm run ${name}: ${err && err.message || err}\n`);
    onExit(1);
  });

  return {
    cancel() { cancelled = true; if (currentHandle && currentHandle.cancel) currentHandle.cancel(); },
  };
}

module.exports = { runScript, resolveBin, NATIVE_MSG };
