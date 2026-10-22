// Tab life (phase 04): `openTabs`, the batch open Wisp uses to restore a saved
// tab session.

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { tabLifeHandlers, isOpenableURL, MAXIMUM_TABS_PER_OPEN_REQUEST } from "../handlers/tab-life.js";
import { createFakeChrome } from "./fake-chrome.mjs";

let fakeChrome;

// The shared fake has no `tabs.create`, and its `windows.create` doesn't open
// a tab for a `url`. They are added here rather than in fake-chrome.mjs so this
// phase doesn't edit a file other phases are changing at the same time.
function addTabCreation(chromeFake) {
  const { state, calls } = chromeFake;
  function createTabRecord({ windowId, url, active, pinned }) {
    const windowTabs = state.tabs.filter((tab) => tab.windowId === windowId);
    const tab = {
      id: state.nextTabID++,
      windowId,
      index: windowTabs.length,
      title: "",
      url,
      pinned: Boolean(pinned),
      active: Boolean(active),
      audible: false,
      mutedInfo: { muted: false },
      groupId: -1,
      lastAccessed: 0,
    };
    state.tabs.push(tab);
    return tab;
  }
  chromeFake.tabs.create = async (createProperties) => {
    calls.push(["tabs.create", createProperties]);
    return { ...createTabRecord(createProperties) };
  };
  const originalCreateWindow = chromeFake.windows.create;
  chromeFake.windows.create = async (createProperties) => {
    const newWindow = await originalCreateWindow(createProperties);
    const windowTabs = [];
    if (typeof createProperties?.url === "string") {
      windowTabs.push({ ...createTabRecord({ windowId: newWindow.id, url: createProperties.url, active: true }) });
    }
    return { ...newWindow, tabs: windowTabs };
  };
  return chromeFake;
}

beforeEach(() => {
  fakeChrome = addTabCreation(
    createFakeChrome({
      windows: [
        { id: 1, type: "normal", focused: false },
        { id: 2, type: "normal", focused: true },
        { id: 3, type: "popup", focused: false },
      ],
    })
  );
  globalThis.chrome = fakeChrome;
});

function createdTabCalls() {
  return fakeChrome.calls.filter(([apiName]) => apiName === "tabs.create").map(([, properties]) => properties);
}

test("openTabs opens in the focused normal window, only the first tab active", async () => {
  const result = await tabLifeHandlers.openTabs({
    urls: ["https://a.example/", "https://b.example/", "https://c.example/"],
  });

  assert.equal(result.windowId, 2);
  assert.equal(result.openedCount, 3);
  assert.equal(result.tabIds.length, 3);
  assert.equal(result.groupId, null);
  assert.equal(result.skippedCount, 0);
  assert.equal(result.truncated, false);
  assert.deepEqual(
    createdTabCalls().map((properties) => [properties.windowId, properties.url, properties.active, properties.pinned]),
    [
      [2, "https://a.example/", true, false],
      [2, "https://b.example/", false, false],
      [2, "https://c.example/", false, false],
    ]
  );
});

test("openTabs uses a window Wisp named, and ignores one that isn't a normal window", async () => {
  const intoWindowOne = await tabLifeHandlers.openTabs({ urls: ["https://a.example/"], windowId: 1 });
  assert.equal(intoWindowOne.windowId, 1);

  const intoPopup = await tabLifeHandlers.openTabs({ urls: ["https://a.example/"], windowId: 3 });
  assert.equal(intoPopup.windowId, 2, "a popup isn't a place to restore tabs, so the focused window is used");
});

