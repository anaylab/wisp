// Phase 02, page reading: the extraction in content/read-page.js against
// fixture pages, and the handlers' tab choice, refusals and caps.
//
// The fixtures are parsed with linkedom (a devDependency, `npm install` in
// chrome-extension/). It never ships: nothing the extension loads imports it.
// Without it the extraction tests are skipped, saying why, so the rest of the
// suite still runs on a checkout that hasn't installed it.

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  pageReadingHandlers,
  forbiddenPageReason,
  MISSING_PAGES_READ_ERROR,
  PAGE_READER_SCRIPT_FILE,
} from "../handlers/page-reading.js";
import { createFakeChrome } from "./fake-chrome.mjs";

// Defines globalThis.wispPageReader, as the injected file does in a tab.
await import("../content/read-page.js");
const pageReader = globalThis.wispPageReader;

let parseHTML = null;
try {
  ({ parseHTML } = await import("linkedom"));
} catch (error) {
  parseHTML = null;
}
const skipWithoutLinkedom = parseHTML ? false : "linkedom isn't installed: run `npm install` in chrome-extension/";

function fixtureDocument(fixtureName) {
  const html = readFileSync(new URL(`./fixtures/${fixtureName}.html`, import.meta.url), "utf8");
  return parseHTML(html).document;
}

// MARK: - Extraction

test("an article page keeps the article and drops the furniture", { skip: skipWithoutLinkedom }, () => {
  const pageText = pageReader.readPageText(fixtureDocument("article"));

  assert.equal(pageText.title, "How Sourdough Rises | The Baking Journal");
  assert.equal(pageText.canonicalUrl, "https://baking.example.com/sourdough-rises");
  assert.equal(pageText.lang, "en");
  assert.equal(pageText.description, "Wild yeast, lactic acid bacteria and time.");
  assert.equal(pageText.publishedDate, "2026-03-14T09:30:00Z");
  assert.equal(pageText.truncated, false);

  const lines = pageText.text.split("\n");
  assert.equal(lines[0], "# How Sourdough Rises");
  assert.ok(lines.includes("## What you need"));
  assert.ok(lines.includes("- Flour"));
  assert.ok(lines.includes("  - Filtered is best"), "nested list items are indented");
  assert.ok(lines.includes("Item | Price"));
  assert.ok(lines.includes("Starter kit | $12.50"));
  assert.ok(lines.includes("A sourdough starter is a culture of wild yeast and lactic acid bacteria."), "whitespace is collapsed");
  assert.ok(lines.includes("wait(12h)"), "preformatted lines are kept");

  for (const furniture of ["Home", "cookies", "Popular stories", "© The Baking Journal", "Share on social", "Tags: bread", "hidden", "trackEverything", "color: red"]) {
    assert.ok(!pageText.text.includes(furniture), `"${furniture}" should not be in the text`);
  }
  assert.ok(pageText.wordCount > 20);
});

test("a docs page reads <main>, not the sidebar", { skip: skipWithoutLinkedom }, () => {
  const pageText = pageReader.readPageText(fixtureDocument("docs-with-sidebar"));
  assert.ok(pageText.text.startsWith("# Configuring the CLI"));
  assert.ok(pageText.text.includes("### verbose"), "role=heading with aria-level counts as a heading");
  assert.ok(pageText.text.includes("The CLI reads toolkit.json from the project root."));
  assert.ok(!pageText.text.includes("Getting started"));
  assert.ok(!pageText.text.includes("Install"));
  assert.ok(!pageText.text.includes("Next: Plugins"));
  assert.equal(pageText.canonicalUrl, "");
  assert.equal(pageText.publishedDate, "");
});

test("the outline lists the content's headings with their levels", { skip: skipWithoutLinkedom }, () => {
  const outline = pageReader.readPageOutline(fixtureDocument("docs-with-sidebar"));
  assert.deepEqual(outline.headings, [
    { level: 1, text: "Configuring the CLI" },
    { level: 2, text: "Options" },
    { level: 3, text: "verbose" },
    { level: 3, text: "timeout" },
  ]);
  assert.equal(outline.truncated, false);
});

test("a page with a password field never yields a field value or an ignored region", { skip: skipWithoutLinkedom }, () => {
  const pageText = pageReader.readPageText(fixtureDocument("login-with-password"));
  assert.ok(pageText.text.includes("# Sign in to Example Bank"));
  assert.ok(pageText.text.includes("Need help? Call us."));
  for (const secret of ["hunter2-secret", "4111111111111111", "928374", "ada@example.com", "draft note text", "99887766"]) {
    assert.ok(!pageText.text.includes(secret), `"${secret}" must not be read`);
  }
});

