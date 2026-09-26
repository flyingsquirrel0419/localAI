'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const shellwords = require('../lib/shellwords');

test('simple command', () => {
  assert.deepStrictEqual(shellwords.parse('node index.js'), [
    { env: {}, argv: ['node', 'index.js'], op: null },
  ]);
});

test('&& chain', () => {
  const segs = shellwords.parse('node a.js && node b.js');
  assert.strictEqual(segs.length, 2);
  assert.strictEqual(segs[0].op, '&&');
  assert.strictEqual(segs[1].op, null);
});

test('|| chain', () => {
  const segs = shellwords.parse('node a.js || echo fallback');
  assert.strictEqual(segs[0].op, '||');
  assert.deepStrictEqual(segs[1].argv, ['echo', 'fallback']);
});

test('semicolon and env assignment', () => {
  const segs = shellwords.parse('FOO=1 BAR=two node x.js; echo done');
  assert.strictEqual(segs.length, 2);
  assert.deepStrictEqual(segs[0].env, { FOO: '1', BAR: 'two' });
  assert.deepStrictEqual(segs[0].argv, ['node', 'x.js']);
  assert.strictEqual(segs[0].op, ';');
});

test('quoting', () => {
  const segs = shellwords.parse(`echo "hello world" 'single quoted' a\\ b "with\\"esc"`);
  assert.deepStrictEqual(segs[0].argv, ['echo', 'hello world', 'single quoted', 'a b', 'with"esc']);
});

test('empty input', () => {
  assert.deepStrictEqual(shellwords.parse(''), []);
  assert.deepStrictEqual(shellwords.parse('   \n '), []);
});
