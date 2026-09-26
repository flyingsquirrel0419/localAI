'use strict';
// Tiny self-contained harness: no deps, exits non-zero on failure.
const { sum } = require('../src/sum');

let failed = 0;
function check(name, actual, expected) {
  if (actual === expected) {
    console.log(`ok - ${name}`);
  } else {
    failed++;
    console.log(`FAIL - ${name}: expected ${expected}, got ${actual}`);
  }
}

check('sum(1, 2)', sum(1, 2), 3);
check('sum(0, 0)', sum(0, 0), 0);
check('sum(-1, 1)', sum(-1, 1), 0);

if (failed) {
  console.log(`${failed} test(s) failed`);
  process.exit(1);
}
console.log('all tests passed');