test("a page longer than the cap is cut and says so", { skip: skipWithoutLinkedom }, () => {
  const longDocument = fixtureDocument("long-page");
  const fullRead = pageReader.readPageText(longDocument);
  assert.equal(fullRead.text.length, 20000);
  assert.equal(fullRead.truncated, true);
  assert.ok(fullRead.characterCount > 20000);
  assert.ok(!fullRead.text.includes("The final sentence of the report."));
  assert.ok(fullRead.wordCount > 20000 / 10, "the word count is of the whole page");

  const shortRead = pageReader.readPageText(longDocument, { maximumCharacters: 500 });
  assert.equal(shortRead.text.length, 500);
  assert.equal(shortRead.truncated, true);

  const oversizedRequest = pageReader.readPageText(longDocument, { maximumCharacters: 1000000 });
  assert.equal(oversizedRequest.text.length, 20000, "never more than the shared cap");
});

// MARK: - Selection

// linkedom has no selection, so a test hands the document one.
function selectText(documentToRead, element, selectedText) {
  const textNode = element.firstChild;
  documentToRead.getSelection = () => ({
    rangeCount: 1,
    anchorNode: textNode,
    focusNode: textNode,
    toString: () => selectedText,
    getRangeAt: () => ({ commonAncestorContainer: textNode }),
  });
}

test("a selection comes back with context on either side", { skip: skipWithoutLinkedom }, () => {
  const articleDocument = fixtureDocument("article");
  const paragraph = [...articleDocument.querySelectorAll("p")].find((element) => element.textContent.includes("sourdough starter"));
  selectText(articleDocument, paragraph, "wild yeast");
  const selection = pageReader.readSelection(articleDocument);
  assert.equal(selection.hasSelection, true);
  assert.equal(selection.selectedText, "wild yeast");
  assert.ok(selection.contextBefore.endsWith("a culture of "));
  assert.ok(selection.contextAfter.startsWith(" and lactic acid"));
});

test("a selection inside an ignored region, or with none, reads as no selection", { skip: skipWithoutLinkedom }, () => {
  const loginDocument = fixtureDocument("login-with-password");
  const ignoredRegion = loginDocument.querySelector("[data-wisp-ignore]");
  selectText(loginDocument, ignoredRegion, "Account number 99887766");
  const ignoredSelection = pageReader.readSelection(loginDocument);
  assert.equal(ignoredSelection.hasSelection, false);
  assert.equal(ignoredSelection.selectedText, "");

  const formSelection = loginDocument.querySelector("form");
  selectText(loginDocument, formSelection, "Email Password");
  assert.equal(pageReader.readSelection(loginDocument).hasSelection, false, "a selection spanning a password field drops out");

  loginDocument.getSelection = () => ({ rangeCount: 0, toString: () => "" });
  assert.equal(pageReader.readSelection(loginDocument).hasSelection, false);
});

// MARK: - Handlers

let fakeChrome;
let injectedReaderCalls;

function makeTab(id, overrides = {}) {
  return { id, windowId: 1, index: id, title: `Tab ${id}`, url: `https://example.com/${id}`, active: false, incognito: false, ...overrides };
}

function grantPagesRead() {
  fakeChrome.state.grantedPermissionNames.add("scripting");
  fakeChrome.state.grantedOrigins.add("<all_urls>");
}

beforeEach(() => {
  fakeChrome = createFakeChrome({
    windows: [
      { id: 1, type: "normal", focused: false },
      { id: 2, type: "normal", focused: true },
    ],
    tabs: [
      makeTab(10, { active: true }),
      makeTab(20, { windowId: 2, active: true, title: "Front tab", url: "https://news.example.com/story" }),
      makeTab(21, { windowId: 2, url: "chrome://settings" }),
      makeTab(22, { windowId: 2, url: "https://chromewebstore.google.com/detail/abc" }),
      makeTab(23, { windowId: 2, incognito: true }),
      makeTab(24, { windowId: 2, url: "file:///Users/ada/notes.html" }),
    ],
  });
  fakeChrome.windows.getLastFocused = async () => ({ ...fakeChrome.state.windows.find((browserWindow) => browserWindow.focused) });
  fakeChrome.extension = { isAllowedFileSchemeAccess: async () => false };

  // Plays the page: the file injection defines the reader, the func call
  // returns whatever the reader would have.
  injectedReaderCalls = [];
  fakeChrome.scripting.executeScript = async (injection) => {
    fakeChrome.calls.push(["scripting.executeScript", injection]);
    if (injection.files) return [{ result: undefined }];
    const [readerFunctionName, readerOptions] = injection.args;
    injectedReaderCalls.push({ tabId: injection.target.tabId, readerFunctionName, readerOptions });
    switch (readerFunctionName) {
      case "readPageText":
        return [{ result: { title: "Story", canonicalUrl: "https://news.example.com/story", lang: "en", description: "", publishedDate: "", text: "x".repeat(25000), wordCount: 1, characterCount: 25000, truncated: false } }];
      case "readSelection":
        return [{ result: { title: "Story", hasSelection: true, selectedText: "the quote", contextBefore: "before ", contextAfter: " after", truncated: false } }];
      case "readPageOutline":
        return [{ result: { title: "Story", headings: [{ level: 1, text: "Story" }, { level: 9, text: "Deep" }, { level: 2, text: "" }], truncated: false } }];
      default:
        throw new Error(`unexpected reader ${readerFunctionName}`);
    }
  };
  globalThis.chrome = fakeChrome;
});

