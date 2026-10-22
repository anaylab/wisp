// Wisp Tabs — the DOM controller (phase 03).
//
// The request handlers behind Wisp's `ExtensionBrowserController`: open and
// steer a tab, read it as a snapshot of element ids, and act on those ids. The
// page work itself happens in content/dom-agent.js, injected on demand; this
// file picks the tab and frame, enforces which pages may be touched
// (lib/page-access.js), and keeps Wisp's work in a "Wisp" tab group.
//
// Why this exists beside the AppleScript path: an extension can work in a
// background tab (the user keeps reading their own), address a tab by a real
// id instead of Safari-style window+position guesses, and see cross-origin
// frames. Wisp still decides everything; nothing here chooses what to click.
//
// Every method takes an optional `tabId`. Without one it means the tab in
// front of the user: the active tab of the last focused normal window.
//
// Element ids are the snapshot's `e7`. Elements from a cross-origin frame are
// prefixed with Chrome's frame id (`f12e3`), so an action finds its frame
// again; same-origin frames and shadow roots are walked by the top frame's
// agent and keep plain ids, as in the AppleScript snapshot.

import { capList, truncateText } from "../lib/limits.js";
import {
  PAGE_ACCESS_ACT,
  PAGE_ACCESS_BLANK,
  PAGE_ACCESS_READ_ONLY,
  PAGE_ACCESS_REFUSED,
  isNavigableURL,
  pageAccessForURL,
} from "../lib/page-access.js";

export const DOM_AGENT_FILE = "content/dom-agent.js";
export const WISP_GROUP_TITLE = "Wisp";
export const WISP_GROUP_COLOR = "purple";

// The snapshot's default budgets, the same numbers as
// `AppleScriptBrowserController.defaultElementLimit` / `defaultTextCharacterLimit`.
export const DEFAULT_ELEMENT_LIMIT = 25;
export const DEFAULT_TEXT_CHARACTER_LIMIT = 1500;

// Cross-origin frames read per snapshot. Pages with dozens of ad frames would
// otherwise cost a round trip each for nothing the user asked about.
export const MAXIMUM_CROSS_ORIGIN_FRAMES = 8;

// Settling, mirroring the AppleScript controller: loaded, then the DOM quiet
// for 400ms, spending at most 3s waiting for quiet (a ticker never goes quiet).
export const DEFAULT_QUIET_MILLISECONDS = 400;
export const DEFAULT_MAXIMUM_QUIET_WAIT_MILLISECONDS = 3000;
const LOAD_POLL_MILLISECONDS = 120;
const QUIET_POLL_MILLISECONDS = 150;
// The bridge caps every request at 30s; the reply has to leave before Wisp
// stops waiting for it.
const MAXIMUM_WAIT_MILLISECONDS = 29000;

const ELEMENT_ID_PATTERN = /^(?:f(\d{1,9}))?(e\d{1,9})$/;

// Splits `f12e3` into frame 12, local id `e3`; a plain `e3` is the top frame.
export function parseElementID(elementId) {
  if (typeof elementId !== "string") return null;
  const match = ELEMENT_ID_PATTERN.exec(elementId.trim());
  if (!match) return null;
  return { frameId: match[1] === undefined ? 0 : Number(match[1]), localElementId: match[2] };
}

// Best match first, by the same tiers as
// `AppleScriptBrowserController.findElements`: exact label, prefix, contains,
// then every query word somewhere in the label.
export function rankElementsByQuery(elements, query) {
  const normalizedQuery = String(query ?? "").toLowerCase().trim();
  if (!normalizedQuery) return [];
  const queryWords = normalizedQuery.split(" ").filter((word) => word.length > 0);
  const scoreOf = (element) => {
    const label = String(element.label ?? "").toLowerCase();
    if (label === normalizedQuery) return 4;
    if (label.startsWith(normalizedQuery)) return 3;
    if (label.includes(normalizedQuery)) return 2;
    if (queryWords.length > 1 && queryWords.every((word) => label.includes(word))) return 1;
    return 0;
  };
  return elements
    .map((element) => ({ element, score: scoreOf(element) }))
    .filter(({ score }) => score > 0)
    .sort((first, second) => second.score - first.score)
    .map(({ element }) => element);
}