test("openTabs in a new window opens the first address with the window and the rest as tabs", async () => {
  const result = await tabLifeHandlers.openTabs({
    urls: ["https://a.example/", "https://b.example/"],
    windowMode: "new",
    groupTitle: "Thesis",
    groupColor: "purple",
  });

  const windowCreateCalls = fakeChrome.calls.filter(([apiName]) => apiName === "windows.create");
  assert.equal(windowCreateCalls.length, 1);
  assert.equal(windowCreateCalls[0][1].url, "https://a.example/");
  assert.equal(result.openedCount, 2);
  assert.deepEqual(
    createdTabCalls().map((properties) => [properties.windowId, properties.url, properties.active]),
    [[result.windowId, "https://b.example/", false]]
  );

  // Both tabs end up in one group with the saved title and colour.
  assert.equal(typeof result.groupId, "number");
  const group = fakeChrome.state.groups.find((candidateGroup) => candidateGroup.id === result.groupId);
  assert.equal(group.title, "Thesis");
  assert.equal(group.color, "purple");
  assert.equal(group.windowId, result.windowId);
  for (const tabID of result.tabIds) {
    assert.equal(fakeChrome.state.tabs.find((tab) => tab.id === tabID).groupId, result.groupId);
  }
});

test("openTabs pins when asked and never groups pinned tabs", async () => {
  const result = await tabLifeHandlers.openTabs({
    urls: ["https://mail.example/", "https://cal.example/"],
    pinned: true,
    groupTitle: "Ignored",
  });
  assert.equal(result.groupId, null);
  assert.ok(createdTabCalls().every((properties) => properties.pinned === true));
  assert.equal(fakeChrome.calls.filter(([apiName]) => apiName === "tabs.group").length, 0);
});

test("openTabs pins the first tab of a new window too", async () => {
  const result = await tabLifeHandlers.openTabs({ urls: ["https://mail.example/"], windowMode: "new", pinned: true });
  const pinCalls = fakeChrome.calls.filter(([apiName, , properties]) => apiName === "tabs.update" && properties.pinned);
  assert.deepEqual(pinCalls.map(([, tabID]) => tabID), result.tabIds);
});

test("openTabs skips addresses that aren't pages to go back to", async () => {
  const result = await tabLifeHandlers.openTabs({
    urls: [
      "javascript:alert(1)",
      "https://ok.example/",
      "data:text/html,hi",
      "file:///etc/passwd",
      "chrome-extension://abc/page.html",
      "chrome://history/",
      "not a url",
      42,
    ],
  });
  assert.equal(result.openedCount, 2);
  assert.equal(result.skippedCount, 6);
  assert.deepEqual(createdTabCalls().map((properties) => properties.url), ["https://ok.example/", "chrome://history/"]);
});

test("openTabs caps one request at 60 tabs and says so", async () => {
  const manyURLs = Array.from({ length: 75 }, (_, offset) => `https://site${offset}.example/`);
  const result = await tabLifeHandlers.openTabs({ urls: manyURLs });
  assert.equal(MAXIMUM_TABS_PER_OPEN_REQUEST, 60);
  assert.equal(result.openedCount, 60);
  assert.equal(result.truncated, true);
});

test("openTabs rejects bad arguments before touching Chrome", async () => {
  const badArguments = [
    undefined,
    {},
    { urls: [] },
    { urls: "https://a.example/" },
    { urls: ["https://a.example/"], windowMode: "incognito" },
    { urls: ["https://a.example/"], groupColor: "#ff0000" },
    { urls: ["javascript:alert(1)"] },
  ];
  for (const badArgument of badArguments) {
    await assert.rejects(() => tabLifeHandlers.openTabs(badArgument), undefined, JSON.stringify(badArgument));
  }
  assert.deepEqual(fakeChrome.calls, []);
});

test("isOpenableURL allows web and chrome pages only", () => {
  assert.equal(isOpenableURL("https://a.example/"), true);
  assert.equal(isOpenableURL("http://localhost:3000/"), true);
  assert.equal(isOpenableURL("chrome://settings/"), true);
  assert.equal(isOpenableURL("javascript:void(0)"), false);
  assert.equal(isOpenableURL("about:blank"), false);
  assert.equal(isOpenableURL(""), false);
  assert.equal(isOpenableURL(null), false);
});
