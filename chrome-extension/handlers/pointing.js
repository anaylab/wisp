// Wisp Tabs — pointing inside the page (phase 05).
//
// The request handlers that draw Wisp's marks in a tab (content/highlight.js)
// and watch for the real click on a walkthrough step:
//
//   highlightElements({tabId, items:[{elementId, kind, label, stepNumber}], color, dismissOnEscape})
//       → {tabId, shown:[ids], missing:[ids]}
//   clearHighlights({tabId?})                    → {cleared: true}
//   watchClicks({tabId, elementIds})             → {tabId, watching:[ids], missing:[ids]}
//   stopWatchingClicks({tabId?})                 → {stopped: true}
//
// Element ids are the DOM controller's (`e7`, or `f12e3` in a cross-origin
// frame), so Wisp finds an element with `findElements` and then marks it.
// Clicks and dismissals come back as events through events/pointing.js.
//
// Wisp decides what to mark and when to stop; nothing here chooses an element.

import { capList } from "../lib/limits.js";
import { PAGE_ACCESS_ACT, PAGE_ACCESS_BLANK, PAGE_ACCESS_REFUSED, pageAccessForURL } from "../lib/page-access.js";
import { parseElementID } from "./dom-controller.js";

export const HIGHLIGHTER_FILE = "content/highlight.js";

// Runs inside the page (serialised by executeScript), so it must be
// self-contained. NOT_INSTALLED is the cue to inject content/highlight.js and
// ask again, as the DOM controller does with its agent.
function invokeWispHighlighterMethod(methodName, methodArguments) {
  const highlighter = window.__wispHighlighter;
  if (!highlighter || typeof highlighter[methodName] !== "function") return { status: "NOT_INSTALLED" };
  try {
    return highlighter[methodName](methodArguments);
  } catch (error) {
    return { status: "FAILED", detail: String((error && error.message) || error) };
  }
}

// Splits wire items by the frame their element lives in, turning `f12e3` into
// frame 12's local `e3`. Items whose id isn't an element id are reported
// missing rather than guessed at.
export function groupItemsByFrame(items) {
  const itemsByFrameID = new Map();
  const unparseableElementIDs = [];
  for (const item of items ?? []) {
    const parsedElementID = parseElementID(item?.elementId);
    if (!parsedElementID) {
      unparseableElementIDs.push(String(item?.elementId ?? ""));
      continue;
    }
    const frameItems = itemsByFrameID.get(parsedElementID.frameId) ?? [];
    frameItems.push({ ...item, elementId: parsedElementID.localElementId, wireElementId: item.elementId });
    itemsByFrameID.set(parsedElementID.frameId, frameItems);
  }
  return { itemsByFrameID, unparseableElementIDs };
}

// A frame-local id back to the id Wisp knows.
export function wireElementID(frameId, localElementId) {
  return frameId === 0 ? localElementId : `f${frameId}${localElementId}`;
}

