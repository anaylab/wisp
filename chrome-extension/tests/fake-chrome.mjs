// An in-memory fake of the parts of `chrome.*` the extension uses, so the
// handlers, events and bridge can be tested with `node --test` and no browser.
//
// It is deliberately small: state is plain arrays, every API is async like
// Chrome's, and every event exposes `dispatch(...args)` so a test can play the
// part of Chrome. Calls that change something are recorded in `fake.calls` as
// `[apiName, ...args]`. Later phases extend it (for example `scripting`).

export function createFakeEvent() {
  const listeners = [];
  return {
    listeners,
    addListener(listener) {
      listeners.push(listener);
    },
    removeListener(listener) {
      const listenerIndex = listeners.indexOf(listener);
      if (listenerIndex >= 0) listeners.splice(listenerIndex, 1);
    },
    hasListener(listener) {
      return listeners.includes(listener);
    },
    // Calls every listener and waits for any that return a promise.
    async dispatch(...eventArguments) {
      await Promise.all(listeners.map((listener) => listener(...eventArguments)));
    },
  };
}

function permissionSetContains(grantedPermissionNames, grantedOrigins, requestedPermissions) {
  const requestedNames = requestedPermissions?.permissions ?? [];
  const requestedOrigins = requestedPermissions?.origins ?? [];
  return (
    requestedNames.every((name) => grantedPermissionNames.has(name)) &&
    requestedOrigins.every((origin) => grantedOrigins.has(origin))
  );
}

