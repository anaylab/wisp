// Phase 11, research mode: finding and marking a citation's quote in the page
// (content/quote-highlight.js) and the `highlightTextFragments` handler.
//
// The fixture page is parsed with linkedom (a devDependency, `npm install` in
// chrome-extension/); without it the page tests are skipped, saying why.
// linkedom has no layout and no Range.setStart, so the tests give the document
// a small recording Range: what matters here is where a quote starts and ends.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  createResearchHandlers,
  cleanedQuotesParameter,
  MISSING_PAGES_READ_ERROR,
  QUOTE_HIGHLIGHTER_FILE,
  MAXIMUM_QUOTES_PER_REQUEST,
} from "../handlers/research.js";
import { createFakeChrome } from "./fake-chrome.mjs";

// Defines globalThis.wispQuoteHighlighter, as the injected file does in a tab.
await import("../content/quote-highlight.js");
const quoteHighlighter = globalThis.wispQuoteHighlighter;

let parseHTML = null;
try {
  ({ parseHTML } = await import("linkedom"));
} catch (error) {
  parseHTML = null;
}
const skipWithoutLinkedom = parseHTML ? false : "linkedom isn't installed: run `npm install` in chrome-extension/";

function fixtureDocument() {
  const html = readFileSync(new URL("./fixtures/research/keyboard-review.html", import.meta.url), "utf8");
  const parsedDocument = parseHTML(html).document;
  parsedDocument.createRange = () => {
    const recordedRange = {
      setStart(node, offset) { recordedRange.start = { node, offset }; },
      setEnd(node, offset) { recordedRange.end = { node, offset }; },
      getClientRects: () => [{ left: 10, top: 20, width: 100, height: 18 }],
    };
    return recordedRange;
  };
  return parsedDocument;
}

// The text a location covers, read back from its nodes (same node only, or
// first node's tail + last node's head when it spans several).
function textAt(location) {
  if (location.startNode === location.endNode) {
    return location.startNode.nodeValue.slice(location.startOffset, location.endOffset);
  }
  return location.startNode.nodeValue.slice(location.startOffset) + "…" + location.endNode.nodeValue.slice(0, location.endOffset);
}

// MARK: - Folding and finding

test("folding matches curly quotes, dashes and whitespace the way Wisp's verifier does", () => {
  const { normalizedForMatching } = quoteHighlighter.internals;
  assert.equal(normalizedForMatching("it’s  hot‑swappable — $70…"), "it'shot-swappable-$70...");
  assert.equal(normalizedForMatching("It's\nhot-swappable - $70..."), normalizedForMatching("it’s hot‑swappable — $70…"));
});

test("a quote inside one paragraph is found where it starts and ends", { skip: skipWithoutLinkedom }, () => {
  const [location] = quoteHighlighter.findQuoteLocations(fixtureDocument(), ["Its keycaps are thin ABS plastic"]);
  assert.ok(location);
  assert.equal(textAt(location), "Its keycaps are thin ABS plastic");
});

test("a quote crossing inline elements and typographic punctuation is still found", { skip: skipWithoutLinkedom }, () => {
  const [location] = quoteHighlighter.findQuoteLocations(fixtureDocument(), [
    "The Keychron K2 is the board we'd buy first: it's wireless, hot-swappable",
  ]);
  assert.ok(location, "the quote spans <strong> and uses straight quotes where the page has curly ones");
  assert.equal(location.startNode.nodeValue.slice(location.startOffset).trim(), "The");
  assert.match(location.endNode.nodeValue.slice(0, location.endOffset), /hot‑swappable$/);
});

test("a quote that crosses from one paragraph into the next matches without the line break", { skip: skipWithoutLinkedom }, () => {
  const [location] = quoteHighlighter.findQuoteLocations(fixtureDocument(), [
    "costs about $70. Its keycaps are thin",
  ]);
  assert.ok(location);
});

test("text in scripts, form fields and data-wisp-ignore regions is never matched", { skip: skipWithoutLinkedom }, () => {
  const locations = quoteHighlighter.findQuoteLocations(fixtureDocument(), [
    "the keychron k2 costs nothing at all",
    "hunter2 is my keyboard password",
    "the keychron k2 is a scam, says this textarea",
    "the keychron k2 is the only keyboard you need",
  ]);
  assert.deepEqual(locations, [null, null, null, null]);
});

test("a fabricated quote and a too-short quote aren't found", { skip: skipWithoutLinkedom }, () => {
  const locations = quoteHighlighter.findQuoteLocations(fixtureDocument(), [
    "The Keychron K2 is the best keyboard ever made",
    "K2",
  ]);
  assert.deepEqual(locations, [null, null]);
});

// MARK: - Drawing

