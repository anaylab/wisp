// Today's nine tab primitives: argument validation, and that they still do
// what they did before the module split.

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { tabHandlers } from "../handlers/tabs.js";
import { capabilityHandlers } from "../handlers/capabilities.js";
import { createFakeChrome } from "./fake-chrome.mjs";

let fakeChrome;

function makeTab(id, overrides = {}) {
  return {
    id,
    windowId: 1,
    index: id,
    title: `Tab ${id}`,
    url: `https://example.com/${id}`,
    pinned: false,
    active: false,
    audible: false,
    mutedInfo: { muted: false },
    groupId: -1,
    lastAccessed: 100 + id,
    ...overrides,
  };
}

beforeEach(() => {
  fakeChrome = createFakeChrome({
    windows: [
      { id: 1, type: "normal", focused: true },
      { id: 2, type: "popup", focused: false },
    ],
    tabs: [makeTab(10), makeTab(11, { groupId: 7 }), makeTab(12, { windowId: 2 })],
    groups: [
      { id: 7, windowId: 1, title: "Docs", color: "blue", collapsed: false },
      { id: 8, windowId: 2, title: "Popup group", color: "red", collapsed: true },
    ],
  });
  // The handlers use the global `chrome`, as they do in the service worker.
  globalThis.chrome = fakeChrome;
});

const BAD_TAB_ID_LISTS = [undefined, null, [], "10", [10, "11"], [1.5], {}];

const TAB_ID_LIST_METHODS = ["groupTabs", "ungroupTabs", "closeTabs", "pinTabs", "muteTabs", "moveTabsToNewWindow"];

for (const methodName of TAB_ID_LIST_METHODS) {
  test(`${methodName} rejects anything but a non-empty list of integer tab ids`, async () => {
    for (const badTabIDs of BAD_TAB_ID_LISTS) {
      await assert.rejects(
        () => tabHandlers[methodName]({ tabIds: badTabIDs }),
        /tabIds must be a non-empty list of tab ids/,
        `${methodName} accepted ${JSON.stringify(badTabIDs)}`
      );
    }
    assert.deepEqual(fakeChrome.calls, []);
  });
}

test("focusTab rejects anything but an integer tab id", async () => {
  for (const badTabID of [undefined, null, "10", 1.5, [10]]) {
    await assert.rejects(() => tabHandlers.focusTab({ tabId: badTabID }), /tabId must be a tab id/);
  }
  assert.deepEqual(fakeChrome.calls, []);
});

test("the handler map holds exactly today's nine primitives", () => {
  assert.deepEqual(Object.keys(tabHandlers).sort(), [
    "closeTabs",
    "focusTab",
    "getTabs",
    "groupTabs",
    "moveTabsToNewWindow",
    "muteTabs",
    "pinTabs",
    "setGroupsCollapsed",
    "ungroupTabs",
  ]);
});

test("getTabs lists only normal windows' tabs and groups, in the shape Wisp decodes", async () => {
  const snapshot = await tabHandlers.getTabs();
  assert.equal(snapshot.focusedWindowId, 1);
  assert.deepEqual(
    snapshot.tabs.map((tab) => tab.id),
    [10, 11]
  );
  assert.deepEqual(snapshot.tabs[1], {
    id: 11,
    windowId: 1,
    index: 11,
    title: "Tab 11",
    url: "https://example.com/11",
    pinned: false,
    active: false,
    audible: false,
    muted: false,
    groupId: 7,
    lastAccessed: 111,
  });
  assert.deepEqual(snapshot.groups, [{ id: 7, windowId: 1, title: "Docs", color: "blue", collapsed: false }]);
});

test("getTabs falls back to pendingUrl and fills missing fields", async () => {
  fakeChrome.state.tabs = [{ id: 20, windowId: 1, index: 0, pendingUrl: "https://loading.example" }];
  const snapshot = await tabHandlers.getTabs();
  assert.deepEqual(snapshot.tabs[0], {
    id: 20,
    windowId: 1,
    index: 0,
    title: "",
    url: "https://loading.example",
    pinned: false,
    active: false,
    audible: false,
    muted: false,
    groupId: -1,
    lastAccessed: 0,
  });
});

test("groupTabs makes a new group in the first tab's window and names it", async () => {
  const result = await tabHandlers.groupTabs({ tabIds: [10], title: "Work", color: "green", collapsed: true });
  assert.deepEqual(fakeChrome.calls[0], ["tabs.group", { tabIds: [10], groupId: undefined, createProperties: { windowId: 1 } }]);
  assert.deepEqual(fakeChrome.calls[1], ["tabGroups.update", result.groupId, { title: "Work", color: "green", collapsed: true }]);
});

test("groupTabs adds to an existing group without renaming it when nothing is given", async () => {
  const result = await tabHandlers.groupTabs({ tabIds: [10], groupId: 7 });
  assert.deepEqual(result, { groupId: 7 });
  assert.equal(fakeChrome.calls.length, 1);
});

test("pinTabs and muteTabs default to on, and turn off only for an explicit false", async () => {
  assert.deepEqual(await tabHandlers.pinTabs({ tabIds: [10, 11] }), { changedCount: 2, pinned: true });
  assert.deepEqual(await tabHandlers.pinTabs({ tabIds: [10], pinned: false }), { changedCount: 1, pinned: false });
  assert.deepEqual(await tabHandlers.muteTabs({ tabIds: [10] }), { changedCount: 1, muted: true });
  assert.deepEqual(await tabHandlers.muteTabs({ tabIds: [10], muted: false }), { changedCount: 1, muted: false });
});

test("setGroupsCollapsed covers every group when none are named", async () => {
  assert.deepEqual(await tabHandlers.setGroupsCollapsed({}), { changedCount: 2, collapsed: true });
  assert.deepEqual(await tabHandlers.setGroupsCollapsed({ groupIds: [7], collapsed: false }), {
    changedCount: 1,
    collapsed: false,
  });
});

test("closeTabs, ungroupTabs, focusTab and moveTabsToNewWindow report what they did", async () => {
  assert.deepEqual(await tabHandlers.ungroupTabs({ tabIds: [11] }), { ungroupedCount: 1 });
  assert.deepEqual(await tabHandlers.focusTab({ tabId: 10 }), { tabId: 10, windowId: 1 });
  const moveResult = await tabHandlers.moveTabsToNewWindow({ tabIds: [10, 11] });
  assert.equal(moveResult.movedCount, 2);
  assert.deepEqual(await tabHandlers.closeTabs({ tabIds: [10] }), { closedCount: 1 });
});

test("getCapabilities and openPermissionsPage", async () => {
  fakeChrome.state.grantedPermissionNames.add("scripting");
  fakeChrome.state.grantedOrigins.add("<all_urls>");
  assert.deepEqual(await capabilityHandlers.getCapabilities({}), { capabilities: ["tabs", "pages.read"] });
  assert.deepEqual(await capabilityHandlers.openPermissionsPage({}), { opened: true });
  assert.equal(fakeChrome.state.optionsPageOpenCount, 1);
});
