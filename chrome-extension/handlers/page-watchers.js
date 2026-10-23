// Wisp Tabs — page watchers (phase 08).
//
//   startPageWatch({tabId?, condition, reloadEveryMinutes?, label?}) → the watch
//   stopPageWatch({watchId} | {all: true})                           → {stoppedCount}
//   listPageWatches()                    → {watches: […], recentlyEnded: […]}
//
//   watch.matched {watchId, matchedText, tabId, url, title}   the condition was met
//   watch.ended   {watchId, reason}   timedOut | tabClosed | navigatedAway | pageUnavailable
//
// A watch is content/page-watch.js running in the tab: a MutationObserver
// that re-reads the page's text at most once a second and decides with the
// same rules as Wisp's screen watcher. This file keeps the list of watches,
// puts the watcher back into the page whenever it loads again, reloads the
// tabs that need it, and tells Wisp how each watch ended. Wisp decides what to
// watch and what to say; nothing here calls a model.
//
// Where watches live: `chrome.storage.session`. Chrome stops an idle service
// worker after ~30s and wakes it for the next event, so nothing that matters
// can live in a variable here. Session storage lasts exactly as long as the
// browser does, which is as long as a tab id means anything (contracts.md §1).
// A watch's evaluator state is stored with it, so a reload continues the
// watch rather than starting over.
//
// Reloading watches ("tell me when tickets are back in stock") don't reload
// the user's own tab — that would throw away whatever they were doing in it.
// They open the page again in a background tab in the Wisp group and reload
// that one on an alarm (at least every 5 minutes; Chrome's alarms and good
// manners toward the site agree). When it matches, the tab is left open for
// the user to see; otherwise it is closed when the watch ends, unless the user
// is looking at it.
//
// A match or an ending while Wisp isn't connected can't be sent (events are
// never queued), so endings are also kept for an hour in `recentlyEnded`, and
// Wisp reads `listPageWatches` whenever it connects.
//
// Needs `pages.read` (scripting + <all_urls>), like page reading.

import { computeCapabilities, CAPABILITY_PAGES_READ } from "../lib/capabilities.js";
import { sendEvent as bridgeSendEvent } from "../lib/bridge.js";
import { truncateText } from "../lib/limits.js";
import { pageAccessForURL, PAGE_ACCESS_ACT, PAGE_ACCESS_READ_ONLY } from "../lib/page-access.js";
import { domControllerHandlers } from "./dom-controller.js";

export const PAGE_WATCH_SCRIPT_FILE = "content/page-watch.js";
export const PAGE_WATCH_STORAGE_KEY = "wispPageWatches";
export const PAGE_WATCH_REPORT_MESSAGE_TYPE = "wisp.pageWatch.report";
export const PAGE_WATCH_SWEEP_ALARM_NAME = "wisp-page-watch-sweep";
export const PAGE_WATCH_RELOAD_ALARM_PREFIX = "wisp-page-watch-reload:";
export const MISSING_PAGES_READ_ERROR = `missing capability ${CAPABILITY_PAGES_READ}`;

export const MAXIMUM_ACTIVE_PAGE_WATCHES = 5;
export const PAGE_WATCH_TIMEOUT_MILLISECONDS = 24 * 60 * 60 * 1000;
export const MINIMUM_RELOAD_EVERY_MINUTES = 5;
export const MAXIMUM_RELOAD_EVERY_MINUTES = 24 * 60;
// How long an ending is remembered for a Wisp that wasn't connected.
export const RECENTLY_ENDED_RETENTION_MILLISECONDS = 60 * 60 * 1000;
export const MAXIMUM_RECENTLY_ENDED = 20;
// Sweeps in a row the watcher couldn't be put back into the page (an error
// page, a page Chrome won't script) before the watch gives up.
export const INJECTION_FAILURES_BEFORE_GIVING_UP = 10;

