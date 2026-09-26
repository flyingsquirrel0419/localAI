const test = require("node:test");
const assert = require("node:assert");

test("this one passes", () => {
  assert.ok(true);
});

test("this one fails", () => {
  assert.strictEqual(1, 2, "intentionally broken");
});
