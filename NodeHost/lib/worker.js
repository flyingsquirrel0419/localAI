'use strict';
// Worker script: patches the environment, then loads the target script as the
// main module. Loaded only by lib/runner.js via worker_threads.
const path = require('path');
const Module = require('module');
const { workerData } = require('worker_threads');

const { script, args, cwd, env, execPath } = workerData;

// --- env -----------------------------------------------------------------
for (const k of Object.keys(process.env)) {
  if (!(k in env)) delete process.env[k];
}
Object.assign(process.env, env);

// --- argv / argv0 / execPath ----------------------------------------------
process.argv = [execPath, script, ...args];
try {
  Object.defineProperty(process, 'argv0', { value: execPath, configurable: true, writable: true });
} catch { /* read-only; harmless */ }
try {
  Object.defineProperty(process, 'execPath', { value: execPath, configurable: true });
} catch { /* read-only on some builds; harmless */ }

// --- cwd -------------------------------------------------------------------
// process.chdir is unavailable in workers. Patch process.cwd and resolve
// relative paths in the fs module against the requested cwd. This covers the
// overwhelmingly common case: scripts using relative fs paths.
process.cwd = () => cwd;
const realFs = require('fs');
function resolveP(p) {
  if (typeof p !== 'string') return p;
  if (path.isAbsolute(p)) return p;
  return path.resolve(cwd, p);
}
for (const fn of [
  'readFileSync', 'writeFileSync', 'readdirSync', 'statSync', 'lstatSync',
  'existsSync', 'accessSync', 'mkdirSync', 'rmSync', 'rmdirSync', 'unlinkSync',
  'renameSync', 'copyFileSync', 'appendFileSync', 'openSync', 'realpathSync',
  'readlinkSync', 'chmodSync', 'chownSync', 'truncateSync', 'utimesSync',
  'readFile', 'writeFile', 'readdir', 'stat', 'lstat', 'access', 'mkdir',
  'rm', 'rmdir', 'unlink', 'rename', 'copyFile', 'appendFile', 'open',
  'realpath', 'readlink', 'chmod', 'chown', 'truncate', 'utimes',
  'createReadStream', 'createWriteStream', 'watch', 'watchFile', 'unwatchFile',
  'opendirSync', 'opendir', 'cpSync', 'cp', 'symlinkSync', 'symlink',
]) {
  if (typeof realFs[fn] !== 'function') continue;
  const orig = realFs[fn];
  realFs[fn] = function (p, ...rest) {
    return orig.call(this, typeof p === 'string' ? resolveP(p) : p, ...rest);
  };
}
// fs.promises mirrors the same functions.
if (realFs.promises) {
  for (const fn of [
    'readFile', 'writeFile', 'readdir', 'stat', 'lstat', 'access', 'mkdir',
    'rm', 'rmdir', 'unlink', 'rename', 'copyFile', 'appendFile', 'open',
    'realpath', 'readlink', 'chmod', 'chown', 'truncate', 'utimes', 'opendir',
    'cp', 'symlink', 'watch',
  ]) {
    if (typeof realFs.promises[fn] !== 'function') continue;
    const orig = realFs.promises[fn];
    realFs.promises[fn] = function (p, ...rest) {
      return orig.call(this, typeof p === 'string' ? resolveP(p) : p, ...rest);
    };
  }
}

// --- child_process shim ------------------------------------------------------
// nodejs-mobile forbids spawn/exec entirely. Throw a precise error, except
// `node file.js ...` (or execPath file.js), emulated with a nested Worker.
const childShim = require('./child-shim');
childShim.install(Module, { cwd, execPath });

// --- process.exit ------------------------------------------------------------
// End only this worker. worker.terminate() from the parent maps the code, but
// inside the worker the cleanest route is to actually exit — worker_threads
// isolates this from the host process.
// (process.exit in a worker terminates just the worker thread.)

// --- run the script as main ---------------------------------------------------
process.mainModule = undefined; // let Module set it
Module.runMain
  ? Module.runMain(script)
  : Module._load(script, null, true);