export function createFakeChrome({
  windows = [{ id: 1, type: "normal", focused: true, incognito: false }],
  tabs = [],
  groups = [],
  grantedPermissions = [],
  grantedOrigins = [],
  manifestVersion = "1.1.0",
  // Permission names the fake Chrome doesn't know, so `contains` throws like
  // an older Chrome would.
  unknownPermissionNames = [],
  // Phase 03: frames per tab for webNavigation.getAllFrames, and a stand-in
  // for chrome.scripting.executeScript (injection) => results.
  framesByTabID = {},
  executeScript = null,
  // Download items for the `downloads` fake (phase 07).
  downloads = [],
} = {}) {
  const calls = [];
  const state = {
    windows: windows.map((browserWindow) => ({ ...browserWindow })),
    tabs: tabs.map((tab) => ({ ...tab })),
    groups: groups.map((group) => ({ ...group })),
    grantedPermissionNames: new Set(grantedPermissions),
    grantedOrigins: new Set(grantedOrigins),
    alarms: new Map(),
    sessionStorage: {},
    localStorage: {},
    nextTabID: 1000,
    nextGroupID: 500,
    nextWindowID: 50,
    optionsPageOpenCount: 0,
    downloads: downloads.map((downloadItem) => ({ ...downloadItem })),
    shownDownloadIDs: [],
  };

  function findTab(tabID) {
    const tab = state.tabs.find((candidateTab) => candidateTab.id === tabID);
    if (!tab) throw new Error(`No tab with id: ${tabID}.`);
    return tab;
  }

  function findGroup(groupID) {
    const group = state.groups.find((candidateGroup) => candidateGroup.id === groupID);
    if (!group) throw new Error(`No group with id: ${groupID}.`);
    return group;
  }

  function checkPermissionNames(requestedPermissions) {
    for (const name of requestedPermissions?.permissions ?? []) {
      if (unknownPermissionNames.includes(name)) {
        throw new Error(`'${name}' is not a recognized permission.`);
      }
    }
  }

  const fakeChrome = {
    calls,
    state,

    tabs: {
      // Filters only on the query keys a test passes, so `query({})` is every tab.
      async query(queryInfo = {}) {
        const lastFocusedWindowID = state.windows.find((browserWindow) => browserWindow.focused)?.id;
        return state.tabs
          .filter((tab) => !("active" in queryInfo) || Boolean(tab.active) === queryInfo.active)
          .filter((tab) => !("windowId" in queryInfo) || tab.windowId === queryInfo.windowId)
          .filter((tab) => !queryInfo.lastFocusedWindow || tab.windowId === lastFocusedWindowID)
          .map((tab) => ({ ...tab }));
      },
      async create(createProperties) {
        calls.push(["tabs.create", createProperties]);
        const newTab = {
          id: state.nextTabID++,
          windowId: createProperties.windowId ?? 1,
          index: state.tabs.length,
          url: createProperties.url ?? "about:blank",
          title: "",
          active: Boolean(createProperties.active),
          status: "complete",
          groupId: -1,
        };
        state.tabs.push(newTab);
        return { ...newTab };
      },
      async goBack(tabID) {
        calls.push(["tabs.goBack", tabID]);
        findTab(tabID);
      },
      async goForward(tabID) {
        calls.push(["tabs.goForward", tabID]);
        findTab(tabID);
      },
      async captureVisibleTab(windowID, options) {
        calls.push(["tabs.captureVisibleTab", windowID, options]);
        return "data:image/jpeg;base64,RkFLRQ==";
      },
      async get(tabID) {
        return { ...findTab(tabID) };
      },
      async update(tabID, updateProperties) {
        calls.push(["tabs.update", tabID, updateProperties]);
        const tab = findTab(tabID);
        if ("pinned" in updateProperties) tab.pinned = updateProperties.pinned;
        if ("active" in updateProperties) tab.active = updateProperties.active;
        if ("muted" in updateProperties) tab.mutedInfo = { muted: updateProperties.muted };
        if ("url" in updateProperties) tab.url = updateProperties.url;
        return { ...tab };
      },
      async group({ tabIds, groupId, createProperties }) {
        calls.push(["tabs.group", { tabIds, groupId, createProperties }]);
        let targetGroupID = groupId;
        if (typeof targetGroupID !== "number") {
          targetGroupID = state.nextGroupID++;
          state.groups.push({ id: targetGroupID, windowId: createProperties?.windowId ?? 1, title: "", color: "grey", collapsed: false });
        }
        for (const tabID of tabIds) findTab(tabID).groupId = targetGroupID;
        return targetGroupID;
      },
      async ungroup(tabIDs) {
        calls.push(["tabs.ungroup", tabIDs]);
        for (const tabID of [].concat(tabIDs)) findTab(tabID).groupId = -1;
      },
      async remove(tabIDs) {
        calls.push(["tabs.remove", tabIDs]);
        const removedTabIDs = new Set([].concat(tabIDs));
        state.tabs = state.tabs.filter((tab) => !removedTabIDs.has(tab.id));
      },
      async move(tabIDs, moveProperties) {
        calls.push(["tabs.move", tabIDs, moveProperties]);
        for (const tabID of [].concat(tabIDs)) findTab(tabID).windowId = moveProperties.windowId;
        return [].concat(tabIDs).map((tabID) => ({ ...findTab(tabID) }));
      },
      onCreated: createFakeEvent(),
      onUpdated: createFakeEvent(),
      onRemoved: createFakeEvent(),
      onActivated: createFakeEvent(),
    },

    tabGroups: {
      async query() {
        return state.groups.map((group) => ({ ...group }));
      },
      async update(groupID, updateProperties) {
        calls.push(["tabGroups.update", groupID, updateProperties]);
        Object.assign(findGroup(groupID), updateProperties);
        return { ...findGroup(groupID) };
      },
    },

    windows: {
      WINDOW_ID_NONE: -1,
      async getAll({ windowTypes } = {}) {
        return state.windows
          .filter((browserWindow) => !windowTypes || windowTypes.includes(browserWindow.type))
          .map((browserWindow) => ({ ...browserWindow }));
      },
      async get(windowID) {
        const browserWindow = state.windows.find((candidateWindow) => candidateWindow.id === windowID);
        if (!browserWindow) throw new Error(`No window with id: ${windowID}.`);
        return { ...browserWindow };
      },
      async getLastFocused() {
        const focusedWindow = state.windows.find((browserWindow) => browserWindow.focused) ?? state.windows[0];
        if (!focusedWindow) throw new Error("No last-focused window");
        return { ...focusedWindow };
      },
      async update(windowID, updateProperties) {
        calls.push(["windows.update", windowID, updateProperties]);
        return { id: windowID, ...updateProperties };
      },
      async create(createProperties) {
        calls.push(["windows.create", createProperties]);
        const newWindow = { id: state.nextWindowID++, type: "normal", focused: true, incognito: false };
        state.windows.push(newWindow);
        if (typeof createProperties?.tabId === "number") findTab(createProperties.tabId).windowId = newWindow.id;
        return { ...newWindow };
      },
      onFocusChanged: createFakeEvent(),
    },

    permissions: {
      async contains(requestedPermissions) {
        checkPermissionNames(requestedPermissions);
        return permissionSetContains(state.grantedPermissionNames, state.grantedOrigins, requestedPermissions);
      },
      async request(requestedPermissions) {
        calls.push(["permissions.request", requestedPermissions]);
        checkPermissionNames(requestedPermissions);
        for (const name of requestedPermissions?.permissions ?? []) state.grantedPermissionNames.add(name);
        for (const origin of requestedPermissions?.origins ?? []) state.grantedOrigins.add(origin);
        syncOptionalAPIs();
        await fakeChrome.permissions.onAdded.dispatch(requestedPermissions);
        return true;
      },
      async remove(removedPermissions) {
        calls.push(["permissions.remove", removedPermissions]);
        for (const name of removedPermissions?.permissions ?? []) state.grantedPermissionNames.delete(name);
        for (const origin of removedPermissions?.origins ?? []) state.grantedOrigins.delete(origin);
        syncOptionalAPIs();
        await fakeChrome.permissions.onRemoved.dispatch(removedPermissions);
        return true;
      },
      onAdded: createFakeEvent(),
      onRemoved: createFakeEvent(),
    },

    alarms: {
      create(alarmName, alarmInfo) {
        calls.push(["alarms.create", alarmName, alarmInfo]);
        state.alarms.set(alarmName, alarmInfo);
      },
      onAlarm: createFakeEvent(),
    },

    storage: {
      session: {
        async get(keys) {
          return pickKeys(state.sessionStorage, keys);
        },
        async set(items) {
          Object.assign(state.sessionStorage, items);
        },
        onChanged: createFakeEvent(),
      },
      local: {
        async get(keys) {
          return pickKeys(state.localStorage, keys);
        },
        async set(items) {
          Object.assign(state.localStorage, items);
        },
        onChanged: createFakeEvent(),
      },
    },

    runtime: {
      // The real extension's id (pinned by the manifest key), so a handler
      // that checks a message's sender against it sees the same value.
      id: "kpblnefdnmlodeagdnfodnbbdbkacnce",
      getManifest() {
        return { version: manifestVersion };
      },
      async openOptionsPage() {
        calls.push(["runtime.openOptionsPage"]);
        state.optionsPageOpenCount += 1;
      },
      async sendMessage(message) {
        calls.push(["runtime.sendMessage", message]);
      },
      onStartup: createFakeEvent(),
      onInstalled: createFakeEvent(),
      onMessage: createFakeEvent(),
    },

    // Filled in by the phases that inject content scripts: pass
    // `executeScript` to play the page.
    scripting: {
      async executeScript(injection) {
        calls.push(["scripting.executeScript", injection]);
        return executeScript ? executeScript(injection) : [];
      },
    },

    webNavigation: {
      async getAllFrames({ tabId }) {
        return (framesByTabID[tabId] ?? [{ frameId: 0, parentFrameId: -1, url: findTab(tabId).url }]).map((frame) => ({ ...frame }));
      },
      async getFrame({ tabId, frameId }) {
        const frames = framesByTabID[tabId] ?? [{ frameId: 0, parentFrameId: -1, url: findTab(tabId).url }];
        const frame = frames.find((candidateFrame) => candidateFrame.frameId === frameId);
        return frame ? { ...frame } : null;
      },
      onCommitted: createFakeEvent(),
      onCompleted: createFakeEvent(),
    },
  };

  // Like Chrome, `chrome.downloads` only exists while the optional
  // `downloads` permission is granted. Its events persist across a grant,
  // remove and re-grant, so a test can check listeners aren't doubled.
  const fakeDownloadsAPI = createFakeDownloadsAPI(state, calls);
  function syncOptionalAPIs() {
    if (state.grantedPermissionNames.has("downloads")) {
      fakeChrome.downloads = fakeDownloadsAPI;
    } else {
      delete fakeChrome.downloads;
    }
  }
  syncOptionalAPIs();

  return fakeChrome;
}

