// handlers/pointing.js and events/pointing.js against the fake Chrome, with
// executeScript played by running the real content/highlight.js in a fake
// page per (tab, frame).

import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";

import { createFakeChrome, createFakeEvent } from "./fake-chrome.mjs";
import { FakeDocument, el, runSerializedFunction } from "./fake-dom.mjs";
import { loadHighlighter } from "./fake-highlight-page.mjs";
import { createPointingHandlers, groupItemsByFrame, wireElementID } from "../handlers/pointing.js";
import { pointingEventFromMessage, startPointingEvents } from "../events/pointing.js";

const EXTENSION_ID = "kpblnefdnmlodeagdnfodnbbdbkacnce";

function makePage(buttonIDs) {
  const fakeDocument = new FakeDocument();
  for (const [buttonIndex, buttonID] of buttonIDs.entries()) {
    fakeDocument.body.append(el("button", {
      attributes: { "data-wisp-id": buttonID },
      text: `Button ${buttonID}`,
      rect: { left: 10, top: 10 + buttonIndex * 30, width: 80, height: 20 },
    }));
  }
  return fakeDocument;
}

// executeScript over per-frame fake pages; `pagesByTarget` is keyed "tabId:frameId".
function makeChromeWithPages({ tabs, pagesByTarget, framesByTabID = {} }) {
  const loadedByTarget = new Map();
  const executeScript = ({ target, files, func, args }) => target.frameIds.map((frameId) => {
    const targetKey = `${target.tabId}:${frameId}`;
    const fakeDocument = pagesByTarget[targetKey];
    if (!fakeDocument) throw new Error(`Cannot access frame ${targetKey}`);
    if (files) {
      loadedByTarget.set(targetKey, loadHighlighter(fakeDocument));
      return { frameId, result: null };
    }
    const context = loadedByTarget.get(targetKey)?.context ?? emptyContext();
    return { frameId, result: JSON.parse(JSON.stringify(runSerializedFunction(context, func, args) ?? null)) };
  });
  const fakeChrome = createFakeChrome({ tabs, framesByTabID, executeScript });
  return { fakeChrome, loadedByTarget };
}

function emptyContext() {
  const context = vm.createContext({});
  context.window = context;
  return context;
}

const githubTab = { id: 7, windowId: 1, active: true, url: "https://github.com/settings", title: "Settings" };

test("ids are split by frame and put back together", () => {
  const { itemsByFrameID, unparseableElementIDs } = groupItemsByFrame([
    { elementId: "e1", kind: "ring" },
    { elementId: "f12e3", kind: "box" },
    { elementId: "nonsense" },
  ]);
  assert.deepEqual([...itemsByFrameID.keys()], [0, 12]);
  assert.equal(itemsByFrameID.get(12)[0].elementId, "e3");
  assert.equal(itemsByFrameID.get(12)[0].wireElementId, "f12e3");
  assert.deepEqual(unparseableElementIDs, ["nonsense"]);
  assert.equal(wireElementID(0, "e4"), "e4");
  assert.equal(wireElementID(9, "e4"), "f9e4");
});

test("highlightElements injects the highlighter once and reports what it drew", async () => {
  const { fakeChrome, loadedByTarget } = makeChromeWithPages({
    tabs: [githubTab],
    pagesByTarget: { "7:0": makePage(["e1", "e2"]) },
  });
  const handlers = createPointingHandlers({ chromeAPI: () => fakeChrome });

  const firstResult = await handlers.highlightElements({
    items: [{ elementId: "e1", kind: "step", stepNumber: 1, label: "Settings" }, { elementId: "e9", kind: "ring" }],
    color: "rgb(52, 199, 89)",
  });
  assert.deepEqual(firstResult, { tabId: 7, shown: ["e1"], missing: ["e9"] });
  const page = loadedByTarget.get("7:0");
  assert.equal(page.highlighter.state.marks.length, 1);
  assert.equal(page.highlighter.state.hostElement.style["--wisp-mark-color"], "rgb(52, 199, 89)");

  // A second call replaces the marks, without injecting the file again.
  const injectionCountBefore = fakeChrome.calls.filter(([name, injection]) => name === "scripting.executeScript" && injection.files).length;
  await handlers.highlightElements({ tabId: 7, items: [{ elementId: "e2", kind: "ring" }] });
  const injectionCountAfter = fakeChrome.calls.filter(([name, injection]) => name === "scripting.executeScript" && injection.files).length;
  assert.equal(injectionCountAfter, injectionCountBefore);
  assert.deepEqual([...page.highlighter.state.marks.map((mark) => mark.elementId)], ["e2"]);

  await handlers.clearHighlights({});
  assert.equal(page.highlighter.state.marks.length, 0);
});

test("elements in a cross-origin frame are marked in that frame", async () => {
  const { fakeChrome, loadedByTarget } = makeChromeWithPages({
    tabs: [githubTab],
    pagesByTarget: { "7:0": makePage(["e1"]), "7:12": makePage(["e3"]) },
    framesByTabID: {
      7: [
        { frameId: 0, parentFrameId: -1, url: "https://github.com/settings" },
        { frameId: 12, parentFrameId: 0, url: "https://embed.example/widget" },
      ],
    },
  });
  const handlers = createPointingHandlers({ chromeAPI: () => fakeChrome });
  const result = await handlers.highlightElements({
    tabId: 7,
    items: [{ elementId: "e1", kind: "ring" }, { elementId: "f12e3", kind: "box" }, { elementId: "f13e1", kind: "box" }],
  });
  assert.deepEqual(result.shown, ["e1", "f12e3"]);
  assert.deepEqual(result.missing, ["f13e1"]);
  assert.equal(loadedByTarget.get("7:12").highlighter.state.marks[0].elementId, "e3");

  // Clearing reaches the frame too.
  await handlers.clearHighlights({ tabId: 7 });
  assert.equal(loadedByTarget.get("7:12").highlighter.state.marks.length, 0);
});

