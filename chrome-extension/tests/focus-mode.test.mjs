// Focus mode (phase 09): applyFocusLayout then restoreFocusLayout puts Chrome
// back exactly, including when a tab was closed or moved during the block.

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { focusModeHandlers } from "../handlers/focus-mode.js";
import { createFakeChrome } from "./fake-chrome.mjs";

let fakeChrome;

function makeTab(id, overrides = {}) {
  return {
    id,
    windowId: 1,
    index: 0,
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

// The shared fake keeps tab order loosely and has no `storage.session.remove`
// or window states. Focus mode is the first phase that cares, so the extra
// behaviour lives here rather than in fake-chrome.mjs, which every wave-2 phase
// edits at the same time.
function addFocusModeBehaviour(fake) {
  fake.storage.session.remove = async (keys) => {
    for (const key of [].concat(keys)) delete fake.state.sessionStorage[key];
  };

  function reindexWindow(windowID) {
    fake.state.tabs
      .filter((tab) => tab.windowId === windowID)
      .sort((first, second) => first.index - second.index)
      .forEach((tab, position) => {
        tab.index = position;
      });
  }

  fake.tabs.move = async (tabIDs, { windowId, index }) => {
    fake.calls.push(["tabs.move", tabIDs, { windowId, index }]);
    const movedTabs = [];
    for (const [offset, tabID] of [].concat(tabIDs).entries()) {
      const tab = fake.state.tabs.find((candidate) => candidate.id === tabID);
      if (!tab) throw new Error(`No tab with id: ${tabID}.`);
      const fromWindowID = tab.windowId;
      tab.windowId = windowId;
      // Changing window drops the group and the pin, as Chrome does.
      if (fromWindowID !== windowId) {
        tab.groupId = -1;
        tab.pinned = false;
      }
      tab.index = index === -1 ? Number.MAX_SAFE_INTEGER : index - 0.5 + offset * 0.001;
      reindexWindow(fromWindowID);
      reindexWindow(windowId);
      movedTabs.push({ ...tab });
    }
    return movedTabs;
  };

  const createWindow = fake.windows.create;
  fake.windows.create = async (createProperties) => {
    const newWindow = await createWindow(createProperties);
    const storedWindow = fake.state.windows.find((browserWindow) => browserWindow.id === newWindow.id);
    storedWindow.state = createProperties?.state ?? "normal";
    storedWindow.focused = createProperties?.focused !== false;
    if (typeof createProperties?.tabId === "number") {
      const movedTab = fake.state.tabs.find((tab) => tab.id === createProperties.tabId);
      movedTab.groupId = -1;
      movedTab.index = 0;
    }
    return { ...storedWindow };
  };

  fake.windows.update = async (windowID, updateProperties) => {
    fake.calls.push(["windows.update", windowID, updateProperties]);
    const browserWindow = fake.state.windows.find((candidate) => candidate.id === windowID);
    Object.assign(browserWindow, updateProperties);
    return { ...browserWindow };
  };

  fake.tabs.ungroup = async (tabIDs) => {
    fake.calls.push(["tabs.ungroup", tabIDs]);
    for (const tabID of [].concat(tabIDs)) {
      fake.state.tabs.find((tab) => tab.id === tabID).groupId = -1;
    }
    // Chrome removes a group once its last tab leaves.
    const usedGroupIDs = new Set(fake.state.tabs.map((tab) => tab.groupId));
    fake.state.groups = fake.state.groups.filter((group) => usedGroupIDs.has(group.id));
  };

  // Chrome closes a window once its last tab leaves it.
  const removeEmptyWindows = () => {
    const windowIDsWithTabs = new Set(fake.state.tabs.map((tab) => tab.windowId));
    fake.state.windows = fake.state.windows.filter((browserWindow) => windowIDsWithTabs.has(browserWindow.id));
  };
  const move = fake.tabs.move;
  fake.tabs.move = async (...moveArguments) => {
    const result = await move(...moveArguments);
    removeEmptyWindows();
    return result;
  };
  return fake;
}

// What a test compares before and after: everything focus mode may touch.
function layoutSnapshot(fake) {
  return {
    windows: fake.state.windows.map((browserWindow) => browserWindow.id).sort(),
    tabs: [...fake.state.tabs]
      .sort((first, second) => first.id - second.id)
      .map((tab) => ({
        id: tab.id,
        windowId: tab.windowId,
        index: tab.index,
        groupId: tab.groupId,
        pinned: Boolean(tab.pinned),
        muted: Boolean(tab.mutedInfo?.muted),
      })),
    groups: [...fake.state.groups]
      .sort((first, second) => first.id - second.id)
      .map((group) => ({ id: group.id, collapsed: Boolean(group.collapsed), title: group.title })),
  };
}

beforeEach(() => {
  // Three groups (one on-task), a playing YouTube tab, a pinned tab, and loose on-task tabs.
  fakeChrome = addFocusModeBehaviour(
    createFakeChrome({
      windows: [{ id: 1, type: "normal", focused: true }],
      tabs: [
        makeTab(10, { index: 0, pinned: true, title: "Mail" }),
        makeTab(11, { index: 1, groupId: 7, title: "Essay outline" }),
        makeTab(12, { index: 2, groupId: 7, title: "Essay sources" }),
        makeTab(13, { index: 3, groupId: 8, title: "Shopping" }),
        makeTab(14, { index: 4, groupId: 9, title: "Trip" }),
        makeTab(15, { index: 5, title: "Essay draft" }),
        makeTab(16, { index: 6, title: "Thesaurus", active: true }),
        makeTab(17, { index: 7, title: "Lo-fi beats", url: "https://youtube.com/watch?v=1", audible: true }),
        makeTab(18, { index: 8, title: "r/all", url: "https://reddit.com/" }),
      ],
      groups: [
        { id: 7, windowId: 1, title: "Essay", color: "blue", collapsed: false },
        { id: 8, windowId: 1, title: "Shopping", color: "red", collapsed: false },
        { id: 9, windowId: 1, title: "Trip", color: "pink", collapsed: true },
      ],
    })
  );
  globalThis.chrome = fakeChrome;
});

const FOCUS_PARAMS = {
  keepTabIds: [11, 12, 15, 16],
  keepGroupIds: [7],
  distractingTabIds: [17, 18],
  moveDistractingToLaterWindow: true,
};

test("apply collapses off-task groups, mutes, groups Focus and moves distractions; restore undoes it all", async () => {
  const before = layoutSnapshot(fakeChrome);

  const applied = await focusModeHandlers.applyFocusLayout(FOCUS_PARAMS);
  assert.match(applied.token, /^focus-/);
  // Group 9 was already collapsed, so only group 8 changed.
  assert.equal(applied.collapsedGroupCount, 1);
  assert.equal(applied.mutedTabCount, 1);
  assert.equal(applied.focusGroupedTabCount, 2);
  assert.equal(applied.movedTabCount, 2);

  const group8 = fakeChrome.state.groups.find((group) => group.id === 8);
  assert.equal(group8.collapsed, true);
  assert.equal(fakeChrome.state.groups.find((group) => group.id === 7).collapsed, false);
  const youtubeTab = fakeChrome.state.tabs.find((tab) => tab.id === 17);
  assert.equal(youtubeTab.mutedInfo.muted, true);
  assert.equal(youtubeTab.windowId, applied.laterWindowId);
  const laterWindow = fakeChrome.state.windows.find((browserWindow) => browserWindow.id === applied.laterWindowId);
  assert.equal(laterWindow.state, "minimized");
  const focusGroup = fakeChrome.state.groups.find((group) => group.title === "Focus");
  assert.ok(focusGroup);
  assert.deepEqual(
    fakeChrome.state.tabs.filter((tab) => tab.groupId === focusGroup.id).map((tab) => tab.id).sort(),
    [15, 16]
  );
  // Nothing is ever closed.
  assert.equal(fakeChrome.state.tabs.length, 9);
  assert.equal(fakeChrome.calls.some(([apiName]) => apiName === "tabs.remove"), false);
  // The prior state is kept under the token.
  assert.ok(fakeChrome.state.sessionStorage[`wispFocusLayout:${applied.token}`]);

  const restored = await focusModeHandlers.restoreFocusLayout({ token: applied.token });
  assert.equal(restored.restored, true);
  assert.equal(restored.skippedTabCount, 0);
  assert.deepEqual(layoutSnapshot(fakeChrome), before);
  assert.equal(fakeChrome.state.sessionStorage[`wispFocusLayout:${applied.token}`], undefined);
});

test("a tab closed mid-focus is skipped and everything else still comes back", async () => {
  const applied = await focusModeHandlers.applyFocusLayout(FOCUS_PARAMS);

  // The user closes the YouTube tab, which focus mode both muted and moved.
  await fakeChrome.tabs.remove([17]);
  const before = layoutSnapshot(fakeChrome);

  const restored = await focusModeHandlers.restoreFocusLayout({ token: applied.token });
  assert.equal(restored.restored, true);
  // 17 is skipped as a moved tab and as a muted tab.
  assert.equal(restored.skippedTabCount, 2);
  assert.equal(restored.movedBackTabCount, 1);
  assert.equal(fakeChrome.state.tabs.find((tab) => tab.id === 18).windowId, 1);
  assert.equal(fakeChrome.state.groups.find((group) => group.id === 8).collapsed, false);
  assert.equal(fakeChrome.state.groups.some((group) => group.title === "Focus"), false);
  assert.notDeepEqual(layoutSnapshot(fakeChrome), before);
});

test("a tab the user dragged out of the Later window stays where they put it", async () => {
  const applied = await focusModeHandlers.applyFocusLayout(FOCUS_PARAMS);
  const userWindow = await fakeChrome.windows.create({});
  // A window needs a tab; give it one so the fake keeps it.
  fakeChrome.state.tabs.push(makeTab(40, { windowId: userWindow.id }));
  await fakeChrome.tabs.move(18, { windowId: userWindow.id, index: 1 });

  const restored = await focusModeHandlers.restoreFocusLayout({ token: applied.token });
  assert.equal(restored.movedBackTabCount, 1);
  assert.equal(fakeChrome.state.tabs.find((tab) => tab.id === 18).windowId, userWindow.id);
  assert.equal(fakeChrome.state.tabs.find((tab) => tab.id === 17).windowId, 1);
});

test("a tab the user left in the Later window when its home window closed gets the Later window shown", async () => {
  fakeChrome.state.windows.push({ id: 2, type: "normal", focused: false });
  fakeChrome.state.tabs.push(makeTab(30, { windowId: 2, index: 0, title: "Netflix", url: "https://netflix.com/" }));
  fakeChrome.state.tabs.push(makeTab(31, { windowId: 2, index: 1, title: "Notes" }));
  const applied = await focusModeHandlers.applyFocusLayout({ ...FOCUS_PARAMS, distractingTabIds: [30] });

  // Window 2 closes (its other tab goes with it).
  fakeChrome.state.tabs = fakeChrome.state.tabs.filter((tab) => tab.windowId !== 2);
  fakeChrome.state.windows = fakeChrome.state.windows.filter((browserWindow) => browserWindow.id !== 2);

  const restored = await focusModeHandlers.restoreFocusLayout({ token: applied.token });
  assert.equal(restored.movedBackTabCount, 1);
  // It lands in another normal window rather than staying hidden.
  assert.equal(fakeChrome.state.tabs.find((tab) => tab.id === 30).windowId, 1);
});

test("explicit lists from Wisp are honoured, and kept tabs and groups are never touched", async () => {
  const applied = await focusModeHandlers.applyFocusLayout({
    keepTabIds: [17],
    keepGroupIds: [8],
    collapseGroupIds: [8, 7],
    muteTabIds: [17],
    focusTabIds: [15],
    distractingTabIds: [17],
    moveDistractingToLaterWindow: true,
  });
  assert.equal(applied.collapsedGroupCount, 1);
  assert.equal(fakeChrome.state.groups.find((group) => group.id === 8).collapsed, false);
  assert.equal(fakeChrome.state.groups.find((group) => group.id === 7).collapsed, true);
  assert.equal(applied.mutedTabCount, 0);
  assert.equal(applied.movedTabCount, 0);
  assert.equal(applied.laterWindowId, null);
  assert.equal(applied.focusGroupedTabCount, 1);
});

test("without the move switch, distracting tabs stay put; pinned tabs never move", async () => {
  const applied = await focusModeHandlers.applyFocusLayout({ ...FOCUS_PARAMS, moveDistractingToLaterWindow: false });
  assert.equal(applied.movedTabCount, 0);
  assert.equal(fakeChrome.state.windows.length, 1);

  const pinnedApplied = await focusModeHandlers.applyFocusLayout({
    distractingTabIds: [10],
    moveDistractingToLaterWindow: true,
  });
  assert.equal(pinnedApplied.movedTabCount, 0);
});

test("restoring an unknown token says so and changes nothing", async () => {
  const restored = await focusModeHandlers.restoreFocusLayout({ token: "focus-gone" });
  assert.deepEqual(restored, { restored: false, reason: "unknown token" });
  assert.deepEqual(fakeChrome.calls, []);
});

test("restoring twice is harmless", async () => {
  const applied = await focusModeHandlers.applyFocusLayout(FOCUS_PARAMS);
  await focusModeHandlers.restoreFocusLayout({ token: applied.token });
  const second = await focusModeHandlers.restoreFocusLayout({ token: applied.token });
  assert.equal(second.restored, false);
});

test("bad arguments are refused before anything changes", async () => {
  await assert.rejects(() => focusModeHandlers.applyFocusLayout({ keepTabIds: ["11"] }), /keepTabIds must be a list of ids/);
  await assert.rejects(() => focusModeHandlers.restoreFocusLayout({}), /token must be a restore token/);
  assert.deepEqual(fakeChrome.calls, []);
});
