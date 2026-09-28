// Wisp Tabs — background service worker.
//
// This extension is deliberately thin. It holds one WebSocket to Wisp on this
// Mac and exposes a handful of tab primitives (list, group, ungroup, close).
// Every decision about *how* to organize tabs is made by Wisp, where it
// can be tested and where the model lives; the extension only does what it is
// told, and only through Chrome's tab APIs.
//
// Why a WebSocket that the extension dials out on: an MV3 service worker cannot
// listen for connections, and Wisp already runs on the same machine. The socket
// only ever goes to 127.0.0.1, and Wisp only accepts it because the handshake's
// Origin is this extension's fixed ID (pinned by the "key" in manifest.json).

const WISP_BRIDGE_URL = "ws://127.0.0.1:47823";
const EXTENSION_VERSION = chrome.runtime.getManifest().version;

// Chrome ends an idle MV3 service worker after ~30s. Traffic on an open
// WebSocket extends its life (Chrome 116+), so a small ping keeps it resident
// while Wisp is connected.
const KEEP_ALIVE_INTERVAL_MILLISECONDS = 20 * 1000;

// When Wisp isn't running there is no socket to keep the worker alive, so an
// alarm wakes it to try again. 30s is the shortest period Chrome allows.
const RECONNECT_ALARM_NAME = "wisp-reconnect";
const RECONNECT_ALARM_PERIOD_MINUTES = 0.5;

let wispSocket = null;
let keepAliveTimerID = null;

// MARK: - Connection

function connectToWisp() {
  if (wispSocket && (wispSocket.readyState === WebSocket.OPEN || wispSocket.readyState === WebSocket.CONNECTING)) {
    return;
  }

  let socket;
  try {
    socket = new WebSocket(WISP_BRIDGE_URL);
  } catch (error) {
    recordConnectionStatus(false);
    return;
  }
  wispSocket = socket;

  socket.onopen = () => {
    sendToWisp({ type: "hello", extensionVersion: EXTENSION_VERSION, browserName: browserName() });
    startKeepAlive();
    recordConnectionStatus(true);
  };

  socket.onmessage = (event) => {
    handleMessageFromWisp(event.data);
  };

  socket.onclose = () => {
    if (wispSocket === socket) {
      wispSocket = null;
    }
    stopKeepAlive();
    recordConnectionStatus(false);
  };

  // A failed connect fires onerror then onclose; onclose does the cleanup.
  socket.onerror = () => {};
}

function sendToWisp(message) {
  if (wispSocket && wispSocket.readyState === WebSocket.OPEN) {
    wispSocket.send(JSON.stringify(message));
  }
}

function startKeepAlive() {
  stopKeepAlive();
  keepAliveTimerID = setInterval(() => sendToWisp({ type: "ping" }), KEEP_ALIVE_INTERVAL_MILLISECONDS);
}

function stopKeepAlive() {
  if (keepAliveTimerID !== null) {
    clearInterval(keepAliveTimerID);
    keepAliveTimerID = null;
  }
}

function recordConnectionStatus(isConnectedToWisp) {
  chrome.storage.session.set({ isConnectedToWisp, connectionStatusChangedAt: Date.now() });
}

function browserName() {
  const userAgentBrands = navigator.userAgentData?.brands ?? [];
  const namedBrand = userAgentBrands.find((brand) => !/not.a.brand|chromium/i.test(brand.brand));
  return namedBrand?.brand ?? "Chrome";
}

// MARK: - Requests from Wisp

async function handleMessageFromWisp(rawMessage) {
  let request;
  try {
    request = JSON.parse(rawMessage);
  } catch (error) {
    return;
  }
  if (typeof request.id !== "number" || typeof request.method !== "string") {
    return;
  }

  const handler = requestHandlers[request.method];
  if (!handler) {
    sendToWisp({ id: request.id, error: `unknown method ${request.method}` });
    return;
  }

  try {
    const result = await handler(request.params ?? {});
    sendToWisp({ id: request.id, result: result ?? {} });
  } catch (error) {
    sendToWisp({ id: request.id, error: String(error?.message ?? error) });
  }
}

const requestHandlers = {
  // Every tab in every normal window (not popups or app windows), plus the
  // tab groups that exist, so Wisp can see the whole picture in one call.
  async getTabs() {
    const normalWindows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    const normalWindowIDs = new Set(normalWindows.map((browserWindow) => browserWindow.id));
    const focusedWindowID = normalWindows.find((browserWindow) => browserWindow.focused)?.id ?? null;

    const allTabs = await chrome.tabs.query({});
    const tabs = allTabs
      .filter((tab) => normalWindowIDs.has(tab.windowId))
      .map((tab) => ({
        id: tab.id,
        windowId: tab.windowId,
        index: tab.index,
        title: tab.title ?? "",
        url: tab.url ?? tab.pendingUrl ?? "",
        pinned: Boolean(tab.pinned),
        active: Boolean(tab.active),
        audible: Boolean(tab.audible),
        groupId: tab.groupId ?? -1,
        lastAccessed: tab.lastAccessed ?? 0,
      }));

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
};

function requireTabIDs(tabIds) {
  if (!Array.isArray(tabIds) || tabIds.length === 0 || !tabIds.every((tabID) => Number.isInteger(tabID))) {
    throw new Error("tabIds must be a non-empty list of tab ids");
  }
}

// MARK: - Lifecycle

chrome.alarms.create(RECONNECT_ALARM_NAME, { periodInMinutes: RECONNECT_ALARM_PERIOD_MINUTES });

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM_NAME) connectToWisp();
});

chrome.runtime.onStartup.addListener(connectToWisp);
chrome.runtime.onInstalled.addListener(connectToWisp);

// The popup's "Try again" button.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "reconnect") {
    connectToWisp();
    sendResponse({ ok: true });
  }
});

connectToWisp();