test("every method refuses without pages.read and injects nothing", async () => {
  for (const methodName of ["getPageText", "getSelection", "getPageOutline"]) {
    await assert.rejects(() => pageReadingHandlers[methodName]({}), new RegExp(MISSING_PAGES_READ_ERROR));
  }
  assert.deepEqual(fakeChrome.calls.filter(([apiName]) => apiName === "scripting.executeScript"), []);
});

test("with no tab id, the showing tab of the last focused window is read", async () => {
  grantPagesRead();
  const pageText = await pageReadingHandlers.getPageText({});
  assert.equal(pageText.tabId, 20);
  assert.equal(pageText.windowId, 2);
  assert.equal(pageText.url, "https://news.example.com/story");
  assert.equal(pageText.title, "Story");

  const injections = fakeChrome.calls.filter(([apiName]) => apiName === "scripting.executeScript").map(([, injection]) => injection);
  assert.deepEqual(injections[0], { target: { tabId: 20 }, files: [PAGE_READER_SCRIPT_FILE] });
  assert.deepEqual(injections[1].target, { tabId: 20 });
});

test("page text is capped at the shared limit, or at a smaller requested one", async () => {
  grantPagesRead();
  const fullRead = await pageReadingHandlers.getPageText({ tabId: 10 });
  assert.equal(fullRead.tabId, 10);
  assert.equal(fullRead.text.length, 20000);
  assert.equal(fullRead.truncated, true);

  const smallRead = await pageReadingHandlers.getPageText({ tabId: 10, maximumCharacters: 6000 });
  assert.equal(smallRead.text.length, 6000);
  assert.equal(injectedReaderCalls.at(-1).readerOptions.maximumCharacters, 6000);
});

test("forbidden and incognito tabs are refused before anything is injected", async () => {
  grantPagesRead();
  await assert.rejects(() => pageReadingHandlers.getPageText({ tabId: 21 }), /doesn't read chrome: pages/);
  await assert.rejects(() => pageReadingHandlers.getPageText({ tabId: 22 }), /extension store/);
  await assert.rejects(() => pageReadingHandlers.getPageText({ tabId: 23 }), /incognito/);
  await assert.rejects(() => pageReadingHandlers.getPageText({ tabId: 24 }), /allow access to file urls/);
  await assert.rejects(() => pageReadingHandlers.getPageText({ tabId: "20" }), /tabId must be a tab id/);
  assert.deepEqual(injectedReaderCalls, []);

  fakeChrome.extension.isAllowedFileSchemeAccess = async () => true;
  const fileRead = await pageReadingHandlers.getPageText({ tabId: 24 });
  assert.equal(fileRead.tabId, 24);
});

test("forbiddenPageReason allows only web pages, and files when allowed", () => {
  assert.equal(forbiddenPageReason("https://example.com/a"), null);
  assert.equal(forbiddenPageReason("http://localhost:3000/"), null);
  for (const forbiddenURL of ["chrome://extensions", "chrome-extension://abc/options.html", "devtools://devtools/bundled/inspector.html", "view-source:https://example.com", "about:blank", "data:text/html,hi", "https://chrome.google.com/webstore/detail/x", "https://microsoftedge.microsoft.com/addons/detail/x", "not a url"]) {
    assert.notEqual(forbiddenPageReason(forbiddenURL), null, forbiddenURL);
  }
  assert.notEqual(forbiddenPageReason("file:///tmp/a.html"), null);
  assert.equal(forbiddenPageReason("file:///tmp/a.html", { isFileSchemeAccessAllowed: true }), null);
});

test("a page Chrome won't script comes back as a plain error", async () => {
  grantPagesRead();
  fakeChrome.scripting.executeScript = async () => {
    throw new Error("Frame with ID 0 is showing error page");
  };
  await assert.rejects(() => pageReadingHandlers.getPageText({ tabId: 20 }), /couldn't read the page: Frame with ID 0 is showing error page/);
});

test("getSelection and getPageOutline return the reader's results, tidied", async () => {
  grantPagesRead();
  const selection = await pageReadingHandlers.getSelection({});
  assert.equal(selection.tabId, 20);
  assert.equal(selection.hasSelection, true);
  assert.equal(selection.selectedText, "the quote");
  assert.equal(selection.contextBefore, "before ");

  const outline = await pageReadingHandlers.getPageOutline({ tabId: 20 });
  assert.deepEqual(outline.headings, [
    { level: 1, text: "Story" },
    { level: 6, text: "Deep" },
  ]);
});
