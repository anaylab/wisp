// handlers/dom-controller.js against the fake Chrome, with executeScript played
// by running the real content script in a fake DOM per (tab, frame).

import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";

import { createFakeChrome } from "./fake-chrome.mjs";
import { FakeDocument, el, loadDomAgent, runSerializedFunction } from "./fake-dom.mjs";
import {
  WISP_GROUP_TITLE,
  createDomControllerHandlers,
  mergeFrameSnapshots,
  parseElementID,
  rankElementsByQuery,
  screenPointForElement,
} from "../handlers/dom-controller.js";
import { pageAccessForURL, isNavigableURL } from "../lib/page-access.js";

// A fake Chrome whose executeScript runs in per-frame fake documents.
// `documentsByTarget` is keyed "tabId:frameId".
function makeChromeWithPages({ tabs, documentsByTarget, framesByTabID = {}, windows } = {}) {
  const contextsByTarget = new Map();
  const executeScript = ({ target, files, func, args }) => {
    return target.frameIds.map((frameId) => {
      const targetKey = `${target.tabId}:${frameId}`;
      const fakeDocument = documentsByTarget[targetKey];
      if (!fakeDocument) throw new Error(`Cannot access frame ${targetKey}`);
      if (files) {
        contextsByTarget.set(targetKey, loadDomAgent(fakeDocument, { clock: fakeDocument.clock }));
        return { frameId, result: null };
      }
      const context = contextsByTarget.get(targetKey) ?? emptyContext();
      return { frameId, result: JSON.parse(JSON.stringify(runSerializedFunction(context, func, args) ?? null)) };
    });
  };
  const fakeChrome = createFakeChrome({
    windows: windows ?? [{ id: 1, type: "normal", focused: true, incognito: false, left: 0, top: 25, width: 1200, height: 900 }],
    tabs,
    framesByTabID,
    executeScript,
  });
  return { fakeChrome, contextsByTarget };
}

// A page world that has never had the agent injected.
function emptyContext() {
  const context = vm.createContext({});
  context.window = context;
  return context;
}

function handlersFor(fakeChrome, { clock } = {}) {
  return createDomControllerHandlers({
    chromeAPI: () => fakeChrome,
    currentTimeMilliseconds: () => clock?.now ?? 0,
    sleep: async (milliseconds) => {
      if (clock) clock.now += milliseconds;
    },
  });
}

function shopPage() {
  const fakeDocument = new FakeDocument({ title: "Shop", url: "https://shop.example/" });
  fakeDocument.body.append(
    el("input", { attributes: { "aria-label": "Search products" } }),
    el("button", { text: "Search" }),
    el("a", { attributes: { href: "https://shop.example/cart" }, text: "Cart" })
  );
  return fakeDocument;
}

test("element ids: top frame plain, cross-origin frames prefixed; anything else rejected", () => {
  assert.deepEqual(parseElementID("e7"), { frameId: 0, localElementId: "e7" });
  assert.deepEqual(parseElementID("f12e3"), { frameId: 12, localElementId: "e3" });
  assert.equal(parseElementID("e7'); alert(1)//"), null);
  assert.equal(parseElementID("button"), null);
  assert.equal(parseElementID(7), null);
});

test("page access: web pages act, local files only read, protected pages refused", () => {
  assert.equal(pageAccessForURL("https://example.com/"), "act");
  assert.equal(pageAccessForURL("about:blank"), "blank");
  assert.equal(pageAccessForURL(""), "blank");
  assert.equal(pageAccessForURL("chrome://settings"), "refused");
  assert.equal(pageAccessForURL("chrome-extension://abc/options.html"), "refused");
  assert.equal(pageAccessForURL("devtools://devtools/bundled/inspector.html"), "refused");
  assert.equal(pageAccessForURL("https://chromewebstore.google.com/detail/x"), "refused");
  assert.equal(pageAccessForURL("https://chrome.google.com/webstore/detail/x"), "refused");
  assert.equal(pageAccessForURL("https://chrome.google.com/intl/en/chrome/"), "act");
  assert.equal(pageAccessForURL("file:///Users/me/notes.html"), "refused");
  assert.equal(pageAccessForURL("file:///Users/me/notes.html", { isFileSchemeAccessAllowed: true }), "read");
  assert.equal(pageAccessForURL("javascript:alert(1)"), "refused");
  assert.equal(pageAccessForURL("data:text/html,<p>x</p>"), "refused");
  assert.equal(isNavigableURL("https://youtube.com"), true);
  assert.equal(isNavigableURL("about:blank"), true);
  assert.equal(isNavigableURL("javascript:alert(1)"), false);
  assert.equal(isNavigableURL("file:///etc/passwd"), false);
});