export const PAGE_WATCH_ENDING_TIMED_OUT = "timedOut";
export const PAGE_WATCH_ENDING_TAB_CLOSED = "tabClosed";
export const PAGE_WATCH_ENDING_NAVIGATED_AWAY = "navigatedAway";
export const PAGE_WATCH_ENDING_PAGE_UNAVAILABLE = "pageUnavailable";
export const PAGE_WATCH_ENDING_MATCHED = "matched";

const CONDITION_KINDS = new Set(["textAppears", "textDisappears", "pageSettlesAfterChange", "numberCrosses"]);
const MAXIMUM_CONDITION_TEXT_CHARACTERS = 200;
const MAXIMUM_SELECTOR_CHARACTERS = 500;
const MAXIMUM_LABEL_CHARACTERS = 200;
const MAIN_FRAME_ID = 0;

// Turns Wisp's condition into the exact shape the page watcher reads, or
// throws saying what is wrong. The page only ever sees validated values.
export function validatedCondition(condition) {
  if (!condition || typeof condition !== "object" || !CONDITION_KINDS.has(condition.kind)) {
    throw new Error("condition.kind must be textAppears, textDisappears, pageSettlesAfterChange or numberCrosses");
  }
  const cleanedText = (value, fieldName) => {
    if (typeof value !== "string" || value.trim() === "") throw new Error(`condition.${fieldName} is needed`);
    if (value.length > MAXIMUM_CONDITION_TEXT_CHARACTERS) throw new Error(`condition.${fieldName} is too long`);
    return value.trim();
  };
  switch (condition.kind) {
    case "textAppears":
    case "textDisappears":
      return { kind: condition.kind, text: cleanedText(condition.text, "text") };
    case "pageSettlesAfterChange":
      return { kind: condition.kind };
    case "numberCrosses": {
      if (condition.direction !== "below" && condition.direction !== "above") {
        throw new Error("condition.direction must be below or above");
      }
      if (typeof condition.threshold !== "number" || !Number.isFinite(condition.threshold)) {
        throw new Error("condition.threshold must be a number");
      }
      const hasNearText = typeof condition.nearText === "string" && condition.nearText.trim() !== "";
      const hasSelector = typeof condition.selector === "string" && condition.selector.trim() !== "";
      if (!hasNearText && !hasSelector) throw new Error("condition.nearText or condition.selector is needed");
      if (hasSelector && condition.selector.length > MAXIMUM_SELECTOR_CHARACTERS) throw new Error("condition.selector is too long");
      const numberCondition = { kind: condition.kind, direction: condition.direction, threshold: condition.threshold };
      if (hasNearText) numberCondition.nearText = cleanedText(condition.nearText, "nearText");
      if (hasSelector) numberCondition.selector = condition.selector.trim();
      return numberCondition;
    }
    default:
      throw new Error("unknown condition");
  }
}

// Reload interval in whole minutes, at least 5, or null for a watch that
// waits for the page to change by itself.
export function validatedReloadEveryMinutes(reloadEveryMinutes) {
  if (reloadEveryMinutes === undefined || reloadEveryMinutes === null) return null;
  if (typeof reloadEveryMinutes !== "number" || !Number.isFinite(reloadEveryMinutes) || reloadEveryMinutes <= 0) {
    throw new Error("reloadEveryMinutes must be a number of minutes");
  }
  return Math.min(MAXIMUM_RELOAD_EVERY_MINUTES, Math.max(MINIMUM_RELOAD_EVERY_MINUTES, Math.round(reloadEveryMinutes)));
}

function originOf(pageURL) {
  try {
    return new URL(pageURL).origin;
  } catch (error) {
    return "";
  }
}

// What Wisp is told about a watch: never its evaluator state.
function publicWatch(watchRecord) {
  return {
    watchId: watchRecord.watchId,
    tabId: watchRecord.tabId,
    windowId: watchRecord.windowId,
    url: watchRecord.url,
    title: watchRecord.title,
    label: watchRecord.label,
    condition: watchRecord.condition,
    reloadEveryMinutes: watchRecord.reloadEveryMinutes,
    ownsTab: watchRecord.ownsTab,
    startedAt: watchRecord.startedAt,
    expiresAt: watchRecord.startedAt + PAGE_WATCH_TIMEOUT_MILLISECONDS,
  };
}

