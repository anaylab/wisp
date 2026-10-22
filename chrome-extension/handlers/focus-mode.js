// Wisp Tabs — focus mode (phase 09).
//
// Wisp decides which tabs are on-task (ChromeFocusPlanner.swift); this file only
// carries the layout out and puts it back. Two rules shape it:
//
// * Nothing is ever closed. Off-task groups are collapsed, off-task tabs that
//   play sound are muted, loose on-task tabs are grouped as "Focus", and
//   distracting tabs may be moved into a minimised "Later" window. Every one of
//   those is undone by `restoreFocusLayout`.
// * The prior state lives in `chrome.storage.session` under a restore token, so
//   a service worker that Chrome stops and wakes again can still restore it.
//   Session storage (like tab ids) lasts only as long as the browser does, which
//   is exactly how long the state means anything.
//
// The user keeps using Chrome while a focus block runs, so restore tolerates a
// world that moved on: a closed tab is skipped, a tab the user dragged out of
// the Later window stays where they put it, and a group the user expanded
// themselves is simply already expanded.

const STORAGE_KEY_PREFIX = "wispFocusLayout:";
const FOCUS_GROUP_TITLE = "Focus";
const FOCUS_GROUP_COLOR = "green";

export const focusModeHandlers = {
  // Params (all lists are Chrome tab/group ids from `getTabs`):
  //   keepTabIds, keepGroupIds        on-task; never collapsed, muted or moved
  //   distractingTabIds               moved to the Later window when asked
  //   moveDistractingToLaterWindow    bool, default false
  //   collapseGroupIds, muteTabIds, focusTabIds   optional explicit lists from
  //       Wisp's planner. When omitted they are derived from the keep lists:
  //       every other group collapses, every other audible tab is muted, and
  //       loose unpinned kept tabs are grouped as "Focus".
  async applyFocusLayout(params = {}) {
    const keepTabIDs = new Set(optionalIDList(params.keepTabIds, "keepTabIds"));
    const keepGroupIDs = new Set(optionalIDList(params.keepGroupIds, "keepGroupIds"));
    const distractingTabIDs = optionalIDList(params.distractingTabIds, "distractingTabIds");
    const shouldMoveDistractingTabs = params.moveDistractingToLaterWindow === true;

    const normalWindows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    const normalWindowIDs = new Set(normalWindows.map((browserWindow) => browserWindow.id));
    const allTabs = (await chrome.tabs.query({})).filter((tab) => normalWindowIDs.has(tab.windowId));
    const allGroups = (await chrome.tabGroups.query({})).filter((group) => normalWindowIDs.has(group.windowId));
    const tabsByID = new Map(allTabs.map((tab) => [tab.id, tab]));
    const groupsByID = new Map(allGroups.map((group) => [group.id, group]));

    // A kept tab is never touched, even if Wisp listed it somewhere else by mistake.
    const collapseGroupIDs = (params.collapseGroupIds !== undefined
      ? optionalIDList(params.collapseGroupIds, "collapseGroupIds")
      : allGroups.map((group) => group.id)
    ).filter((groupID) => !keepGroupIDs.has(groupID) && groupsByID.has(groupID));
    const muteTabIDs = (params.muteTabIds !== undefined
      ? optionalIDList(params.muteTabIds, "muteTabIds")
      : allTabs.filter((tab) => tab.audible).map((tab) => tab.id)
    ).filter((tabID) => !keepTabIDs.has(tabID) && tabsByID.has(tabID));
    const focusTabIDs = (params.focusTabIds !== undefined
      ? optionalIDList(params.focusTabIds, "focusTabIds")
      : [...keepTabIDs]
    ).filter((tabID) => {
      const tab = tabsByID.get(tabID);
      return tab && !tab.pinned && (tab.groupId ?? -1) === -1;
    });
    const tabIDsToMove = shouldMoveDistractingTabs
      ? distractingTabIDs.filter((tabID) => {
          const tab = tabsByID.get(tabID);
          // Pinned tabs were pinned on purpose; moving one would unpin it.
          return tab && !tab.pinned && !keepTabIDs.has(tabID);
        })
      : [];

    const restoreToken = makeRestoreToken();
    const layoutRecord = {
      createdAt: Date.now(),
      collapsedGroups: [],
      mutedTabs: [],
      focusGroups: [],
      movedTabs: [],
      laterWindowId: null,
    };
    const saveRecord = () => chrome.storage.session.set({ [STORAGE_KEY_PREFIX + restoreToken]: layoutRecord });
    // Saved before anything changes and after every step, so a worker stopped
    // half-way still knows what it already did.
    await saveRecord();

    for (const groupID of collapseGroupIDs) {
      const group = groupsByID.get(groupID);
      if (group.collapsed) continue;
      if (await attempt(() => chrome.tabGroups.update(groupID, { collapsed: true }))) {
        layoutRecord.collapsedGroups.push({ groupId: groupID, windowId: group.windowId, title: group.title ?? "" });
      }
    }
    await saveRecord();

    for (const tabID of muteTabIDs) {
      const tab = tabsByID.get(tabID);
      if (tab.mutedInfo?.muted) continue;
      if (await attempt(() => chrome.tabs.update(tabID, { muted: true }))) {
        layoutRecord.mutedTabs.push({ tabId: tabID, url: tab.url ?? "" });
      }
    }
    await saveRecord();

    // One "Focus" group per window: a group can't span windows.
    const focusTabIDsByWindow = new Map();
    for (const tabID of focusTabIDs) {
      const windowID = tabsByID.get(tabID).windowId;
      if (!focusTabIDsByWindow.has(windowID)) focusTabIDsByWindow.set(windowID, []);
      focusTabIDsByWindow.get(windowID).push(tabID);
    }
    for (const [windowID, windowTabIDs] of focusTabIDsByWindow) {
      let focusGroupID = null;
      const grouped = await attempt(async () => {
        focusGroupID = await chrome.tabs.group({ tabIds: windowTabIDs, createProperties: { windowId: windowID } });
        await chrome.tabGroups.update(focusGroupID, { title: FOCUS_GROUP_TITLE, color: FOCUS_GROUP_COLOR });
      });
      if (grouped || focusGroupID !== null) {
        layoutRecord.focusGroups.push({ groupId: focusGroupID, windowId: windowID, tabIds: windowTabIDs });
      }
    }
    await saveRecord();

    if (tabIDsToMove.length > 0) {
      const movedTabs = tabIDsToMove.map((tabID) => {
        const tab = tabsByID.get(tabID);
        return {
          tabId: tabID,
          fromWindowId: tab.windowId,
          fromIndex: tab.index,
          fromGroupId: tab.groupId ?? -1,
          wasActive: Boolean(tab.active),
          url: tab.url ?? "",
        };
      });
      // Recorded before the move: a tab that moved but wasn't recorded could
      // never be brought back.
      layoutRecord.movedTabs = movedTabs;
      await saveRecord();

      const [firstTabID, ...remainingTabIDs] = tabIDsToMove;
      const laterWindow = await chrome.windows.create({ tabId: firstTabID, focused: false, state: "minimized" });
      layoutRecord.laterWindowId = laterWindow.id;
      await saveRecord();
      if (remainingTabIDs.length > 0) {
        await attempt(() => chrome.tabs.move(remainingTabIDs, { windowId: laterWindow.id, index: -1 }));
      }
    }

    return {
      token: restoreToken,
      collapsedGroupCount: layoutRecord.collapsedGroups.length,
      mutedTabCount: layoutRecord.mutedTabs.length,
      focusGroupedTabCount: layoutRecord.focusGroups.reduce((count, focusGroup) => count + focusGroup.tabIds.length, 0),
      movedTabCount: layoutRecord.movedTabs.length,
      laterWindowId: layoutRecord.laterWindowId,
    };
  },

  // Puts back what `applyFocusLayout` changed. Returns `{restored: false}` for
  // a token this browser session doesn't know (Chrome restarted, or it was
  // already restored), so Wisp can forget it.
  async restoreFocusLayout({ token } = {}) {
    if (typeof token !== "string" || token.length === 0) {
      throw new Error("token must be a restore token from applyFocusLayout");
    }
    const storageKey = STORAGE_KEY_PREFIX + token;
    const stored = await chrome.storage.session.get(storageKey);
    const layoutRecord = stored[storageKey];
    if (!layoutRecord) {
      return { restored: false, reason: "unknown token" };
    }

    const normalWindows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    const normalWindowIDs = new Set(normalWindows.map((browserWindow) => browserWindow.id));
    const openTabsByID = new Map((await chrome.tabs.query({})).map((tab) => [tab.id, tab]));
    const openGroupIDs = new Set((await chrome.tabGroups.query({})).map((group) => group.id));
    let skippedTabCount = 0;

    // 1. Moved tabs go home first, so their old groups still exist to rejoin.
    let movedBackTabCount = 0;
    const tabsToReactivate = [];
    const movedTabsInIndexOrder = [...(layoutRecord.movedTabs ?? [])].sort((first, second) => first.fromIndex - second.fromIndex);
    for (const movedTab of movedTabsInIndexOrder) {
      const openTab = openTabsByID.get(movedTab.tabId);
      // Closed, or the user dragged it somewhere else: leave it be.
      if (!openTab || openTab.windowId !== layoutRecord.laterWindowId) {
        skippedTabCount += 1;
        continue;
      }
      let destinationWindowID = movedTab.fromWindowId;
      if (!normalWindowIDs.has(destinationWindowID)) {
        // Its window was closed meanwhile: any other normal window will do.
        destinationWindowID = normalWindows.find((browserWindow) => browserWindow.id !== layoutRecord.laterWindowId)?.id ?? null;
      }
      if (destinationWindowID === null) {
        skippedTabCount += 1;
        continue;
      }
      const movedBack = await attempt(() =>
        chrome.tabs.move(movedTab.tabId, { windowId: destinationWindowID, index: movedTab.fromIndex })
      );
      if (!movedBack) {
        skippedTabCount += 1;
        continue;
      }
      movedBackTabCount += 1;
      if (destinationWindowID === movedTab.fromWindowId && movedTab.fromGroupId !== -1 && openGroupIDs.has(movedTab.fromGroupId)) {
        await attempt(() => chrome.tabs.group({ tabIds: [movedTab.tabId], groupId: movedTab.fromGroupId }));
      }
      if (movedTab.wasActive) tabsToReactivate.push(movedTab.tabId);
    }
    // A Later window that still holds tabs (the user put some there, or a
    // window to return to was gone) is shown again instead of staying hidden.
    if (layoutRecord.laterWindowId !== null && layoutRecord.laterWindowId !== undefined) {
      const remainingTabsInLaterWindow = (await chrome.tabs.query({})).filter((tab) => tab.windowId === layoutRecord.laterWindowId);
      if (remainingTabsInLaterWindow.length > 0) {
        await attempt(() => chrome.windows.update(layoutRecord.laterWindowId, { state: "normal" }));
      }
    }
    for (const tabID of tabsToReactivate) {
      await attempt(() => chrome.tabs.update(tabID, { active: true }));
    }

    // 2. Take the tabs Wisp grouped out of the "Focus" group, if they're still in it.
    let ungroupedTabCount = 0;
    for (const focusGroup of layoutRecord.focusGroups ?? []) {
      const tabIDsStillInFocusGroup = focusGroup.tabIds.filter((tabID) => openTabsByID.get(tabID)?.groupId === focusGroup.groupId);
      skippedTabCount += focusGroup.tabIds.length - tabIDsStillInFocusGroup.length;
      if (tabIDsStillInFocusGroup.length === 0) continue;
      if (await attempt(() => chrome.tabs.ungroup(tabIDsStillInFocusGroup))) {
        ungroupedTabCount += tabIDsStillInFocusGroup.length;
      }
    }

    // 3. Unmute what Wisp muted.
    let unmutedTabCount = 0;
    for (const mutedTab of layoutRecord.mutedTabs ?? []) {
      const openTab = openTabsByID.get(mutedTab.tabId);
      if (!openTab) {
        skippedTabCount += 1;
        continue;
      }
      if (await attempt(() => chrome.tabs.update(mutedTab.tabId, { muted: false }))) {
        unmutedTabCount += 1;
      }
    }

    // 4. Expand what Wisp collapsed.
    let restoredGroupCount = 0;
    for (const collapsedGroup of layoutRecord.collapsedGroups ?? []) {
      if (!openGroupIDs.has(collapsedGroup.groupId)) continue;
      if (await attempt(() => chrome.tabGroups.update(collapsedGroup.groupId, { collapsed: false }))) {
        restoredGroupCount += 1;
      }
    }

    await chrome.storage.session.remove(storageKey);
    return {
      restored: true,
      restoredGroupCount,
      unmutedTabCount,
      ungroupedTabCount,
      movedBackTabCount,
      skippedTabCount,
    };
  },
};

// Runs one Chrome call and reports whether it worked. Focus mode carries on past
// a tab that closed or a group Chrome won't collapse, rather than leaving the
// layout half-applied and unrecorded.
async function attempt(chromeCall) {
  try {
    await chromeCall();
    return true;
  } catch {
    return false;
  }
}

function optionalIDList(ids, parameterName) {
  if (ids === undefined || ids === null) return [];
  if (!Array.isArray(ids) || !ids.every((id) => Number.isInteger(id))) {
    throw new Error(`${parameterName} must be a list of ids`);
  }
  return ids;
}

function makeRestoreToken() {
  const randomPart = Math.random().toString(36).slice(2, 10);
  return `focus-${Date.now().toString(36)}-${randomPart}`;
}
