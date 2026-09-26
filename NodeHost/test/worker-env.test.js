'use strict';
// H4: worker must strip host credentials (LOCALAI_HOST_TOKEN, GITHUB_TOKEN,
// etc.) from the environment it hands to user scripts, even if the caller
// (mistakenly or maliciously) passed them through `env`.
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { runNode } = require('../lib/runner');

function runScript(dir, script, env) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    runNode({
      script,
      cwd: dir,
      env,
      onStdout: (s) => { stdout += s; },
      onStderr: (s) => { stderr += s; },
      onExit: (code) => resolve({ code, stdout, stderr }),
      timeoutMs: 10000,
    });
  });
}

test('worker strips forbidden credential env keys', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nodehost-env-'));
  fs.writeFileSync(path.join(dir, 'env.js'), `
    const keys = ['LOCALAI_HOST_TOKEN', 'LOCALAI_HOST_PORT', 'LOCALAI_HOST_PORTFILE',
                  'GITHUB_TOKEN', 'GH_TOKEN', 'HF_TOKEN', 'HUGGING_FACE_HUB_TOKEN'];
    const leaked = keys.filter((k) => process.env[k]);
    console.log('LEAKED:' + (leaked.length ? leaked.join(',') : 'none'));
    console.log('SAFE:' + (process.env.SAFE_VAR || 'missing'));
  `);
  const { code, stdout } = await runScript(dir, 'env.js', {
    LOCALAI_HOST_TOKEN: 'super-secret-host-token',
    LOCALAI_HOST_PORT: '12345',
    LOCALAI_HOST_PORTFILE: '/tmp/portfile',
    GITHUB_TOKEN: 'ghp_abcdefghijklmnop',
    GH_TOKEN: 'ghp_abcdefghijklmnop',
    HF_TOKEN: 'hf_abcdefghijklmnop',
    HUGGING_FACE_HUB_TOKEN: 'hf_abcdefghijklmnop',
    SAFE_VAR: 'kept',
  });
  assert.strictEqual(code, 0);
  assert.match(stdout, /LEAKED:none/);
  assert.match(stdout, /SAFE:kept/);
  fs.rmSync(dir, { recursive: true, force: true });
});