export function createPageWatcher({
  chromeAPI = () => globalThis.chrome,
  sendEvent = bridgeSendEvent,
  currentTimeMilliseconds = () => Date.now(),
  makeWatchID = () => globalThis.crypto.randomUUID(),
  groupTabWithWisp = (tabID) => domControllerHandlers.getOrCreateWispGroup({ tabIds: [tabID], collapsed: true }),
} = {}) {
  // MARK: - The stored list

  // Every read-modify-write of the stored list goes through this chain, so a
  // report arriving while a watch starts can't overwrite it.
  let storeUpdateChain = Promise.resolve();

  async function readStore() {
    const storedItems = await chromeAPI().storage.session.get(PAGE_WATCH_STORAGE_KEY);
    const storedValue = storedItems?.[PAGE_WATCH_STORAGE_KEY];
    return {
      watches: storedValue?.watches && typeof storedValue.watches === "object" ? { ...storedValue.watches } : {},
      recentlyEnded: Array.isArray(storedValue?.recentlyEnded) ? [...storedValue.recentlyEnded] : [],
    };
  }

  function updateStore(changeStore) {
    const updateResult = storeUpdateChain.then(async () => {
      const store = await readStore();
      const changeResult = await changeStore(store);
      const now = currentTimeMilliseconds();
      store.recentlyEnded = store.recentlyEnded
        .filter((endedWatch) => now - endedWatch.endedAt < RECENTLY_ENDED_RETENTION_MILLISECONDS)
        .slice(-MAXIMUM_RECENTLY_ENDED);
      await chromeAPI().storage.session.set({ [PAGE_WATCH_STORAGE_KEY]: store });
      return changeResult;
    });
    storeUpdateChain = updateResult.catch(() => {});
    return updateResult;
  }

  // MARK: - The page side

  // Every script that runs in a watched tab re-checks the page first
  // (contracts.md §6): a watched tab can be redirected or reloaded into a page
  // Wisp mustn't read, and the sweep and navigation paths run without a
  // request from Wisp in between.
  async function isWatchablePage(tabID) {
    let watchedTab;
    try {
      watchedTab = await chromeAPI().tabs.get(tabID);
    } catch (error) {
      return false;
    }
    if (!watchedTab || watchedTab.incognito) return false;
    const watchedPageAccess = pageAccessForURL(watchedTab.url || watchedTab.pendingUrl || "", {
      isFileSchemeAccessAllowed: await isFileSchemeAccessAllowed(),
    });
    return watchedPageAccess === PAGE_ACCESS_ACT || watchedPageAccess === PAGE_ACCESS_READ_ONLY;
  }

  async function injectWatcher(watchRecord) {
    const chrome = chromeAPI();
    if (!(await isWatchablePage(watchRecord.tabId))) {
      throw new Error("wisp can only watch web pages");
    }
    await chrome.scripting.executeScript({ target: { tabId: watchRecord.tabId }, files: [PAGE_WATCH_SCRIPT_FILE] });
    const injectionResults = await chrome.scripting.executeScript({
      target: { tabId: watchRecord.tabId },
      // Serialised by Chrome and run in the tab's isolated world, where the
      // file above defined `wispPageWatch`. It closes over nothing.
      func: (watch) => globalThis.wispPageWatch.install(watch),
      args: [{ watchId: watchRecord.watchId, condition: watchRecord.condition, state: watchRecord.state ?? {} }],
    });
    return injectionResults?.[0]?.result ?? null;
  }

  async function runInPage(tabID, pageFunction, functionArguments) {
    try {
      const injectionResults = await chromeAPI().scripting.executeScript({ target: { tabId: tabID }, func: pageFunction, args: functionArguments });
      return injectionResults?.[0]?.result ?? null;
    } catch (error) {
      return null;
    }
  }

  async function removeWatcherFromPage(watchRecord) {
    // Nothing of Wisp's runs in a page it may not read, so there's nothing
    // to take out of one either.
    if (!(await isWatchablePage(watchRecord.tabId))) return;
    await runInPage(watchRecord.tabId, (watchId) => globalThis.wispPageWatch?.uninstall(watchId), [watchRecord.watchId]);
  }

  // A tab Wisp opened for a reloading watch is closed when the watch ends,
  // unless the user is looking at it (then it's theirs now).
  async function closeOwnedTabIfUnused(watchRecord) {
    if (!watchRecord.ownsTab) return;
    const chrome = chromeAPI();
    try {
      const ownedTab = await chrome.tabs.get(watchRecord.tabId);
      if (ownedTab.active) return;
      await chrome.tabs.remove(watchRecord.tabId);
    } catch (error) {
      // Already closed.
    }
  }

  function clearReloadAlarm(watchRecord) {
    try {
      chromeAPI().alarms.clear?.(PAGE_WATCH_RELOAD_ALARM_PREFIX + watchRecord.watchId);
    } catch (error) {
      // Nothing to clear.
    }
  }

  // MARK: - Ending

  // Removes the watch and tells Wisp. `reason` is one of the endings above;
  // "matched" is sent as `watch.matched`, everything else as `watch.ended`.
  async function endWatch(watchID, reason, matchedText = null) {
    const endedRecord = await updateStore((store) => {
      const watchRecord = store.watches[watchID];
      if (!watchRecord) return null;
      delete store.watches[watchID];
      const cappedMatchedText = matchedText === null ? null : truncateText(String(matchedText), 500).text;
      store.recentlyEnded.push({ watchId: watchID, reason, matchedText: cappedMatchedText, endedAt: currentTimeMilliseconds(), label: watchRecord.label });
      return { ...watchRecord, matchedText: cappedMatchedText };
    });
    if (!endedRecord) return false;

    clearReloadAlarm(endedRecord);
    if (reason === PAGE_WATCH_ENDING_MATCHED) {
      sendEvent("watch.matched", {
        watchId: endedRecord.watchId,
        matchedText: endedRecord.matchedText,
        tabId: endedRecord.tabId,
        url: endedRecord.url,
        title: endedRecord.title,
      });
    } else {
      sendEvent("watch.ended", { watchId: endedRecord.watchId, reason });
      if (reason !== PAGE_WATCH_ENDING_TAB_CLOSED) {
        await removeWatcherFromPage(endedRecord);
        await closeOwnedTabIfUnused(endedRecord);
      }
    }
    return true;
  }

  // MARK: - Requests

  async function requirePagesReadCapability() {
    const capabilities = await computeCapabilities(chromeAPI());
    if (!capabilities.includes(CAPABILITY_PAGES_READ)) {
      throw new Error(MISSING_PAGES_READ_ERROR);
    }
  }

  async function resolveTab(tabId) {
    const chrome = chromeAPI();
    if (tabId !== undefined && tabId !== null) {
      if (!Number.isInteger(tabId)) throw new Error("tabId must be a tab id");
      return chrome.tabs.get(tabId);
    }
    const lastFocusedWindow = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
    const activeTabs = await chrome.tabs.query({ active: true, windowId: lastFocusedWindow.id });
    const activeTab = activeTabs.find((tab) => tab.active && tab.windowId === lastFocusedWindow.id);
    if (!activeTab) throw new Error("there's no tab showing in chrome");
    return activeTab;
  }

  async function isFileSchemeAccessAllowed() {
    try {
      return Boolean(await chromeAPI().extension?.isAllowedFileSchemeAccess?.());
    } catch (error) {
      return false;
    }
  }

  function ensureSweepAlarm() {
    chromeAPI().alarms.create(PAGE_WATCH_SWEEP_ALARM_NAME, { periodInMinutes: 1 });
  }

  async function startPageWatch({ tabId, condition, reloadEveryMinutes, label } = {}) {
    await requirePagesReadCapability();
    const checkedCondition = validatedCondition(condition);
    const checkedReloadEveryMinutes = validatedReloadEveryMinutes(reloadEveryMinutes);

    const chrome = chromeAPI();
    const requestedTab = await resolveTab(tabId);
    if (requestedTab.incognito) throw new Error("wisp doesn't watch incognito tabs");
    const pageURL = requestedTab.url || requestedTab.pendingUrl || "";
    const pageAccess = pageAccessForURL(pageURL, { isFileSchemeAccessAllowed: await isFileSchemeAccessAllowed() });
    if (pageAccess !== PAGE_ACCESS_ACT && pageAccess !== PAGE_ACCESS_READ_ONLY) {
      throw new Error("wisp can only watch web pages");
    }
    if (checkedReloadEveryMinutes !== null && pageAccess !== PAGE_ACCESS_ACT) {
      throw new Error("wisp only reloads web pages");
    }

    const activeWatchCount = Object.keys((await readStore()).watches).length;
    if (activeWatchCount >= MAXIMUM_ACTIVE_PAGE_WATCHES) {
      throw new Error(`already watching ${MAXIMUM_ACTIVE_PAGE_WATCHES} pages, the most at once — stop one first`);
    }

    // A reloading watch gets its own background tab (see the top of the file).
    let watchedTab = requestedTab;
    let ownsTab = false;
    if (checkedReloadEveryMinutes !== null) {
      watchedTab = await chrome.tabs.create({ windowId: requestedTab.windowId, url: pageURL, active: false });
      ownsTab = true;
      try {
        await groupTabWithWisp(watchedTab.id);
      } catch (error) {
        // Ungrouped is fine; the watch still works.
      }
    }

    const watchID = makeWatchID();
    const startedAt = currentTimeMilliseconds();
    const cappedTitle = truncateText(requestedTab.title ?? "", 500).text;
    const watchRecord = {
      watchId: watchID,
      tabId: watchedTab.id,
      windowId: watchedTab.windowId ?? requestedTab.windowId,
      url: truncateText(pageURL, 2000).text,
      origin: originOf(pageURL),
      title: cappedTitle,
      label: truncateText(typeof label === "string" ? label : "", MAXIMUM_LABEL_CHARACTERS).text,
      condition: checkedCondition,
      reloadEveryMinutes: checkedReloadEveryMinutes,
      ownsTab,
      startedAt,
      state: {},
      injectionFailureCount: 0,
    };

    const didAdd = await updateStore((store) => {
      if (Object.keys(store.watches).length >= MAXIMUM_ACTIVE_PAGE_WATCHES) return false;
      store.watches[watchID] = watchRecord;
      return true;
    });
    if (!didAdd) {
      if (ownsTab) await closeOwnedTabIfUnused(watchRecord);
      throw new Error(`already watching ${MAXIMUM_ACTIVE_PAGE_WATCHES} pages, the most at once — stop one first`);
    }

    ensureSweepAlarm();
    if (checkedReloadEveryMinutes !== null) {
      chrome.alarms.create(PAGE_WATCH_RELOAD_ALARM_PREFIX + watchID, { periodInMinutes: checkedReloadEveryMinutes });
    } else {
      // A reloading watch's new tab is still loading; nav.completed injects it.
      try {
        await injectWatcher(watchRecord);
      } catch (error) {
        await endWatch(watchID, PAGE_WATCH_ENDING_PAGE_UNAVAILABLE);
        throw new Error(`couldn't watch the page: ${String(error?.message ?? error)}`);
      }
    }
    return publicWatch(watchRecord);
  }

  async function stopPageWatch({ watchId, all } = {}) {
    const stoppedRecords = await updateStore((store) => {
      const watchIDsToStop = all === true
        ? Object.keys(store.watches)
        : (typeof watchId === "string" && store.watches[watchId] ? [watchId] : []);
      const removedRecords = watchIDsToStop.map((watchIDToStop) => store.watches[watchIDToStop]);
      for (const watchIDToStop of watchIDsToStop) delete store.watches[watchIDToStop];
      return removedRecords;
    });
    // Stopped by Wisp, so no watch.ended: Wisp already knows.
    for (const stoppedRecord of stoppedRecords) {
      clearReloadAlarm(stoppedRecord);
      await removeWatcherFromPage(stoppedRecord);
      await closeOwnedTabIfUnused(stoppedRecord);
    }
    return { stoppedCount: stoppedRecords.length };
  }

  async function listPageWatches() {
    const store = await readStore();
    const now = currentTimeMilliseconds();
    return {
      watches: Object.values(store.watches).sort((first, second) => first.startedAt - second.startedAt).map(publicWatch),
      recentlyEnded: store.recentlyEnded.filter((endedWatch) => now - endedWatch.endedAt < RECENTLY_ENDED_RETENTION_MILLISECONDS),
    };
  }

  // MARK: - Chrome's events

  // A report from the watcher in a page: its new state, or that it matched.
  // Only accepted from the tab the watch is on.
  async function handlePageReport(report, sender) {
    if (report?.type !== PAGE_WATCH_REPORT_MESSAGE_TYPE || typeof report.watchId !== "string") return;
    const senderTabID = sender?.tab?.id;
    const isFromWatchedTab = await updateStore((store) => {
      const watchRecord = store.watches[report.watchId];
      if (!watchRecord || watchRecord.tabId !== senderTabID || sender?.frameId > MAIN_FRAME_ID) return false;
      if (report.state && typeof report.state === "object") {
        watchRecord.state = report.state;
      }
      watchRecord.injectionFailureCount = 0;
      return true;
    });
    if (isFromWatchedTab && report.met === true) {
      await endWatch(report.watchId, PAGE_WATCH_ENDING_MATCHED, typeof report.matchedText === "string" ? report.matchedText : null);
    }
  }

  async function watchesOnTab(tabID) {
    return Object.values((await readStore()).watches).filter((watchRecord) => watchRecord.tabId === tabID);
  }

  // A watched tab loaded a page: put the watcher back, with what it learned —
  // unless a tab the user drives went to another site, where the question
  // ("does this tab say Deployed") no longer means anything.
  async function handleNavigationCompleted(details) {
    if (details.frameId !== MAIN_FRAME_ID) return;
    for (const watchRecord of await watchesOnTab(details.tabId)) {
      if (!watchRecord.ownsTab && originOf(details.url) !== watchRecord.origin) {
        await endWatch(watchRecord.watchId, PAGE_WATCH_ENDING_NAVIGATED_AWAY);
        continue;
      }
      try {
        await injectWatcher(watchRecord);
      } catch (error) {
        // The once-a-minute sweep tries again.
      }
    }
  }

  async function handleTabRemoved(tabID) {
    for (const watchRecord of await watchesOnTab(tabID)) {
      await endWatch(watchRecord.watchId, PAGE_WATCH_ENDING_TAB_CLOSED);
    }
  }

  async function reloadWatchedTab(watchID) {
    const watchRecord = (await readStore()).watches[watchID];
    if (!watchRecord) {
      chromeAPI().alarms.clear?.(PAGE_WATCH_RELOAD_ALARM_PREFIX + watchID);
      return;
    }
    try {
      await chromeAPI().tabs.reload(watchRecord.tabId);
    } catch (error) {
      await endWatch(watchID, PAGE_WATCH_ENDING_TAB_CLOSED);
    }
  }

  // Once a minute while anything is watched: end what timed out or lost its
  // tab, nudge every watcher to look again (a background tab's own timers can
  // be throttled to once a minute), and put back any that went missing.
  async function sweepWatches() {
    const chrome = chromeAPI();
    const watchRecords = Object.values((await readStore()).watches);
    if (watchRecords.length === 0) {
      chrome.alarms.clear?.(PAGE_WATCH_SWEEP_ALARM_NAME);
      return;
    }
    const now = currentTimeMilliseconds();
    for (const watchRecord of watchRecords) {
      if (now - watchRecord.startedAt >= PAGE_WATCH_TIMEOUT_MILLISECONDS) {
        await endWatch(watchRecord.watchId, PAGE_WATCH_ENDING_TIMED_OUT);
        continue;
      }
      try {
        await chrome.tabs.get(watchRecord.tabId);
      } catch (error) {
        await endWatch(watchRecord.watchId, PAGE_WATCH_ENDING_TAB_CLOSED);
        continue;
      }
      if (!(await isWatchablePage(watchRecord.tabId))) {
        await endWatch(watchRecord.watchId, PAGE_WATCH_ENDING_PAGE_UNAVAILABLE);
        continue;
      }
      const evaluationResult = await runInPage(
        watchRecord.tabId,
        (watchId) => globalThis.wispPageWatch?.evaluateNow(watchId) ?? "notInstalled",
        [watchRecord.watchId]
      );
      if (evaluationResult === "waiting" || evaluationResult === "met") continue;

      let didInject = false;
      try {
        didInject = Boolean(await injectWatcher(watchRecord));
      } catch (error) {
        didInject = false;
      }
      const failureCount = await updateStore((store) => {
        const storedRecord = store.watches[watchRecord.watchId];
        if (!storedRecord) return 0;
        storedRecord.injectionFailureCount = didInject ? 0 : (storedRecord.injectionFailureCount ?? 0) + 1;
        return storedRecord.injectionFailureCount;
      });
      if (failureCount >= INJECTION_FAILURES_BEFORE_GIVING_UP) {
        await endWatch(watchRecord.watchId, PAGE_WATCH_ENDING_PAGE_UNAVAILABLE);
      }
    }
  }

  // Listeners are added synchronously, so they are in place when Chrome wakes
  // the worker for one of them. Then any watches from before a worker restart
  // are put back into their pages (a no-op where the page still has them).
  function startListening() {
    const chrome = chromeAPI();
    chrome.runtime.onMessage.addListener((message, sender) => {
      if (message?.type === PAGE_WATCH_REPORT_MESSAGE_TYPE) {
        handlePageReport(message, sender);
      }
      // No reply: the bridge's own listener answers its messages.
      return false;
    });
    chrome.webNavigation.onCompleted.addListener((details) => handleNavigationCompleted(details));
    chrome.tabs.onRemoved.addListener((tabID) => handleTabRemoved(tabID));
    chrome.alarms.onAlarm.addListener((alarm) => {
      if (alarm.name === PAGE_WATCH_SWEEP_ALARM_NAME) return sweepWatches();
      if (alarm.name.startsWith(PAGE_WATCH_RELOAD_ALARM_PREFIX)) {
        return reloadWatchedTab(alarm.name.slice(PAGE_WATCH_RELOAD_ALARM_PREFIX.length));
      }
      return undefined;
    });
    return restoreWatchesAfterWorkerStart();
  }

  async function restoreWatchesAfterWorkerStart() {
    let watchRecords = [];
    try {
      watchRecords = Object.values((await readStore()).watches);
    } catch (error) {
      return;
    }
    if (watchRecords.length === 0) return;
    ensureSweepAlarm();
    for (const watchRecord of watchRecords) {
      try {
        await injectWatcher(watchRecord);
      } catch (error) {
        // The sweep tries again.
      }
    }
  }

  return {
    handlers: { startPageWatch, stopPageWatch, listPageWatches },
    startListening,
    sweepWatches,
    handlePageReport,
    handleNavigationCompleted,
    handleTabRemoved,
    reloadWatchedTab,
    endWatch,
  };
}

// The service worker's shared watcher.
const sharedPageWatcher = createPageWatcher();

export const pageWatcherHandlers = sharedPageWatcher.handlers;

export function startPageWatcherEvents() {
  return sharedPageWatcher.startListening();
}
