// Wisp Tabs — tab life (phase 04): opening a batch of tabs, which is how Wisp
// restores a saved tab session.
//
// Wisp decides what to open (the saved session lives in Wisp, never here) and
// sends one request per window section: the pinned tabs, then each group, then
// each run of ungrouped tabs. This handler only opens what it is told, in the
// order given, and groups it when asked.

import { capList } from "../lib/limits.js";

// One restore can be a whole window of tabs; past this a request is refused
// work, not a convenience. Wisp splits a bigger session into several calls.
export const MAXIMUM_TABS_PER_OPEN_REQUEST = 60;

// Chrome's tab group colours (chrome.tabGroups.Color).
const TAB_GROUP_COLORS = new Set(["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]);

// Web pages, plus Chrome's own pages for a session saved "including chrome
// pages". Never javascript:, data:, file: or another extension's pages: a
// saved session is a list of places to go back to, not something to run.
export function isOpenableURL(url) {
  if (typeof url !== "string" || url.length === 0) return false;
  let parsedURL;
  try {
    parsedURL = new URL(url);
  } catch {
    return false;
  }
  return parsedURL.protocol === "https:" || parsedURL.protocol === "http:" || parsedURL.protocol === "chrome:";
}

export const tabLifeHandlers = {
  // Opens `urls` in order. `windowMode` "new" opens them in a new window,
  // "current" in `windowId` when given (a window an earlier call made),
  // otherwise the focused normal window. Only the first tab is made active, so
  // restoring twenty tabs doesn't load twenty pages at once in front of the
  // user. With `groupTitle` or `groupColor` the opened tabs become one group;
  // with `pinned` they are pinned (Chrome never groups a pinned tab).
  async openTabs({ urls, windowMode = "current", windowId, groupTitle, groupColor, pinned } = {}) {
    if (!Array.isArray(urls) || urls.length === 0) {
      throw new Error("urls must be a non-empty list of web addresses");
    }
    if (windowMode !== "current" && windowMode !== "new") {
      throw new Error('windowMode must be "current" or "new"');
    }
    if (groupColor !== undefined && !TAB_GROUP_COLORS.has(groupColor)) {
      throw new Error("groupColor must be one of Chrome's tab group colours");
    }

    const { items: cappedURLs, truncated } = capList(urls, MAXIMUM_TABS_PER_OPEN_REQUEST);
    const openableURLs = cappedURLs.filter(isOpenableURL);
    const skippedCount = cappedURLs.length - openableURLs.length;
    if (openableURLs.length === 0) {
      throw new Error("none of those addresses can be opened");
    }

    const shouldPin = pinned === true;
    const openedTabIDs = [];
    let targetWindowID;
    let remainingURLs = openableURLs;

    if (windowMode === "new") {
      const newWindow = await chrome.windows.create({ url: openableURLs[0], focused: true });
      targetWindowID = newWindow.id;
      const firstTabID = newWindow.tabs?.[0]?.id;
      if (Number.isInteger(firstTabID)) {
        openedTabIDs.push(firstTabID);
        if (shouldPin) await chrome.tabs.update(firstTabID, { pinned: true });
      }
      remainingURLs = openableURLs.slice(1);
    } else {
      targetWindowID = await resolveCurrentWindowID(windowId);
    }

    for (const url of remainingURLs) {
      const isFirstOpenedTab = openedTabIDs.length === 0;
      const createdTab = await chrome.tabs.create({
        windowId: targetWindowID,
        url,
        active: isFirstOpenedTab,
        pinned: shouldPin,
      });
      openedTabIDs.push(createdTab.id);
    }

    let groupID = null;
    const wantsGroup = typeof groupTitle === "string" || typeof groupColor === "string";
    if (wantsGroup && !shouldPin && openedTabIDs.length > 0) {
      groupID = await chrome.tabs.group({ tabIds: openedTabIDs, createProperties: { windowId: targetWindowID } });
      const groupUpdate = {};
      if (typeof groupTitle === "string") groupUpdate.title = groupTitle;
      if (typeof groupColor === "string") groupUpdate.color = groupColor;
      await chrome.tabGroups.update(groupID, groupUpdate);
    }

    return {
      tabIds: openedTabIDs,
      windowId: targetWindowID,
      groupId: groupID,
      openedCount: openedTabIDs.length,
      skippedCount,
      truncated,
    };
  },
};

// The window a "current" request lands in: the one Wisp named if it is still
// a normal window, else the focused normal window, else the first one.
async function resolveCurrentWindowID(requestedWindowID) {
  const normalWindows = await chrome.windows.getAll({ windowTypes: ["normal"] });
  if (Number.isInteger(requestedWindowID) && normalWindows.some((browserWindow) => browserWindow.id === requestedWindowID)) {
    return requestedWindowID;
  }
  const focusedWindow = normalWindows.find((browserWindow) => browserWindow.focused) ?? normalWindows[0];
  if (focusedWindow) return focusedWindow.id;
  const newWindow = await chrome.windows.create({ focused: true });
  return newWindow.id;
}
