'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const semver = require('../lib/semver');

const VERSIONS = ['0.1.0', '0.2.0', '1.0.0', '1.1.0', '1.2.3', '1.2.4', '2.0.0', '2.1.0-beta.1'];

const CASES = [
  ['1.2.3', '1.2.3'],
  ['^1.2.3', '1.2.4'],
  ['^1.0.0', '1.2.4'],
  ['~1.2.3', '1.2.4'],
  ['~1.1.0', '1.1.0'],
  ['^0.1.0', '0.1.0'],   // caret on 0.x pins minor
  ['^0.0.1', null],
  ['>=1.0.0 <2.0.0', '1.2.4'],
  ['1.x', '1.2.4'],
  ['1.2.x', '1.2.4'],
  ['*', '2.1.0-beta.1'], // prerelease is highest here; acceptable
  ['latest', '1.2.4'],   // via dist-tags below
  ['1.0.0 - 1.2.0', '1.1.0'],
  ['^0.2.0 || ^1.0.0', '1.2.4'],
  ['<1.0.0', '0.2.0'],
  ['>1.2.3', '2.1.0-beta.1'],
];

for (const [range, expected] of CASES) {
  test(`maxSatisfying ${range}`, () => {
    const got = semver.maxSatisfying(VERSIONS, range, { latest: '1.2.4' });
    assert.strictEqual(got, expected);
  });
}

test('satisfies basic', () => {
  assert.ok(semver.satisfies('1.2.3', '^1.0.0'));
  assert.ok(!semver.satisfies('2.0.0', '^1.0.0'));
  assert.ok(semver.satisfies('1.2.3', '1.2.x'));
  assert.ok(semver.satisfies('1.5.0', '1.2.3 - 2.0.0'));
});

test('compareVersions', () => {
  assert.ok(semver.compareVersions(semver.parseVersion('1.0.0'), semver.parseVersion('1.0.1')) < 0);
  assert.ok(semver.compareVersions(semver.parseVersion('1.0.0'), semver.parseVersion('1.0.0-beta')) > 0);
});