test("ranking mirrors the AppleScript controller: exact, prefix, contains, all words", () => {
  const elements = [
    { id: "e0", label: "Sign in with Google" },
    { id: "e1", label: "Sign in" },
    { id: "e2", label: "Help signing in" },
    { id: "e3", label: "In sign we trust" },
    { id: "e4", label: "Cart" },
  ];
  assert.deepEqual(rankElementsByQuery(elements, " Sign In ").map((element) => element.id), ["e1", "e0", "e2", "e3"]);
  assert.deepEqual(rankElementsByQuery(elements, "in sign").map((element) => element.id), ["e3", "e0", "e1", "e2"]);
  assert.deepEqual(rankElementsByQuery(elements, ""), []);
});

test("frame merging spends one budget: dialog, then in view, top frame before frames", () => {
  const merged = mergeFrameSnapshots(
    { elements: [{ id: "e0", label: "Top in view", priority: 1 }, { id: "e1", label: "Top below", priority: 2 }] },
    [{ frameId: 7, snapshot: { elements: [{ id: "e0", label: "Frame dialog", priority: 0 }, { id: "e1", label: "Frame in view", priority: 1 }] } }],
    3
  );
  assert.deepEqual(merged, [
    { id: "f7e0", label: "Frame dialog" },
    { id: "e0", label: "Top in view" },
    { id: "f7e1", label: "Frame in view" },
  ]);
});

test("screen point: window origin + browser chrome + element centre", () => {
  assert.deepEqual(
    screenPointForElement({ left: 100, top: 50, width: 1200, height: 900 }, { centerX: 120, centerY: 210, viewportWidth: 1200, viewportHeight: 800 }),
    { x: 220, y: 360 }
  );
});

test("a snapshot of a background tab reads the page through the injected agent", async () => {
  const { fakeChrome } = makeChromeWithPages({
    tabs: [
      { id: 1, windowId: 1, url: "https://news.example/", active: true, status: "complete" },
      { id: 2, windowId: 1, url: "https://shop.example/", active: false, status: "complete" },
    ],
    documentsByTarget: { "2:0": shopPage() },
  });
  const handlers = handlersFor(fakeChrome);

  const snapshot = await handlers.snapshotPage({ tabId: 2 });

  assert.equal(snapshot.tabId, 2);
  assert.equal(snapshot.title, "Shop");
  assert.deepEqual(snapshot.elements.map((element) => [element.id, element.label]), [["e0", "Search products"], ["e1", "Search"], ["e2", "Cart"]]);
  assert.ok(snapshot.elements.every((element) => !("priority" in element)), "the wire shape matches the AppleScript snapshot");
  // Injected once (files), then called (func) — and on the next call, no re-injection.
  const injections = () => fakeChrome.calls.filter(([name, injection]) => name === "scripting.executeScript" && injection.files);
  assert.equal(injections().length, 1);
  await handlers.snapshotPage({ tabId: 2 });
  assert.equal(injections().length, 1);
});

test("cross-origin frames are read too, with frame-prefixed ids that actions route back", async () => {
  const frameDocument = new FakeDocument({ url: "https://pay.example/widget" });
  const frameButton = el("button", { text: "Frame button" });
  frameDocument.body.append(frameButton);
  const { fakeChrome } = makeChromeWithPages({
    tabs: [{ id: 3, windowId: 1, url: "https://shop.example/", active: true, status: "complete" }],
    documentsByTarget: { "3:0": shopPage(), "3:4": frameDocument },
    framesByTabID: {
      3: [
        { frameId: 0, parentFrameId: -1, url: "https://shop.example/" },
        { frameId: 4, parentFrameId: 0, url: "https://pay.example/widget" },
        { frameId: 5, parentFrameId: 0, url: "https://shop.example/same-origin" },
        { frameId: 6, parentFrameId: 0, url: "chrome-extension://abc/frame.html" },
      ],
    },
  });
  const handlers = handlersFor(fakeChrome);

  const snapshot = await handlers.snapshotPage({ tabId: 3 });
  assert.deepEqual(snapshot.elements.map((element) => element.id), ["e0", "e1", "e2", "f4e0"]);

  assert.deepEqual(await handlers.clickElement({ tabId: 3, elementId: "f4e0" }), { status: "OK", tabId: 3 });
  assert.equal(frameButton.clickCount, 1);
});