export function createPointingHandlers({ chromeAPI = () => globalThis.chrome } = {}) {
  // Frames each tab has marks or click watches in, so clearing reaches every
  // one of them (frame 0 is always tried). Lost if the worker sleeps; the top
  // frame is still cleared then, and a frame's marks go when its page does.
  const framesWithMarksByTabID = new Map();
  const framesWatchingClicksByTabID = new Map();

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

  // Marks only go on pages Wisp may read: ordinary web pages and, with
  // Chrome's file-access switch, local files. Drawing over a page changes
  // nothing in it, so read access is enough.
  async function requireMarkablePage(tab) {
    const chrome = chromeAPI();
    if (!chrome.scripting?.executeScript) {
      throw new Error("wisp can't read pages yet — open the wisp tabs options and allow reading pages");
    }
    const pageURL = tab.url ?? tab.pendingUrl ?? "";
    let isFileSchemeAccessAllowed = false;
    if (typeof pageURL === "string" && pageURL.startsWith("file:")) {
      try {
        isFileSchemeAccessAllowed = Boolean(await chrome.extension?.isAllowedFileSchemeAccess?.());
      } catch (error) {
        isFileSchemeAccessAllowed = false;
      }
    }
    const pageAccess = pageAccessForURL(pageURL, { isFileSchemeAccessAllowed });
    if (pageAccess === PAGE_ACCESS_REFUSED) {
      throw new Error("wisp doesn't draw on chrome's own pages, the web store or other protected pages");
    }
    if (pageAccess === PAGE_ACCESS_BLANK) throw new Error("the tab is empty — there's nothing to point at");
  }

  async function callHighlighter(tabId, frameId, methodName, methodArguments, { installIfMissing = true } = {}) {
    const chrome = chromeAPI();
    const target = { tabId, frameIds: [frameId] };
    const invoke = async () => {
      const injectionResults = await chrome.scripting.executeScript({
        target,
        func: invokeWispHighlighterMethod,
        args: [methodName, methodArguments ?? {}],
      });
      return injectionResults?.[0]?.result;
    };
    let highlighterResult = await invoke();
    if (highlighterResult?.status === "NOT_INSTALLED" && installIfMissing) {
      await chrome.scripting.executeScript({ target, files: [HIGHLIGHTER_FILE] });
      highlighterResult = await invoke();
    }
    return highlighterResult ?? { status: "NO_RESULT" };
  }

  function rememberFrame(framesByTabID, tabId, frameId) {
    const frameIDs = framesByTabID.get(tabId) ?? new Set();
    frameIDs.add(frameId);
    framesByTabID.set(tabId, frameIDs);
  }

  // Calls `methodName` in every frame of the tab that might hold something,
  // never installing the highlighter just to clear it. A frame that went away
  // is simply skipped.
  async function callInRememberedFrames(tabId, framesByTabID, methodName) {
    const frameIDs = new Set([0, ...(framesByTabID.get(tabId) ?? [])]);
    framesByTabID.delete(tabId);
    for (const frameId of frameIDs) {
      try {
        await callHighlighter(tabId, frameId, methodName, {}, { installIfMissing: false });
      } catch (error) {
        // The frame (or the whole tab) is gone; its marks went with it.
      }
    }
  }

  // A cross-origin frame is marked only if its own address is one Wisp may
  // read; the top frame was checked with the tab.
  async function isMarkableFrame(tabId, frameId) {
    if (frameId === 0) return true;
    try {
      const frame = await chromeAPI().webNavigation.getFrame({ tabId, frameId });
      return Boolean(frame) && pageAccessForURL(frame.url) === PAGE_ACCESS_ACT;
    } catch (error) {
      return false;
    }
  }

  // Runs `methodName` once per frame with that frame's items, collecting
  // which wire ids it reports in `resultKey` and which it couldn't find.
  async function runPerFrame(tab, items, framesByTabID, methodName, buildArguments, resultKey) {
    const { itemsByFrameID, unparseableElementIDs } = groupItemsByFrame(items);
    const succeededElementIDs = [];
    const missingElementIDs = [...unparseableElementIDs];
    for (const [frameId, frameItems] of itemsByFrameID) {
      const localToWireID = new Map(frameItems.map((frameItem) => [frameItem.elementId, frameItem.wireElementId]));
      let frameResult;
      try {
        if (!(await isMarkableFrame(tab.id, frameId))) throw new Error("frame gone or protected");
        frameResult = await callHighlighter(tab.id, frameId, methodName, buildArguments(frameItems));
      } catch (error) {
        frameResult = { status: "FAILED" };
      }
      if (frameResult.status !== "OK") {
        missingElementIDs.push(...frameItems.map((frameItem) => frameItem.wireElementId));
        continue;
      }
      rememberFrame(framesByTabID, tab.id, frameId);
      for (const localID of frameResult[resultKey] ?? []) {
        succeededElementIDs.push(localToWireID.get(localID) ?? wireElementID(frameId, localID));
      }
      for (const localID of frameResult.missing ?? []) {
        missingElementIDs.push(localToWireID.get(localID) ?? wireElementID(frameId, localID));
      }
    }
    return { succeededElementIDs, missingElementIDs };
  }

  return {
    // Replaces whatever Wisp had drawn in this tab with these marks.
    async highlightElements({ tabId, items, color, dismissOnEscape = true } = {}) {
      const tab = await resolveTargetTab(tabId);
      await requireMarkablePage(tab);
      const requestedItems = capList(Array.isArray(items) ? items : []).items;
      await callInRememberedFrames(tab.id, framesWithMarksByTabID, "clear");
      const { succeededElementIDs, missingElementIDs } = await runPerFrame(
        tab,
        requestedItems,
        framesWithMarksByTabID,
        "show",
        (frameItems) => ({
          color,
          dismissOnEscape: dismissOnEscape !== false,
          items: frameItems.map(({ elementId, kind, label, stepNumber }) => ({ elementId, kind, label, stepNumber })),
        }),
        "shown"
      );
      return { tabId: tab.id, shown: succeededElementIDs, missing: missingElementIDs };
    },

    // Without a tab id: every tab Wisp drew in this session, plus the one in
    // front — Esc in Wisp means "take all of it away".
    async clearHighlights({ tabId } = {}) {
      const tabIDs = new Set(framesWithMarksByTabID.keys());
      if (Number.isInteger(tabId)) {
        tabIDs.clear();
        tabIDs.add(tabId);
      } else {
        try {
          tabIDs.add((await resolveTargetTab(undefined)).id);
        } catch (error) {
          // No tab in front (or an incognito one): nothing more to clear.
        }
      }
      for (const tabIDToClear of tabIDs) {
        await callInRememberedFrames(tabIDToClear, framesWithMarksByTabID, "clear");
      }
      return { cleared: true };
    },

    async watchClicks({ tabId, elementIds } = {}) {
      const tab = await resolveTargetTab(tabId);
      await requireMarkablePage(tab);
      await callInRememberedFrames(tab.id, framesWatchingClicksByTabID, "stopWatchingClicks");
      const requestedIDs = capList(Array.isArray(elementIds) ? elementIds : []).items;
      const { succeededElementIDs, missingElementIDs } = await runPerFrame(
        tab,
        requestedIDs.map((elementId) => ({ elementId })),
        framesWatchingClicksByTabID,
        "watchClicks",
        (frameItems) => ({ ids: frameItems.map((frameItem) => frameItem.elementId) }),
        "watching"
      );
      return { tabId: tab.id, watching: succeededElementIDs, missing: missingElementIDs };
    },

    async stopWatchingClicks({ tabId } = {}) {
      const tabIDs = Number.isInteger(tabId) ? [tabId] : [...framesWatchingClicksByTabID.keys()];
      for (const tabIDToStop of tabIDs) {
        await callInRememberedFrames(tabIDToStop, framesWatchingClicksByTabID, "stopWatchingClicks");
      }
      return { stopped: true };
    },
  };
}

export const pointingHandlers = createPointingHandlers();