// `chrome.downloads`: search by id or newest first with a limit, and show.
function createFakeDownloadsAPI(state, calls) {
  return {
    async search(query = {}) {
      let matchingDownloads = state.downloads.map((downloadItem) => ({ ...downloadItem }));
      if (typeof query.id === "number") {
        matchingDownloads = matchingDownloads.filter((downloadItem) => downloadItem.id === query.id);
      }
      if ((query.orderBy ?? []).includes("-startTime")) {
        matchingDownloads.sort((first, second) => String(second.startTime ?? "").localeCompare(String(first.startTime ?? "")));
      }
      if (typeof query.limit === "number" && query.limit > 0) {
        matchingDownloads = matchingDownloads.slice(0, query.limit);
      }
      return matchingDownloads;
    },
    show(downloadID) {
      calls.push(["downloads.show", downloadID]);
      state.shownDownloadIDs.push(downloadID);
    },
    onCreated: createFakeEvent(),
    onChanged: createFakeEvent(),
  };
}

function pickKeys(storageObject, keys) {
  if (keys === null || keys === undefined) return { ...storageObject };
  const requestedKeys = typeof keys === "string" ? [keys] : Array.isArray(keys) ? keys : Object.keys(keys);
  const pickedItems = {};
  for (const key of requestedKeys) {
    if (key in storageObject) pickedItems[key] = storageObject[key];
  }
  return pickedItems;
}