test("actions report the agent's status; a bad id never reaches the page", async () => {
  const fakeDocument = new FakeDocument({ url: "https://login.example/" });
  const passwordField = el("input", { attributes: { type: "password", "aria-label": "Password" } });
  fakeDocument.body.append(passwordField);
  const { fakeChrome } = makeChromeWithPages({
    tabs: [{ id: 1, windowId: 1, url: "https://login.example/", active: true, status: "complete" }],
    documentsByTarget: { "1:0": fakeDocument },
  });
  const handlers = handlersFor(fakeChrome);
  await handlers.snapshotPage({});

  assert.deepEqual(await handlers.typeIntoElement({ elementId: "e0", text: "secret" }), { status: "SENSITIVE", tabId: 1 });
  assert.equal(passwordField.value, "");
  assert.deepEqual(await handlers.clickElement({ elementId: "e40" }), { status: "MISSING", tabId: 1 });
  const callsBefore = fakeChrome.calls.length;
  assert.deepEqual(await handlers.clickElement({ elementId: "x'); evil()" }), { status: "MISSING" });
  assert.equal(fakeChrome.calls.length, callsBefore);
});

test("protected, blank and incognito tabs", async () => {
  const { fakeChrome } = makeChromeWithPages({
    tabs: [
      { id: 1, windowId: 1, url: "chrome://settings", active: true, status: "complete" },
      { id: 2, windowId: 1, url: "about:blank", title: "", active: false, status: "complete" },
      { id: 3, windowId: 1, url: "https://secret.example/", incognito: true, active: false, status: "complete" },
    ],
    documentsByTarget: {},
  });
  const handlers = handlersFor(fakeChrome);

  await assert.rejects(handlers.snapshotPage({ tabId: 1 }), /chrome's own pages/);
  await assert.rejects(handlers.clickElement({ tabId: 1, elementId: "e0" }), /chrome's own pages/);
  await assert.rejects(handlers.snapshotPage({ tabId: 3 }), /incognito/);
  const blank = await handlers.snapshotPage({ tabId: 2 });
  assert.deepEqual(blank.elements, []);
  assert.equal(blank.url, "about:blank");
  await assert.rejects(handlers.clickElement({ tabId: 2, elementId: "e0" }), /empty/);
  assert.ok(!fakeChrome.calls.some(([name]) => name === "scripting.executeScript"), "nothing was injected");
});

test("missing scripting permission says how to grant it", async () => {
  const { fakeChrome } = makeChromeWithPages({
    tabs: [{ id: 1, windowId: 1, url: "https://a.example/", active: true, status: "complete" }],
    documentsByTarget: {},
  });
  delete fakeChrome.scripting;
  await assert.rejects(handlersFor(fakeChrome).snapshotPage({}), /allow reading pages/);
});

test("openTab opens a background tab in the focused window, inside an expanded Wisp group", async () => {
  const { fakeChrome } = makeChromeWithPages({
    tabs: [{ id: 1, windowId: 1, url: "https://mine.example/", active: true, status: "complete", groupId: -1 }],
    documentsByTarget: {},
  });
  const handlers = handlersFor(fakeChrome);

  const opened = await handlers.openTab({ url: "about:blank" });

  const createdTab = fakeChrome.state.tabs.find((tab) => tab.id === opened.tabId);
  assert.equal(createdTab.active, false, "the user stays on their own tab");
  assert.equal(createdTab.windowId, 1);
  const wispGroup = fakeChrome.state.groups.find((group) => group.id === opened.groupId);
  assert.equal(wispGroup.title, WISP_GROUP_TITLE);
  assert.equal(wispGroup.color, "purple");
  assert.equal(wispGroup.collapsed, false);

  // A second task tab joins the same group instead of making another.
  const second = await handlers.openTab({ url: "https://b.example/" });
  assert.equal(second.groupId, opened.groupId);
  assert.equal(fakeChrome.state.groups.length, 1);

  await assert.rejects(handlers.openTab({ url: "javascript:alert(1)" }), /only opens web pages/);
});

test("the Wisp group collapses when idle, but never over the tab the user is looking at", async () => {
  const { fakeChrome } = makeChromeWithPages({
    tabs: [
      { id: 1, windowId: 1, url: "https://mine.example/", active: true, groupId: -1 },
      { id: 2, windowId: 1, url: "https://work.example/", active: false, groupId: 9 },
    ],
    documentsByTarget: {},
  });
  fakeChrome.state.groups.push({ id: 9, windowId: 1, title: "Wisp", color: "purple", collapsed: false });
  const handlers = handlersFor(fakeChrome);

  assert.equal((await handlers.getOrCreateWispGroup({ windowId: 1, collapsed: true })).collapsed, true);

  fakeChrome.state.groups[0].collapsed = false;
  fakeChrome.state.tabs[0].active = false;
  fakeChrome.state.tabs[1].active = true;
  assert.equal((await handlers.getOrCreateWispGroup({ windowId: 1, collapsed: true })).collapsed, false);
});

test("waitForSettled waits for load, then for the DOM to go quiet", async () => {
  const clock = { now: 0 };
  const fakeDocument = shopPage();
  fakeDocument.clock = clock;
  const { fakeChrome } = makeChromeWithPages({
    tabs: [{ id: 1, windowId: 1, url: "https://shop.example/", active: true, status: "loading" }],
    documentsByTarget: { "1:0": fakeDocument },
  });
  const handlers = handlersFor(fakeChrome, { clock });
  // The tab finishes loading after a few polls.
  const realGet = fakeChrome.tabs.get;
  fakeChrome.tabs.get = async (tabID) => {
    const tab = await realGet(tabID);
    if (clock.now >= 300) tab.status = "complete";
    return tab;
  };

  const settled = await handlers.waitForSettled({ tabId: 1, waitSeconds: 8 });
  assert.equal(settled.loaded, true);
  assert.equal(settled.settled, true);
  assert.equal(settled.quietReached, true);
  assert.ok(clock.now >= 300 + 400, "it waited out the quiet period");

  // A page that never stops loading reports not loaded at the deadline.
  fakeChrome.tabs.get = async (tabID) => ({ ...(await realGet(tabID)), status: "loading" });
  const notLoaded = await handlers.waitForSettled({ tabId: 1, waitSeconds: 1 });
  assert.deepEqual(notLoaded, { tabId: 1, loaded: false, settled: false });
});

test("findElements places an element on screen only when its tab is showing", async () => {
  const fakeDocument = new FakeDocument({ url: "https://shop.example/", viewportHeight: 800 });
  fakeDocument.body.append(el("button", { text: "Buy", rect: { left: 100, top: 200, width: 40, height: 20 } }));
  const { fakeChrome } = makeChromeWithPages({
    tabs: [{ id: 1, windowId: 1, url: "https://shop.example/", active: true, status: "complete" }],
    documentsByTarget: { "1:0": fakeDocument },
  });
  const handlers = handlersFor(fakeChrome);

  const ranked = await handlers.findElements({ tabId: 1, query: "buy" });
  assert.deepEqual(ranked.elements.map((element) => element.id), ["e0"]);

  const placed = await handlers.findElements({ tabId: 1, elementId: "e0", includeScreenPoint: true });
  // window (0,25) 1200×900, viewport 1200×800 → chrome 100px tall.
  assert.deepEqual(placed.elements, [{ id: "e0", screenPoint: { x: 120, y: 335 } }]);

  fakeChrome.state.tabs[0].active = false;
  const hidden = await handlers.findElements({ tabId: 1, elementId: "e0", includeScreenPoint: true });
  assert.deepEqual(hidden.elements, [{ id: "e0", screenPoint: null }]);
});

test("captureVisibleTab refuses a background tab and strips the data URL", async () => {
  const { fakeChrome } = makeChromeWithPages({
    tabs: [
      { id: 1, windowId: 1, url: "https://front.example/", active: true, status: "complete" },
      { id: 2, windowId: 1, url: "https://back.example/", active: false, status: "complete" },
    ],
    documentsByTarget: {},
  });
  const handlers = handlersFor(fakeChrome);

  await assert.rejects(handlers.captureVisibleTab({ tabId: 2 }), /only capture the tab that's showing/);
  assert.deepEqual(await handlers.captureVisibleTab({ tabId: 1 }), { tabId: 1, format: "jpeg", imageBase64: "RkFLRQ==" });
});

test("navigation: only web pages, and history errors read plainly", async () => {
  const { fakeChrome } = makeChromeWithPages({
    tabs: [{ id: 1, windowId: 1, url: "https://a.example/", active: true, status: "complete" }],
    documentsByTarget: {},
  });
  const handlers = handlersFor(fakeChrome);

  await handlers.navigateTab({ tabId: 1, url: "https://b.example/" });
  assert.equal(fakeChrome.state.tabs[0].url, "https://b.example/");
  await assert.rejects(handlers.navigateTab({ tabId: 1, url: "file:///etc/passwd" }), /only opens web pages/);

  fakeChrome.tabs.goBack = async () => {
    throw new Error("Cannot find a next page in history.");
  };
  await assert.rejects(handlers.goBackInTab({ tabId: 1 }), /no page to go back to/);
  await assert.rejects(handlers.snapshotPage({ tabId: 99 }), /No tab with id/);
});
