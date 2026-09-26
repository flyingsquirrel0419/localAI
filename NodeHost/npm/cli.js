'use strict';
// npm command emulation entry. Dispatches to run/install/ls/version.
// run(opts) returns a handle {cancel()} synchronously; completion is reported
// through the onExit callback (async for install).
const npmRun = require('./run');
const installer = require('./install');

function run(opts) {
  const { args = [], onStdout, onStderr, onExit, cwd } = opts;
  const sub = args[0];

  const fail = (msg, code = 1) => {
    onStderr(msg + '\n');
    queueMicrotask(() => onExit(code));
    return { cancel() {} };
  };

  switch (sub) {
    case 'run':
    case 'run-script': {
      const name = args[1];
      const extra = [];
      // npm run <name> -- extra args
      const dashDash = args.indexOf('--', 2);
      if (dashDash !== -1) extra.push(...args.slice(dashDash + 1));
      return npmRun.runScript({ name, extra, ...opts });
    }
    case 'test':
      return npmRun.runScript({ name: 'test', extra: args.slice(1), ...opts });
    case 'start':
      return npmRun.runScript({ name: 'start', extra: args.slice(1), ...opts });
    case 'install':
    case 'i':
    case 'ci': {
      const pkgs = args.slice(1).filter((a) => !a.startsWith('-'));
      const flags = args.slice(1).filter((a) => a.startsWith('-'));
      const handle = { cancelled: false, cancel() { this.cancelled = true; } };
      installer.install({
        cwd,
        packages: pkgs,
        saveDev: flags.includes('--save-dev') || flags.includes('-D'),
        frozen: sub === 'ci',
        onStdout, onStderr,
        shouldCancel: () => handle.cancelled,
      }).then(
        (code) => { if (!handle.cancelled) onExit(code); else onExit(130); },
        (err) => {
          onStderr(`npm install failed: ${err && err.message || err}\n`);
          onExit(1);
        }
      );
      return handle;
    }
    case 'ls': {
      const fs = require('fs');
      const path = require('path');
      let out = '';
      const nmDir = path.join(cwd, 'node_modules');
      try {
        for (const entry of fs.readdirSync(nmDir)) {
          if (entry.startsWith('.')) continue;
          if (entry.startsWith('@')) {
            for (const child of fs.readdirSync(path.join(nmDir, entry))) {
              out += `${entry}/${child}\n`;
            }
          } else out += entry + '\n';
        }
      } catch { /* no node_modules */ }
      onStdout(out || '(empty)\n');
      queueMicrotask(() => onExit(0));
      return { cancel() {} };
    }
    case '--version':
    case '-v':
    case 'version':
      onStdout('10.8.2-nodehost\n');
      queueMicrotask(() => onExit(0));
      return { cancel() {} };
    default:
      return fail(`npm command '${sub || ''}' is not supported by the mobile runtime`, 1);
  }
}

module.exports = { run };
