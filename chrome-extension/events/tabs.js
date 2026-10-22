// Wisp Tabs — tab and window events for Wisp.
//
// Lets Wisp follow what happens in Chrome without polling `getTabs`: a tab
// opened, loaded, changed title or started playing sound, closed, came to the
// front, or a window took focus. Events are fire-and-forget and dropped while
// Wisp isn't connected (the bridge never queues), because Wisp re-reads the
// whole picture with `getTabs` whenever it needs it.
//
// Payloads use the tab shape `getTabs` returns (`describeTab`):
//   tab.created    the tab
//   tab.updated    the tab + `status` + `changedFields` (status/url/title/audible)
//   tab.activated  the tab
//   tab.removed    { id, windowId, isWindowClosing }
//   window.focused { focusedWindowId }  (null when Chrome itself lost focus)
//
// Incognito tabs never reach here: the manifest says "incognito": "not_allowed",
// so Chrome doesn't show them to the extension at all. The `incognito` checks
// below are a second lock on the same door.

import { sendEvent as bridgeSendEvent } from "../lib/bridge.js";
import { truncateText } from "../lib/limits.js";
import { describeTab } from "../handlers/tabs.js";

// A loading page fires a burst of updates (status, url, title, favicon…)
// within a few hundred milliseconds; one event per burst is enough.
export const TAB_UPDATE_DEBOUNCE_MILLISECONDS = 250;

// The only changes Wisp cares about. Favicon, discarded, groupId and the like
// would otherwise make the channel chatty.
export const REPORTED_TAB_CHANGE_FIELDS = ["status", "url", "title", "audible"];

const WINDOW_ID_NONE = -1;

// Builds a tab payload with the text fields capped (a data: URL can be huge).
export function tabEventPayload(tab) {
  const describedTab = describeTab(tab);
  const cappedTitle = truncateText(describedTab.title);
  const cappedURL = truncateText(describedTab.url);
  const payload = { ...describedTab, title: cappedTitle.text, url: cappedURL.text };
  if (cappedTitle.truncated || cappedURL.truncated) {
    payload.truncated = true;
  }
  return payload;
}

export function startTabEvents({
  chromeAPI = globalThis.chrome,
  sendEvent = bridgeSendEvent,
  debounceMilliseconds = TAB_UPDATE_DEBOUNCE_MILLISECONDS,
  setTimeoutFunction = globalThis.setTimeout,
  clearTimeoutFunction = globalThis.clearTimeout,
} = {}) {
  // tab id → { timerID, changedFields: Set, latestTab }
  const pendingUpdatesByTabID = new Map();

  function cancelPendingUpdate(tabID) {
    const pendingUpdate = pendingUpdatesByTabID.get(tabID);
    if (pendingUpdate) {
      clearTimeoutFunction(pendingUpdate.timerID);
      pendingUpdatesByTabID.delete(tabID);
    }
  }

  chromeAPI.tabs.onCreated.addListener((tab) => {
    if (tab.incognito) return;
    sendEvent("tab.created", tabEventPayload(tab));
  });

  chromeAPI.tabs.onUpdated.addListener((tabID, changeInfo, tab) => {
    if (tab?.incognito) return;
    const reportedChangeFields = REPORTED_TAB_CHANGE_FIELDS.filter((field) => field in (changeInfo ?? {}));
    if (reportedChangeFields.length === 0) return;

    // Keep the fields from the whole burst, and send the tab as it is at the end.
    const existingPendingUpdate = pendingUpdatesByTabID.get(tabID);
    const changedFields = existingPendingUpdate?.changedFields ?? new Set();
    for (const field of reportedChangeFields) changedFields.add(field);
    if (existingPendingUpdate) clearTimeoutFunction(existingPendingUpdate.timerID);

    const timerID = setTimeoutFunction(() => {
      pendingUpdatesByTabID.delete(tabID);
      sendEvent("tab.updated", {
        ...tabEventPayload(tab),
        status: tab.status ?? "",
        changedFields: REPORTED_TAB_CHANGE_FIELDS.filter((field) => changedFields.has(field)),
      });
    }, debounceMilliseconds);
    pendingUpdatesByTabID.set(tabID, { timerID, changedFields });
  });

  chromeAPI.tabs.onRemoved.addListener((tabID, removeInfo) => {
    // An update still waiting would describe a tab that no longer exists.
    cancelPendingUpdate(tabID);
    sendEvent("tab.removed", {
      id: tabID,
      windowId: removeInfo?.windowId ?? -1,
      isWindowClosing: Boolean(removeInfo?.isWindowClosing),
    });
  });

  chromeAPI.tabs.onActivated.addListener(async ({ tabId: tabID }) => {
    let tab;
    try {
      tab = await chromeAPI.tabs.get(tabID);
    } catch (error) {
      // Closed again before we could look: there's nothing to report.
      return;
    }
    if (tab.incognito) return;
    sendEvent("tab.activated", tabEventPayload(tab));
  });

  chromeAPI.windows.onFocusChanged.addListener((windowID) => {
    sendEvent("window.focused", { focusedWindowId: windowID === WINDOW_ID_NONE ? null : windowID });
  });
}