test("showing quotes marks the found ones, reports the missing ones and scrolls to the first", { skip: skipWithoutLinkedom }, () => {
  const pageDocument = fixtureDocument();
  const scrolledElements = [];
  const originalDocument = globalThis.document;
  const originalAnimationFrame = globalThis.requestAnimationFrame;
  globalThis.document = pageDocument;
  globalThis.requestAnimationFrame = (callback) => callback();
  try {
    for (const paragraph of pageDocument.querySelectorAll("p")) {
      paragraph.scrollIntoView = (options) => scrolledElements.push({ text: paragraph.textContent, options });
    }
    const result = quoteHighlighter.showQuotes({
      quotes: ["The Royal Kludge RK61 is cheaper still", "a sentence that is not there at all"],
      color: "url(javascript:alert(1))",
    });
    assert.deepEqual(result, { found: [0], missing: [1] });
    assert.equal(scrolledElements.length, 1);
    assert.match(scrolledElements[0].text, /Royal Kludge/);

    const hostElement = pageDocument.querySelector("wisp-quotes");
    assert.ok(hostElement, "the marks live in Wisp's own host element");
    assert.ok(hostElement.hasAttribute("data-wisp-ignore"), "Wisp never reads its own marks back");

    assert.deepEqual(quoteHighlighter.clearQuotes(), { cleared: true });
    assert.equal(pageDocument.querySelector("wisp-quotes"), null);
  } finally {
    globalThis.document = originalDocument;
    globalThis.requestAnimationFrame = originalAnimationFrame;
  }
});

test("only plain colours reach the style attribute", () => {
  const { sanitizedColor } = quoteHighlighter.internals;
  assert.equal(sanitizedColor("rgb(255, 59, 48)"), "rgb(255, 59, 48)");
  assert.equal(sanitizedColor("#34c759"), "#34c759");
  assert.equal(sanitizedColor("url(evil)"), "rgb(51, 128, 255)");
});

// MARK: - The handler

const PAGES_READ_PERMISSIONS = { grantedPermissions: ["scripting"], grantedOrigins: ["<all_urls>"] };

function fakeChromeWithTab(tab, { executeScript, permissions = PAGES_READ_PERMISSIONS } = {}) {
  return createFakeChrome({
    tabs: [{ id: 7, windowId: 1, index: 0, active: false, title: "Keys Weekly", status: "complete", ...tab }],
    executeScript,
    ...permissions,
  });
}

test("quotes are cleaned and capped before anything is injected", () => {
  assert.throws(() => cleanedQuotesParameter("not a list"), /quotes must be a list/);
  assert.throws(() => cleanedQuotesParameter(["   ", 4]), /at least one/);
  const manyQuotes = Array.from({ length: 12 }, (unused, quoteIndex) => ` quote number ${quoteIndex} `);
  const cleanedQuotes = cleanedQuotesParameter(manyQuotes);
  assert.equal(cleanedQuotes.length, MAXIMUM_QUOTES_PER_REQUEST);
  assert.equal(cleanedQuotes[0], "quote number 0");
});

test("highlighting injects the quote highlighter, then asks it to show the quotes", async () => {
  const injections = [];
  const fakeChrome = fakeChromeWithTab({ url: "https://keys.example.com/budget" }, {
    executeScript: (injection) => {
      injections.push(injection);
      return injection.func ? [{ result: { found: [0], missing: [1] } }] : [];
    },
  });
  const handlers = createResearchHandlers({ chromeAPI: () => fakeChrome });

  const reply = await handlers.highlightTextFragments({ tabId: 7, quotes: ["one quote here", "another quote here"], color: "#ff9500" });

  assert.deepEqual(reply, { tabId: 7, found: [0], missing: [1] });
  assert.deepEqual(injections[0].files, [QUOTE_HIGHLIGHTER_FILE]);
  assert.deepEqual(injections[1].args, [{ quotes: ["one quote here", "another quote here"], color: "#ff9500", scrollToFirst: true }]);
});

test("without pages.read the handler says which capability is missing", async () => {
  const fakeChrome = fakeChromeWithTab({ url: "https://keys.example.com/budget" }, { permissions: {} });
  const handlers = createResearchHandlers({ chromeAPI: () => fakeChrome });
  await assert.rejects(handlers.highlightTextFragments({ tabId: 7, quotes: ["one quote here"] }), new RegExp(MISSING_PAGES_READ_ERROR));
});

test("chrome's own pages, blank tabs and incognito tabs are refused before injecting", async () => {
  for (const [tab, expectedError] of [
    [{ url: "chrome://settings" }, /chrome's own pages/],
    [{ url: "about:blank" }, /nothing to highlight/],
    [{ url: "https://keys.example.com/budget", incognito: true }, /incognito/],
  ]) {
    let injectionCount = 0;
    const fakeChrome = fakeChromeWithTab(tab, { executeScript: () => { injectionCount += 1; return []; } });
    const handlers = createResearchHandlers({ chromeAPI: () => fakeChrome });
    await assert.rejects(handlers.highlightTextFragments({ tabId: 7, quotes: ["one quote here"] }), expectedError);
    assert.equal(injectionCount, 0);
  }
});

test("a tab id is required: the user's front tab is never assumed", async () => {
  const handlers = createResearchHandlers({ chromeAPI: () => fakeChromeWithTab({ url: "https://keys.example.com/" }) });
  await assert.rejects(handlers.highlightTextFragments({ quotes: ["one quote here"] }), /tabId must be a tab id/);
});
