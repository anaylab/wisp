// Wisp Tabs — the tab primitives (list, group, ungroup, close, focus, pin,
// mute, collapse, move).
//
// Every decision about *how* to organize tabs is made by Wisp, where it can be
// tested and where the model lives; these handlers only do what they are told,
// and only through Chrome's tab APIs.

// The shape Wisp knows a tab by, shared by `getTabs` and the tab events.
export function describeTab(tab) {
  return {
    id: tab.id,
    windowId: tab.windowId,
    index: tab.index,
    title: tab.title ?? "",
    url: tab.url ?? tab.pendingUrl ?? "",
    pinned: Boolean(tab.pinned),
    active: Boolean(tab.active),
    audible: Boolean(tab.audible),
    muted: Boolean(tab.mutedInfo?.muted),
    groupId: tab.groupId ?? -1,
    lastAccessed: tab.lastAccessed ?? 0,
  };
}

export const tabHandlers = {
  // Every tab in every normal window (not popups or app windows), plus the
  // tab groups that exist, so Wisp can see the whole picture in one call.
  async getTabs() {
    const normalWindows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    const normalWindowIDs = new Set(normalWindows.map((browserWindow) => browserWindow.id));
    const focusedWindowID = normalWindows.find((browserWindow) => browserWindow.focused)?.id ?? null;

    const allTabs = await chrome.tabs.query({});
    const tabs = allTabs.filter((tab) => normalWindowIDs.has(tab.windowId)).map(describeTab);

    const allGroups = await chrome.tabGroups.query({});
    const groups = allGroups
      .filter((group) => normalWindowIDs.has(group.windowId))
      .map((group) => ({
        id: group.id,
        windowId: group.windowId,
        title: group.title ?? "",
        color: group.color,
        collapsed: Boolean(group.collapsed),
      }));

    return { tabs, groups, focusedWindowId: focusedWindowID };
  },

  // Groups tabs (all from one window) into a new group, or adds them to an
  // existing one when groupId is given.
  async groupTabs({ tabIds, title, color, collapsed, groupId }) {
    requireTabIDs(tabIds);
    let resultingGroupID;
    if (typeof groupId === "number") {
      resultingGroupID = await chrome.tabs.group({ tabIds, groupId });
    } else {
      const firstTab = await chrome.tabs.get(tabIds[0]);
      resultingGroupID = await chrome.tabs.group({ tabIds, createProperties: { windowId: firstTab.windowId } });
    }

    const groupUpdate = {};
    if (typeof title === "string") groupUpdate.title = title;
    if (typeof color === "string") groupUpdate.color = color;
    if (typeof collapsed === "boolean") groupUpdate.collapsed = collapsed;
    if (Object.keys(groupUpdate).length > 0) {
      await chrome.tabGroups.update(resultingGroupID, groupUpdate);
    }
    return { groupId: resultingGroupID };
  },

  async ungroupTabs({ tabIds }) {
    requireTabIDs(tabIds);
    await chrome.tabs.ungroup(tabIds);
    return { ungroupedCount: tabIds.length };
  },

  // Closed tabs stay in Chrome's history and "Reopen closed tab", so this is
  // recoverable; Wisp still asks before it runs as an agent tool.
  async closeTabs({ tabIds }) {
    requireTabIDs(tabIds);
    await chrome.tabs.remove(tabIds);
    return { closedCount: tabIds.length };
  },

  // Brings a tab to the front: selects it and raises its window.
  async focusTab({ tabId }) {
    requireTabID(tabId);
    const tab = await chrome.tabs.update(tabId, { active: true });
    await chrome.windows.update(tab.windowId, { focused: true });
    return { tabId, windowId: tab.windowId };
  },

  async pinTabs({ tabIds, pinned }) {
    requireTabIDs(tabIds);
    const shouldPin = pinned !== false;
    for (const tabID of tabIds) {
      await chrome.tabs.update(tabID, { pinned: shouldPin });
    }
    return { changedCount: tabIds.length, pinned: shouldPin };
  },

  // Muting is per tab and reversible; nothing is closed or paused.
  async muteTabs({ tabIds, muted }) {
    requireTabIDs(tabIds);
    const shouldMute = muted !== false;
    for (const tabID of tabIds) {
      await chrome.tabs.update(tabID, { muted: shouldMute });
    }
    return { changedCount: tabIds.length, muted: shouldMute };
  },

  // Collapses or expands tab groups: the ones in groupIds, or every group in
  // every normal window when groupIds is omitted.
  async setGroupsCollapsed({ groupIds, collapsed }) {
    const shouldCollapse = collapsed !== false;
    let targetGroupIDs = groupIds;
    if (!Array.isArray(targetGroupIDs)) {
      const allGroups = await chrome.tabGroups.query({});
      targetGroupIDs = allGroups.map((group) => group.id);
    }
    for (const groupID of targetGroupIDs) {
      await chrome.tabGroups.update(groupID, { collapsed: shouldCollapse });
    }
    return { changedCount: targetGroupIDs.length, collapsed: shouldCollapse };
  },

  // Moves the given tabs into one new window. Pinned and grouped state is
  // dropped by Chrome when a tab changes window, which is expected here.
  async moveTabsToNewWindow({ tabIds }) {
    requireTabIDs(tabIds);
    const [firstTabID, ...remainingTabIDs] = tabIds;
    const newWindow = await chrome.windows.create({ tabId: firstTabID });
    if (remainingTabIDs.length > 0) {
      await chrome.tabs.move(remainingTabIDs, { windowId: newWindow.id, index: -1 });
    }
    return { windowId: newWindow.id, movedCount: tabIds.length };
  },
};

function requireTabID(tabId) {
  if (!Number.isInteger(tabId)) {
    throw new Error("tabId must be a tab id");
  }
}

function requireTabIDs(tabIds) {
  if (!Array.isArray(tabIds) || tabIds.length === 0 || !tabIds.every((tabID) => Number.isInteger(tabID))) {
    throw new Error("tabIds must be a non-empty list of tab ids");
  }
}
