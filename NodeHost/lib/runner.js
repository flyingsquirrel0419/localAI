'use strict';
// Runs a JS file in a worker_threads Worker with patched argv/cwd/env and a
// child_process shim. Returns a handle {cancel()}; invokes callbacks for
// stdout/stderr/exit.
const path = require('path');
const fs = require('fs');
const { Worker } = require('worker_threads');

const WORKER_PATH = path.join(__dirname, 'worker.js');

/**
 * @param {object} opts
 * @param {string} opts.script - script path, resolved against cwd if relative
 * @param {string[]} opts.scriptArgs
 * @param {string} opts.cwd
 * @param {Record<string,string>} opts.env
 * @param {number|undefined} opts.timeoutMs
 * @param {(data:string)=>void} opts.onStdout
 * @param {(data:string)=>void} opts.onStderr
 * @param {(code:number)=>void} opts.onExit - called exactly once
 */
function runNode(opts) {
  const { script, scriptArgs = [], cwd, env = {}, timeoutMs } = opts;
  const absScript = path.isAbsolute(script) ? script : path.resolve(cwd, script);

  if (!fs.existsSync(absScript)) {
    opts.onStderr(`node: ${script}: No such file or directory\n`);
    queueMicrotask(() => opts.onExit(1));
    return { cancel() {} };
  }

  const worker = new Worker(WORKER_PATH, {
    workerData: {
      script: absScript,
      args: scriptArgs,
      cwd,
      env,
      // execPath is meaningless inside nodejs-mobile (no re-exec possible),
      // but scripts may print it; keep the host's value.
      execPath: process.execPath,
    },
    stdout: true,
    stderr: true,
    // Inherit nothing else; env is applied inside the worker.
    env: undefined,
  });

  let settled = false;
  let timer = null;
  let cancelReason = null;

  const finish = (code) => {
    if (settled) return;
    settled = true;
    if (timer) clearTimeout(timer);
    opts.onExit(code);
  };

  worker.stdout.on('data', (d) => opts.onStdout(d.toString()));
  worker.stderr.on('data', (d) => opts.onStderr(d.toString()));
  worker.on('error', (err) => {
    opts.onStderr(`node: worker error: ${err.message}\n`);
    finish(1);
  });
  worker.on('exit', (code) => {
    if (cancelReason === 'cancel') return finish(130);
    if (cancelReason === 'timeout') return finish(124);
    finish(code);
  });

  if (timeoutMs && timeoutMs > 0) {
    timer = setTimeout(() => {
      cancelReason = 'timeout';
      worker.terminate();
    }, timeoutMs);
    if (timer.unref) timer.unref();
  }

  return {
    cancel() {
      if (settled) return;
      cancelReason = 'cancel';
      worker.terminate();
    },
  };
}

module.exports = { runNode };
