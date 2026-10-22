// Tab and window events: which changes are reported, the per-tab debounce,
// incognito, and the payload shape.

import { test } from "node:test";
import assert from "node:assert/strict";

import { startTabEvents, TAB_UPDATE_DEBOUNCE_MILLISECONDS } from "../events/tabs.js";
import { createFakeChrome, createManualTimers } from "./fake-chrome.mjs";

function startEvents({ tabs = [] } = {}) {
  const fakeChrome = createFakeChrome({ tabs });
  const timers = createManualTimers();
  const sentEvents = [];
  startTabEvents({
    chromeAPI: fakeChrome,
    sendEvent: (eventName, eventData) => sentEvents.push({ eventName, eventData }),
    setTimeoutFunction: timers.setTimeout,
    clearTimeoutFunction: timers.clearTimeout,
  });
  return { fakeChrome, timers, sentEvents };
}

function tab(id, overrides = {}) {
  return { id, windowId: 1, index: 0, title: "Loading", url: "https://a.example", status: "loading", ...overrides };
}

test("a burst of updates to one tab becomes one event with every changed field and the latest tab", async () => {
  const { fakeChrome, timers, sentEvents } = startEvents();
  await fakeChrome.tabs.onUpdated.dispatch(5, { status: "loading" }, tab(5));
  timers.advance(100);
  await fakeChrome.tabs.onUpdated.dispatch(5, { url: "https://b.example" }, tab(5, { url: "https://b.example" }));
  timers.advance(100);
  await fakeChrome.tabs.onUpdated.dispatch(5, { title: "B" }, tab(5, { url: "https://b.example", title: "B" }));
  timers.advance(TAB_UPDATE_DEBOUNCE_MILLISECONDS - 1);
  assert.equal(sentEvents.length, 0);
  timers.advance(1);

  assert.equal(sentEvents.length, 1);
  assert.equal(sentEvents[0].eventName, "tab.updated");
  assert.deepEqual(sentEvents[0].eventData, {
    id: 5,
    windowId: 1,
    index: 0,
    title: "B",
    url: "https://b.example",
    pinned: false,
    active: false,
    audible: false,
    muted: false,
    groupId: -1,
    lastAccessed: 0,
    status: "loading",
    changedFields: ["status", "url", "title"],
  });
});

test("updates that change nothing Wisp cares about send nothing", async () => {
  const { fakeChrome, timers, sentEvents } = startEvents();
  await fakeChrome.tabs.onUpdated.dispatch(5, { favIconUrl: "https://a.example/icon.png" }, tab(5));
  await fakeChrome.tabs.onUpdated.dispatch(5, { discarded: true }, tab(5));
  await fakeChrome.tabs.onUpdated.dispatch(5, { groupId: 3 }, tab(5));
  timers.advance(1000);
  assert.deepEqual(sentEvents, []);
});

test("audible changes are reported", async () => {
  const { fakeChrome, timers, sentEvents } = startEvents();
  await fakeChrome.tabs.onUpdated.dispatch(5, { audible: true }, tab(5, { audible: true, status: "complete" }));
  timers.advance(TAB_UPDATE_DEBOUNCE_MILLISECONDS);
  assert.deepEqual(sentEvents[0].eventData.changedFields, ["audible"]);
  assert.equal(sentEvents[0].eventData.audible, true);
});

test("each tab debounces on its own", async () => {
  const { fakeChrome, timers, sentEvents } = startEvents();
  await fakeChrome.tabs.onUpdated.dispatch(5, { status: "loading" }, tab(5));
  timers.advance(200);
  await fakeChrome.tabs.onUpdated.dispatch(6, { status: "loading" }, tab(6));
  timers.advance(50);
  assert.deepEqual(
    sentEvents.map((sentEvent) => sentEvent.eventData.id),
    [5]
  );
  timers.advance(200);
  assert.deepEqual(
    sentEvents.map((sentEvent) => sentEvent.eventData.id),
    [5, 6]
  );
});

test("a tab removed before its update fires sends only the removal", async () => {
  const { fakeChrome, timers, sentEvents } = startEvents();
  await fakeChrome.tabs.onUpdated.dispatch(5, { title: "Bye" }, tab(5));
  await fakeChrome.tabs.onRemoved.dispatch(5, { windowId: 1, isWindowClosing: false });
  timers.advance(1000);
  assert.deepEqual(sentEvents, [
    { eventName: "tab.removed", eventData: { id: 5, windowId: 1, isWindowClosing: false } },
  ]);
});

test("created and activated tabs are sent in the getTabs shape", async () => {
  const { fakeChrome, sentEvents } = startEvents({ tabs: [tab(9, { active: true, title: "Nine" })] });
  await fakeChrome.tabs.onCreated.dispatch(tab(8, { pinned: true }));
  await fakeChrome.tabs.onActivated.dispatch({ tabId: 9, windowId: 1 });
  assert.equal(sentEvents[0].eventName, "tab.created");
  assert.equal(sentEvents[0].eventData.id, 8);
  assert.equal(sentEvents[0].eventData.pinned, true);
  assert.equal(sentEvents[1].eventName, "tab.activated");
  assert.equal(sentEvents[1].eventData.title, "Nine");
  assert.equal(sentEvents[1].eventData.active, true);
});

test("an activated tab that is already gone sends nothing", async () => {
  const { fakeChrome, sentEvents } = startEvents();
  await fakeChrome.tabs.onActivated.dispatch({ tabId: 404, windowId: 1 });
  assert.deepEqual(sentEvents, []);
});

test("incognito tabs are never reported", async () => {
  const { fakeChrome, timers, sentEvents } = startEvents({ tabs: [tab(3, { incognito: true })] });
  await fakeChrome.tabs.onCreated.dispatch(tab(3, { incognito: true }));
  await fakeChrome.tabs.onUpdated.dispatch(3, { title: "Secret" }, tab(3, { incognito: true }));
  await fakeChrome.tabs.onActivated.dispatch({ tabId: 3, windowId: 1 });
  timers.advance(1000);
  assert.deepEqual(sentEvents, []);
});

test("window focus reports the window, or null when Chrome lost focus", async () => {
  const { fakeChrome, sentEvents } = startEvents();
  await fakeChrome.windows.onFocusChanged.dispatch(2);
  await fakeChrome.windows.onFocusChanged.dispatch(-1);
  assert.deepEqual(sentEvents, [
    { eventName: "window.focused", eventData: { focusedWindowId: 2 } },
    { eventName: "window.focused", eventData: { focusedWindowId: null } },
  ]);
});

test("a huge URL is capped and marked truncated", async () => {
  const { fakeChrome, sentEvents } = startEvents();
  const hugeDataURL = `data:text/plain,${"x".repeat(30000)}`;
  await fakeChrome.tabs.onCreated.dispatch(tab(4, { url: hugeDataURL }));
  assert.equal(sentEvents[0].eventData.url.length, 20000);
  assert.equal(sentEvents[0].eventData.truncated, true);
});