test("protected, blank and incognito tabs are refused", async () => {
  const handlers = (tab) => createPointingHandlers({ chromeAPI: () => makeChromeWithPages({ tabs: [tab], pagesByTarget: {} }).fakeChrome });
  await assert.rejects(
    handlers({ ...githubTab, url: "chrome://settings" }).highlightElements({ tabId: 7, items: [] }),
    /chrome's own pages/
  );
  await assert.rejects(
    handlers({ ...githubTab, url: "https://chromewebstore.google.com/detail/x" }).watchClicks({ tabId: 7, elementIds: ["e1"] }),
    /web store/
  );
  await assert.rejects(handlers({ ...githubTab, url: "about:blank" }).highlightElements({ tabId: 7, items: [] }), /empty/);
  await assert.rejects(handlers({ ...githubTab, incognito: true }).highlightElements({ tabId: 7, items: [] }), /incognito/);
});

test("without the scripting permission it says how to allow it", async () => {
  const fakeChrome = createFakeChrome({ tabs: [githubTab] });
  delete fakeChrome.scripting;
  const handlers = createPointingHandlers({ chromeAPI: () => fakeChrome });
  await assert.rejects(handlers.highlightElements({ tabId: 7, items: [] }), /allow reading pages/);
});

test("watchClicks watches the found elements and stopWatchingClicks ends it", async () => {
  const { fakeChrome, loadedByTarget } = makeChromeWithPages({
    tabs: [githubTab],
    pagesByTarget: { "7:0": makePage(["e1", "e2"]) },
  });
  const handlers = createPointingHandlers({ chromeAPI: () => fakeChrome });
  const watchResult = await handlers.watchClicks({ tabId: 7, elementIds: ["e2", "e8"] });
  assert.deepEqual(watchResult, { tabId: 7, watching: ["e2"], missing: ["e8"] });
  const page = loadedByTarget.get("7:0");
  assert.deepEqual([...page.highlighter.state.watchedElementIDs], ["e2"]);

  // Watching something new replaces the old watch.
  await handlers.watchClicks({ tabId: 7, elementIds: ["e1"] });
  assert.deepEqual([...page.highlighter.state.watchedElementIDs], ["e1"]);

  assert.deepEqual(await handlers.stopWatchingClicks({}), { stopped: true });
  assert.deepEqual([...page.highlighter.state.watchedElementIDs], []);
});

test("clearing a tab that never had marks doesn't inject anything", async () => {
  const { fakeChrome } = makeChromeWithPages({ tabs: [githubTab], pagesByTarget: { "7:0": makePage([]) } });
  const handlers = createPointingHandlers({ chromeAPI: () => fakeChrome });
  await handlers.clearHighlights({ tabId: 7 });
  assert.equal(fakeChrome.calls.some(([name, injection]) => name === "scripting.executeScript" && injection.files), false);
});

test("content-script messages become events with the tab and frame", () => {
  const sender = { id: EXTENSION_ID, tab: { id: 7 }, frameId: 0 };
  assert.deepEqual(
    pointingEventFromMessage({ type: "wisp.pointing", event: "page.elementClicked", data: { elementId: "e4" } }, sender, EXTENSION_ID),
    { eventName: "page.elementClicked", payload: { tabId: 7, elementId: "e4" } }
  );
  assert.deepEqual(
    pointingEventFromMessage(
      { type: "wisp.pointing", event: "page.highlightDismissed", data: { reason: "label", elementIds: ["e1", "<b>"], elementId: "e1" } },
      { ...sender, frameId: 12 },
      EXTENSION_ID
    ),
    { eventName: "page.highlightDismissed", payload: { tabId: 7, reason: "label", elementIds: ["f12e1"], elementId: "f12e1" } }
  );
  // Another extension, an incognito tab, an unknown event or a bad id: dropped.
  const clicked = { type: "wisp.pointing", event: "page.elementClicked", data: { elementId: "e4" } };
  assert.equal(pointingEventFromMessage(clicked, { ...sender, id: "someone-else" }, EXTENSION_ID), null);
  assert.equal(pointingEventFromMessage(clicked, { ...sender, tab: { id: 7, incognito: true } }, EXTENSION_ID), null);
  assert.equal(pointingEventFromMessage({ ...clicked, event: "watch.matched" }, sender, EXTENSION_ID), null);
  assert.equal(pointingEventFromMessage({ ...clicked, data: { elementId: "f1e2" } }, sender, EXTENSION_ID), null);
  assert.equal(pointingEventFromMessage({ type: "other" }, sender, EXTENSION_ID), null);
});

test("startPointingEvents forwards runtime messages to Wisp", async () => {
  const sentEvents = [];
  const fakeChrome = { runtime: { id: EXTENSION_ID, onMessage: createFakeEvent() } };
  startPointingEvents({ chromeAPI: fakeChrome, sendEvent: (eventName, payload) => sentEvents.push([eventName, payload]) });
  await fakeChrome.runtime.onMessage.dispatch(
    { type: "wisp.pointing", event: "page.elementClicked", data: { elementId: "e2" } },
    { id: EXTENSION_ID, tab: { id: 3 }, frameId: 0 }
  );
  await fakeChrome.runtime.onMessage.dispatch({ type: "something-else" }, { id: EXTENSION_ID, tab: { id: 3 } });
  assert.deepEqual(sentEvents, [["page.elementClicked", { tabId: 3, elementId: "e2" }]]);
});