// Merges the top frame's snapshot with each cross-origin frame's elements:
// dialog first, then what is in view, then below, the top frame before frames
// at the same priority, and the element budget spent once across all of them.
export function mergeFrameSnapshots(topFrameSnapshot, frameSnapshots, elementLimit) {
  const ranked = [];
  (topFrameSnapshot.elements ?? []).forEach((element, elementIndex) => {
    ranked.push({ element, priority: element.priority ?? 1, sourceOrder: 0, elementIndex });
  });
  frameSnapshots.forEach(({ frameId, snapshot }, frameOrder) => {
    (snapshot.elements ?? []).forEach((element, elementIndex) => {
      ranked.push({
        element: { ...element, id: `f${frameId}${element.id}` },
        priority: element.priority ?? 1,
        sourceOrder: frameOrder + 1,
        elementIndex,
      });
    });
  });
  ranked.sort((first, second) =>
    first.priority - second.priority ||
    first.sourceOrder - second.sourceOrder ||
    first.elementIndex - second.elementIndex);
  return ranked.slice(0, Math.max(0, elementLimit)).map(({ element }) => {
    const { priority, ...wireElement } = element;
    return wireElement;
  });
}

// The element's centre on screen, top-left origin, in the browser's screen
// coordinates (CSS pixels = points on macOS). The viewport sits at the bottom
// of the window's outer frame, centred horizontally — the same arithmetic the
// AppleScript controller does with window.screenX/outerHeight in the page.
export function screenPointForElement(windowBounds, elementGeometry) {
  const horizontalChrome = (windowBounds.width - elementGeometry.viewportWidth) / 2;
  const verticalChrome = windowBounds.height - elementGeometry.viewportHeight;
  return {
    x: Math.round(windowBounds.left + horizontalChrome + elementGeometry.centerX),
    y: Math.round(windowBounds.top + verticalChrome + elementGeometry.centerY),
  };
}

// Runs inside the page (serialised by executeScript), so it must be
// self-contained. Reports NOT_INSTALLED when the agent isn't in this document
// yet, which is the cue to inject content/dom-agent.js and ask again.
function invokeWispAgentMethod(methodName, methodArguments) {
  const agent = window.__wispAgent;
  if (!agent || typeof agent[methodName] !== "function") return { status: "NOT_INSTALLED" };
  try {
    return agent[methodName](methodArguments);
  } catch (error) {
    return { status: "FAILED", detail: String((error && error.message) || error) };
  }
}

