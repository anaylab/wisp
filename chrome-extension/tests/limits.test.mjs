// The shared payload caps.

import { test } from "node:test";
import assert from "node:assert/strict";

import { capList, MAXIMUM_LIST_ITEMS, MAXIMUM_TEXT_FIELD_CHARACTERS, truncateText } from "../lib/limits.js";

test("the caps match contracts.md", () => {
  assert.equal(MAXIMUM_TEXT_FIELD_CHARACTERS, 20000);
  assert.equal(MAXIMUM_LIST_ITEMS, 500);
});

test("text at or under the cap is untouched", () => {
  assert.deepEqual(truncateText("hello"), { text: "hello", truncated: false });
  const exactlyAtCap = "a".repeat(MAXIMUM_TEXT_FIELD_CHARACTERS);
  assert.deepEqual(truncateText(exactlyAtCap), { text: exactlyAtCap, truncated: false });
});

test("text over the cap is cut and marked", () => {
  const result = truncateText("a".repeat(MAXIMUM_TEXT_FIELD_CHARACTERS + 1));
  assert.equal(result.text.length, MAXIMUM_TEXT_FIELD_CHARACTERS);
  assert.equal(result.truncated, true);
  assert.deepEqual(truncateText("abcdef", 3), { text: "abc", truncated: true });
});

test("a cut never splits an emoji's surrogate pair", () => {
  const result = truncateText("ab😀cd", 3);
  assert.deepEqual(result, { text: "ab", truncated: true });
});

test("non-strings become empty text", () => {
  for (const notText of [undefined, null, 42, {}, ["a"]]) {
    assert.deepEqual(truncateText(notText), { text: "", truncated: false });
  }
});

test("lists at or under the cap are untouched, longer ones are cut and marked", () => {
  assert.deepEqual(capList([1, 2, 3]), { items: [1, 2, 3], truncated: false });
  const longList = Array.from({ length: MAXIMUM_LIST_ITEMS + 10 }, (_, itemIndex) => itemIndex);
  const result = capList(longList);
  assert.equal(result.items.length, MAXIMUM_LIST_ITEMS);
  assert.equal(result.items.at(-1), MAXIMUM_LIST_ITEMS - 1);
  assert.equal(result.truncated, true);
  assert.deepEqual(capList([1, 2, 3], 2), { items: [1, 2], truncated: true });
});

test("non-lists become empty lists", () => {
  for (const notList of [undefined, null, "abc", { length: 2 }]) {
    assert.deepEqual(capList(notList), { items: [], truncated: false });
  }
});
