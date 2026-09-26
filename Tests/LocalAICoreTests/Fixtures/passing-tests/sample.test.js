const test = require("node:test");
const assert = require("node:assert");

test("addition works", () => {
  assert.strictEqual(1 + 1, 2);
});

test("strings concat", () => {
  assert.strictEqual("a" + "b", "ab");
});