// A WebSocket stand-in for the bridge: records what was sent, and lets a test
// open, close or deliver messages.
export class FakeWebSocket {
  static instances = [];

  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.sentMessages = [];
    FakeWebSocket.instances.push(this);
  }

  send(text) {
    this.sentMessages.push(JSON.parse(text));
  }

  async simulateOpen() {
    this.readyState = 1;
    await this.onopen?.();
  }

  simulateClose() {
    this.readyState = 3;
    this.onclose?.();
  }

  async simulateMessage(data) {
    await this.onmessage?.({ data: typeof data === "string" ? data : JSON.stringify(data) });
  }
}

// Manual timers, so debounce and keep-alive tests don't sleep.
export function createManualTimers() {
  let nextTimerID = 1;
  let currentTime = 0;
  const pendingTimers = new Map();
  return {
    setTimeout(callback, delayMilliseconds) {
      const timerID = nextTimerID++;
      pendingTimers.set(timerID, { callback, fireAt: currentTime + delayMilliseconds, intervalMilliseconds: null });
      return timerID;
    },
    clearTimeout(timerID) {
      pendingTimers.delete(timerID);
    },
    setInterval(callback, intervalMilliseconds) {
      const timerID = nextTimerID++;
      pendingTimers.set(timerID, { callback, fireAt: currentTime + intervalMilliseconds, intervalMilliseconds });
      return timerID;
    },
    clearInterval(timerID) {
      pendingTimers.delete(timerID);
    },
    get pendingTimerCount() {
      return pendingTimers.size;
    },
    advance(milliseconds) {
      const targetTime = currentTime + milliseconds;
      for (;;) {
        const dueTimers = [...pendingTimers.entries()]
          .filter(([, timer]) => timer.fireAt <= targetTime)
          .sort((first, second) => first[1].fireAt - second[1].fireAt);
        if (dueTimers.length === 0) break;
        const [timerID, timer] = dueTimers[0];
        currentTime = timer.fireAt;
        if (timer.intervalMilliseconds === null) {
          pendingTimers.delete(timerID);
        } else {
          timer.fireAt += timer.intervalMilliseconds;
        }
        timer.callback();
      }
      currentTime = targetTime;
    },
  };
}