export function createDomControllerHandlers({
  chromeAPI = () => globalThis.chrome,
  currentTimeMilliseconds = () => Date.now(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
} = {}) {
  // MARK: - Tabs, frames and access

  async function resolveTargetTab(tabId) {
    const chrome = chromeAPI();
    let tab;
    if (Number.isInteger(tabId)) {
      tab = await chrome.tabs.get(tabId);
    } else {
      const activeTabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true, windowType: "normal" });
      tab = activeTabs[0];
      if (!tab) throw new Error("no chrome tab is open");
    }
    if (tab.incognito) throw new Error("wisp never reads or acts in incognito tabs");
    return tab;
  }

  async function pageAccessForTabURL(pageURL) {
    let isFileSchemeAccessAllowed = false;
    if (typeof pageURL === "string" && pageURL.startsWith("file:")) {
      try {
        isFileSchemeAccessAllowed = Boolean(await chromeAPI().extension?.isAllowedFileSchemeAccess?.());
      } catch (error) {
        isFileSchemeAccessAllowed = false;
      }
    }
    return pageAccessForURL(pageURL, { isFileSchemeAccessAllowed });
  }

  function requireScripting() {
    if (!chromeAPI().scripting?.executeScript) {
      throw new Error("wisp can't read pages yet — open the wisp tabs options and allow reading pages");
    }
  }

  // Reading is allowed on ordinary pages and (with file access) local files.
  async function requireReadablePage(tab) {
    const pageAccess = await pageAccessForTabURL(tab.url ?? tab.pendingUrl ?? "");
    if (pageAccess === PAGE_ACCESS_REFUSED) {
      throw new Error("wisp doesn't read chrome's own pages, the web store or other protected pages");
    }
    return pageAccess;
  }

  // Acting is allowed on ordinary web pages only.
  async function requireActionablePage(tab) {
    const pageAccess = await requireReadablePage(tab);
    if (pageAccess === PAGE_ACCESS_BLANK) throw new Error("the tab is empty — open a page first");
    if (pageAccess === PAGE_ACCESS_READ_ONLY) throw new Error("wisp only reads local files, it never acts in them");
    return pageAccess;
  }

  async function callAgent(tabId, frameId, methodName, methodArguments) {
    requireScripting();
    const chrome = chromeAPI();
    const target = { tabId, frameIds: [frameId] };
    const invoke = async () => {
      const injectionResults = await chrome.scripting.executeScript({
        target,
        func: invokeWispAgentMethod,
        args: [methodName, methodArguments ?? {}],
      });
      return injectionResults?.[0]?.result;
    };
    let agentResult = await invoke();
    if (agentResult?.status === "NOT_INSTALLED") {
      await chrome.scripting.executeScript({ target, files: [DOM_AGENT_FILE] });
      agentResult = await invoke();
    }
    return agentResult ?? { status: "NO_RESULT" };
  }

  // Cross-origin http(s) frames, which the top frame's agent cannot walk.
  // Found with webNavigation rather than injecting into every frame blind, so
  // only frames worth reading get a script.
  async function crossOriginFrameIDs(tabId) {
    const chrome = chromeAPI();
    let frames;
    try {
      frames = await chrome.webNavigation.getAllFrames({ tabId });
    } catch (error) {
      return [];
    }
    const framesByID = new Map((frames ?? []).map((frame) => [frame.frameId, frame]));
    const originOf = (frameURL) => {
      try {
        return new URL(frameURL).origin;
      } catch (error) {
        return null;
      }
    };
    const crossOriginIDs = [];
    for (const frame of frames ?? []) {
      if (frame.frameId === 0) continue;
      if (pageAccessForURL(frame.url) !== PAGE_ACCESS_ACT) continue;
      const parentFrame = framesByID.get(frame.parentFrameId);
      const frameOrigin = originOf(frame.url);
      if (!frameOrigin || !parentFrame || originOf(parentFrame.url) === frameOrigin) continue;
      crossOriginIDs.push(frame.frameId);
      if (crossOriginIDs.length >= MAXIMUM_CROSS_ORIGIN_FRAMES) break;
    }
    return crossOriginIDs;
  }

  async function requireActionableFrame(tabId, frameId) {
    if (frameId === 0) return;
    let frame = null;
    try {
      frame = await chromeAPI().webNavigation.getFrame({ tabId, frameId });
    } catch (error) {
      frame = null;
    }
    if (!frame || pageAccessForURL(frame.url) !== PAGE_ACCESS_ACT) {
      throw new Error("that element's frame is gone or protected");
    }
  }

  async function runElementAction(params, methodName, extraArguments = {}) {
    const parsedElementID = parseElementID(params.elementId);
    if (!parsedElementID) return { status: "MISSING" };
    const tab = await resolveTargetTab(params.tabId);
    await requireActionablePage(tab);
    await requireActionableFrame(tab.id, parsedElementID.frameId);
    const agentResult = await callAgent(tab.id, parsedElementID.frameId, methodName, {
      id: parsedElementID.localElementId,
      ...extraArguments,
    });
    return { status: agentResult.status ?? "NO_RESULT", tabId: tab.id };
  }

  function blankSnapshot(tab) {
    return {
      tabId: tab.id,
      url: tab.url || "about:blank",
      title: tab.title ?? "",
      headings: [],
      elements: [],
      text: "",
      scroll: "the whole page fits on screen",
      dialog: "",
    };
  }

  async function takeSnapshot(params) {
    const tab = await resolveTargetTab(params.tabId);
    const pageAccess = await requireReadablePage(tab);
    if (pageAccess === PAGE_ACCESS_BLANK) return blankSnapshot(tab);

    const maximumTextCharacters = Number.isInteger(params.maximumTextCharacters)
      ? params.maximumTextCharacters : DEFAULT_TEXT_CHARACTER_LIMIT;
    const elementLimit = Number.isInteger(params.elementLimit) ? params.elementLimit : DEFAULT_ELEMENT_LIMIT;
    const snapshotArguments = { maximumTextCharacters, elementLimit };

    const topFrameSnapshot = await callAgent(tab.id, 0, "snapshot", snapshotArguments);
    if (topFrameSnapshot.status !== "OK") {
      throw new Error("couldn't read the page");
    }

    const frameSnapshots = [];
    if (elementLimit > 0 && pageAccess === PAGE_ACCESS_ACT) {
      for (const frameId of await crossOriginFrameIDs(tab.id)) {
        try {
          const frameSnapshot = await callAgent(tab.id, frameId, "snapshot", snapshotArguments);
          if (frameSnapshot.status === "OK") frameSnapshots.push({ frameId, snapshot: frameSnapshot });
        } catch (error) {
          // A frame that navigated away or refused injection is just left out.
        }
      }
    }

    const cappedElements = capList(mergeFrameSnapshots(topFrameSnapshot, frameSnapshots, elementLimit));
    const cappedText = truncateText(topFrameSnapshot.text ?? "");
    const cappedURL = truncateText(topFrameSnapshot.url ?? "");
    const snapshot = {
      tabId: tab.id,
      url: cappedURL.text,
      title: truncateText(topFrameSnapshot.title ?? "").text,
      headings: topFrameSnapshot.headings ?? [],
      elements: cappedElements.items,
      text: cappedText.text,
      scroll: topFrameSnapshot.scroll ?? "",
      dialog: topFrameSnapshot.dialog ?? "",
    };
    if (cappedElements.truncated || cappedText.truncated || cappedURL.truncated) snapshot.truncated = true;
    return snapshot;
  }

  // MARK: - The Wisp group

  async function lastFocusedNormalWindowID() {
    const chrome = chromeAPI();
    try {
      const focusedWindow = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
      if (focusedWindow && !focusedWindow.incognito) return focusedWindow.id;
    } catch (error) {
      // No window has had focus yet; fall through to any normal window.
    }
    const normalWindows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    return normalWindows.find((browserWindow) => !browserWindow.incognito)?.id ?? null;
  }

  // The group Wisp keeps its task tab in, one per window, found by title.
  // Collapsing never hides the tab the user is looking at: a group holding the
  // window's active tab stays open.
  async function getOrCreateWispGroup({ windowId, tabIds, collapsed } = {}) {
    const chrome = chromeAPI();
    const tabIDsToGroup = Array.isArray(tabIds) ? tabIds.filter(Number.isInteger) : [];
    let targetWindowID = windowId;
    if (tabIDsToGroup.length > 0) {
      targetWindowID = (await chrome.tabs.get(tabIDsToGroup[0])).windowId;
    } else if (!Number.isInteger(targetWindowID)) {
      targetWindowID = await lastFocusedNormalWindowID();
    }
    if (!Number.isInteger(targetWindowID)) return { groupId: -1, windowId: null, created: false };

    const groupsInWindow = (await chrome.tabGroups.query({ windowId: targetWindowID }))
      .filter((group) => group.windowId === targetWindowID);
    const existingGroup = groupsInWindow.find((group) => group.title === WISP_GROUP_TITLE);

    let groupId = existingGroup?.id ?? -1;
    let created = false;
    if (tabIDsToGroup.length > 0) {
      groupId = existingGroup
        ? await chrome.tabs.group({ tabIds: tabIDsToGroup, groupId: existingGroup.id })
        : await chrome.tabs.group({ tabIds: tabIDsToGroup, createProperties: { windowId: targetWindowID } });
      created = !existingGroup;
    }
    if (groupId === -1) return { groupId: -1, windowId: targetWindowID, created: false };

    const groupUpdate = {};
    if (created) {
      groupUpdate.title = WISP_GROUP_TITLE;
      groupUpdate.color = WISP_GROUP_COLOR;
    }
    if (collapsed === false) groupUpdate.collapsed = false;
    if (collapsed === true) {
      const windowTabs = await chrome.tabs.query({ windowId: targetWindowID });
      const groupHoldsActiveTab = windowTabs.some((tab) =>
        tab.windowId === targetWindowID && tab.groupId === groupId && tab.active);
      if (!groupHoldsActiveTab) groupUpdate.collapsed = true;
    }
    let collapsedNow = Boolean(existingGroup?.collapsed);
    if (Object.keys(groupUpdate).length > 0) {
      const updatedGroup = await chrome.tabGroups.update(groupId, groupUpdate);
      collapsedNow = Boolean(updatedGroup?.collapsed ?? groupUpdate.collapsed ?? collapsedNow);
    }
    return { groupId, windowId: targetWindowID, created, collapsed: collapsedNow };
  }

  // MARK: - Handlers

  return {
    // Opens a tab in the focused window — in the background unless `active` —
    // and puts it in the Wisp group, expanded, so the work is visible but the
    // user stays where they are.
    async openTab({ url = "about:blank", active = false, inWispGroup = true } = {}) {
      if (!isNavigableURL(url)) throw new Error("wisp only opens web pages");
      const chrome = chromeAPI();
      let windowId = await lastFocusedNormalWindowID();
      let tab;
      if (windowId === null) {
        const newWindow = await chrome.windows.create({ url, focused: Boolean(active) });
        windowId = newWindow.id;
        tab = newWindow.tabs?.[0] ?? (await chrome.tabs.query({ windowId }))[0];
      } else {
        tab = await chrome.tabs.create({ windowId, url, active: Boolean(active) });
      }
      let groupId = -1;
      if (inWispGroup !== false && tab) {
        groupId = (await getOrCreateWispGroup({ tabIds: [tab.id], collapsed: false })).groupId;
      }
      return { tabId: tab?.id ?? -1, windowId, groupId };
    },

    async getOrCreateWispGroup(params = {}) {
      return getOrCreateWispGroup(params);
    },

    async navigateTab({ tabId, url } = {}) {
      if (!isNavigableURL(url)) throw new Error("wisp only opens web pages");
      const tab = await resolveTargetTab(tabId);
      await chromeAPI().tabs.update(tab.id, { url });
      return { tabId: tab.id };
    },

    async goBackInTab({ tabId } = {}) {
      const tab = await resolveTargetTab(tabId);
      try {
        await chromeAPI().tabs.goBack(tab.id);
      } catch (error) {
        throw new Error("there's no page to go back to");
      }
      return { tabId: tab.id };
    },

    async goForwardInTab({ tabId } = {}) {
      const tab = await resolveTargetTab(tabId);
      try {
        await chromeAPI().tabs.goForward(tab.id);
      } catch (error) {
        throw new Error("there's no page to go forward to");
      }
      return { tabId: tab.id };
    },

    async snapshotPage(params = {}) {
      return takeSnapshot(params);
    },

    // Two uses: `query` ranks the page's elements against what a person called
    // it; `elementId` (with `includeScreenPoint`) places one element on screen
    // for Wisp's cursor marker. A background tab, or an element in a
    // cross-origin frame, has no screen point.
    async findElements(params = {}) {
      if (typeof params.elementId === "string") {
        const parsedElementID = parseElementID(params.elementId);
        if (!parsedElementID) return { elements: [] };
        const tab = await resolveTargetTab(params.tabId);
        let screenPoint = null;
        if (params.includeScreenPoint && parsedElementID.frameId === 0 && tab.active &&
            (await pageAccessForTabURL(tab.url ?? "")) === PAGE_ACCESS_ACT) {
          const geometry = await callAgent(tab.id, 0, "elementScreenGeometry", { id: parsedElementID.localElementId });
          if (geometry.status === "OK") {
            const windowBounds = await chromeAPI().windows.get(tab.windowId);
            screenPoint = screenPointForElement(windowBounds, geometry);
          }
        }
        return { tabId: tab.id, elements: [{ id: params.elementId, screenPoint }] };
      }
      const snapshot = await takeSnapshot({ tabId: params.tabId });
      return { tabId: snapshot.tabId, elements: rankElementsByQuery(snapshot.elements, params.query) };
    },

    async clickElement(params = {}) {
      return runElementAction(params, "click");
    },

    async typeIntoElement(params = {}) {
      return runElementAction(params, "typeText", { text: String(params.text ?? ""), pressEnter: Boolean(params.pressEnter) });
    },

    async hoverElement(params = {}) {
      return runElementAction(params, "hover");
    },

    async selectOption(params = {}) {
      return runElementAction(params, "selectOption", { optionLabel: String(params.optionLabel ?? "") });
    },

    async pressKey({ tabId, key } = {}) {
      const tab = await resolveTargetTab(tabId);
      await requireActionablePage(tab);
      const agentResult = await callAgent(tab.id, 0, "pressKey", { key });
      return { status: agentResult.status ?? "NO_RESULT", tabId: tab.id };
    },

    async scrollPage({ tabId, direction } = {}) {
      const tab = await resolveTargetTab(tabId);
      const pageAccess = await requireReadablePage(tab);
      if (pageAccess === PAGE_ACCESS_BLANK) return { status: "OK", tabId: tab.id };
      const agentResult = await callAgent(tab.id, 0, "scrollPage", { direction });
      return { status: agentResult.status ?? "NO_RESULT", tabId: tab.id };
    },

    // Waits for the tab to finish loading, then (unless `requireQuiet` is
    // false) for the DOM to stop changing — one request, so Wisp doesn't poll
    // across the socket. Giving up on quiet after the budget still counts as
    // settled, as in the AppleScript controller: a page with a carousel must
    // not cost every step the whole timeout.
    async waitForSettled({
      tabId,
      waitSeconds = 8,
      requireQuiet = true,
      quietMilliseconds = DEFAULT_QUIET_MILLISECONDS,
      maximumQuietWaitMilliseconds = DEFAULT_MAXIMUM_QUIET_WAIT_MILLISECONDS,
    } = {}) {
      const chrome = chromeAPI();
      const startedAt = currentTimeMilliseconds();
      const waitMilliseconds = Math.min(Math.max(0, Number(waitSeconds) * 1000 || 0), MAXIMUM_WAIT_MILLISECONDS);
      const deadline = startedAt + waitMilliseconds;

      let tab = await resolveTargetTab(tabId);
      while (tab.status !== "complete") {
        if (currentTimeMilliseconds() >= deadline) return { tabId: tab.id, loaded: false, settled: false };
        await sleep(LOAD_POLL_MILLISECONDS);
        tab = await chrome.tabs.get(tab.id);
      }
      if (!requireQuiet) return { tabId: tab.id, loaded: true, settled: true };

      const pageAccess = await pageAccessForTabURL(tab.url ?? "");
      if (pageAccess !== PAGE_ACCESS_ACT && pageAccess !== PAGE_ACCESS_READ_ONLY) {
        // Nothing to observe on a blank or protected page; loaded is settled.
        return { tabId: tab.id, loaded: true, settled: true };
      }

      const remainingMilliseconds = deadline - currentTimeMilliseconds();
      const quietDeadline = currentTimeMilliseconds() +
        Math.max(0, Math.min(remainingMilliseconds, maximumQuietWaitMilliseconds));
      while (currentTimeMilliseconds() < quietDeadline) {
        const quietness = await callAgent(tab.id, 0, "quietness", { quietMilliseconds });
        if (quietness.isQuiet) return { tabId: tab.id, loaded: true, settled: true, quietReached: true };
        await sleep(QUIET_POLL_MILLISECONDS);
      }
      return { tabId: tab.id, loaded: true, settled: true, quietReached: false };
    },

    // Only for the browser protocol's screenshot fallback. Chrome can only
    // capture what a window is showing, so a background tab is refused rather
    // than capturing whatever tab happens to be in front.
    async captureVisibleTab({ tabId, quality = 70 } = {}) {
      const tab = await resolveTargetTab(tabId);
      await requireActionablePage(tab);
      if (!tab.active) {
        throw new Error("chrome can only capture the tab that's showing, and this one is in the background — bring it to the front first");
      }
      const dataURL = await chromeAPI().tabs.captureVisibleTab(tab.windowId, {
        format: "jpeg",
        quality: Math.min(100, Math.max(10, Number(quality) || 70)),
      });
      const base64Marker = "base64,";
      const markerIndex = String(dataURL).indexOf(base64Marker);
      if (markerIndex < 0) throw new Error("chrome returned no picture");
      return { tabId: tab.id, format: "jpeg", imageBase64: String(dataURL).slice(markerIndex + base64Marker.length) };
    },
  };
}

export const domControllerHandlers = createDomControllerHandlers();
