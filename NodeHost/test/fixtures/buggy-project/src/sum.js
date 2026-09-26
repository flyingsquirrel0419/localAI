'use strict';
// BUG: does not handle the two-argument case correctly (subtracts).
function sum(a, b) {
  return a - b;
}
module.exports = { sum };
