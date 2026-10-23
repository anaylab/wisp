// Phase 08, page watchers: the in-page watcher (content/page-watch.js) against
// fixture DOM changes, the number parser, and the worker's list of watches
// (handlers/page-watchers.js) against the fake Chrome.
//
// The DOM tests use linkedom (a devDependency; `npm install` in
// chrome-extension/) and are skipped without it, saying why.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  createPageWatcher,
  validatedCondition,
  validatedReloadEveryMinutes,
  MISSING_PAGES_READ_ERROR,
  PAGE_WATCH_SCRIPT_FILE,
  PAGE_WATCH_STORAGE_KEY,
  PAGE_WATCH_SWEEP_ALARM_NAME,
  PAGE_WATCH_RELOAD_ALARM_PREFIX,
  PAGE_WATCH_TIMEOUT_MILLISECONDS,
  MAXIMUM_ACTIVE_PAGE_WATCHES,
} from "../handlers/page-watchers.js";
import { createFakeChrome, createManualTimers } from "./fake-chrome.mjs";

// Defines globalThis.wispPageWatch, as the injected file does in a tab.
await import("../content/page-watch.js");
const pageWatch = globalThis.wispPageWatch;

let parseHTML = null;
try {
  ({ parseHTML } = await import("linkedom"));
} catch (error) {
  parseHTML = null;
}
const skipWithoutLinkedom = parseHTML ? false : "linkedom isn't installed: run `npm install` in chrome-extension/";

// MARK: - Numbers

test("numbers parse with currencies, thousands separators and decimal commas", () => {
  const expectations = [
    ["$79.99", 79.99],
    ["$1,299.99", 1299.99],
    ["1.299,99 €", 1299.99],
    ["79,99 €", 79.99],
    ["1,299", 1299],
    ["1.299", 1299],
    ["1 299 kr", 1299],
    ["CHF 1'299.50", 1299.5],
    ["£12", 12],
    ["0.125", 0.125],
    ["12345", 12345],
    ["1234,56", 1234.56],
    ["−5", -5],
    ["€ 1 299,00", 1299],
  ];
  for (const [numberText, expectedValue] of expectations) {
    assert.equal(pageWatch.parseNumberText(numberText), expectedValue, numberText);
  }
  assert.equal(pageWatch.parseNumberText("no number here"), null);
  // Two numbers with a space between are not one grouped number.
  assert.equal(pageWatch.firstNumberIn("Save 20 80 items").value, 20);
});

test("the number near a label is found after it, on its line, or on the next line", () => {
  assert.equal(pageWatch.findNumberNearText(["Rated 4.5 stars", "Price: $79.99"], "price").value, 79.99);
  assert.equal(pageWatch.findNumberNearText(["2 items", "Price", "$1,049.00"], "price").value, 1049);
  assert.equal(pageWatch.findNumberNearText(["Was $99, price now $89"], "price").value, 89);
  assert.equal(pageWatch.findNumberNearText(["Shipping $5"], "price"), null);
  // Whole words: "prices" isn't "price".
  assert.equal(pageWatch.findNumberNearText(["All prices 10% off"], "price"), null);
});

// MARK: - The evaluator, on plain observations

test("textAppears ignores what was already there and fires on a new occurrence", () => {
  const condition = { kind: "textAppears", text: "Deployed" };
  let step = pageWatch.evaluateObservation(condition, {}, { matchingLineCount: 1, lastMatchingLine: "Deployed v1" }, 0);
  assert.equal(step.met, false);
  step = pageWatch.evaluateObservation(condition, step.state, { matchingLineCount: 1 }, 1000);
  assert.equal(step.met, false);
  step = pageWatch.evaluateObservation(condition, step.state, { matchingLineCount: 2, lastMatchingLine: "Deployed v2" }, 2000);
  assert.equal(step.met, true);
  assert.equal(step.matchedText, "Deployed v2");
});

test("numberCrosses fires once the number is past the threshold", () => {
  const condition = { kind: "numberCrosses", nearText: "price", direction: "below", threshold: 80 };
  assert.equal(pageWatch.evaluateObservation(condition, {}, { value: 89.99 }, 0).met, false);
  assert.equal(pageWatch.evaluateObservation(condition, {}, { value: 80 }, 0).met, false);
  assert.equal(pageWatch.evaluateObservation(condition, {}, { value: null }, 0).met, false);
  const met = pageWatch.evaluateObservation(condition, {}, { value: 79.99, numberText: "$79.99", lineText: "Price $79.99" }, 0);
  assert.equal(met.met, true);
  assert.equal(met.matchedText, "Price $79.99");
  const aboveCondition = { ...condition, direction: "above", threshold: 100 };
  assert.equal(pageWatch.evaluateObservation(aboveCondition, {}, { value: 100.5 }, 0).met, true);
});

// MARK: - A live page

class ManualMutationObserver {
  static instances = [];
  constructor(callback) {
    this.callback = callback;
    this.isObserving = false;
    ManualMutationObserver.instances.push(this);
  }
  observe() {
    this.isObserving = true;
  }
  disconnect() {
    this.isObserving = false;
  }
  // Plays the page mutating.
  fire() {
    if (this.isObserving) this.callback([]);
  }
}

function watchedPage(html, watch) {
  const { document } = parseHTML(`<html><body>${html}</body></html>`);
  const timers = createManualTimers();
  let currentTime = 100000;
  const reports = [];
  ManualMutationObserver.instances = [];
  const installResult = pageWatch.install(watch, {
    document,
    setTimeout: timers.setTimeout,
    clearTimeout: timers.clearTimeout,
    now: () => currentTime,
    report: (report) => reports.push(report),
    MutationObserver: ManualMutationObserver,
  });
  return {
    document,
    reports,
    installResult,
    // The page changes: mutate, let the observer fire, and move the clock.
    change(mutate) {
      mutate(document);
      for (const observer of ManualMutationObserver.instances) observer.fire();
    },
    // In 100ms steps, so the page's clock and its timers move together.
    advance(milliseconds) {
      for (let elapsed = 0; elapsed < milliseconds; elapsed += 100) {
        const stepMilliseconds = Math.min(100, milliseconds - elapsed);
        currentTime += stepMilliseconds;
        timers.advance(stepMilliseconds);
      }
    },
    get metReport() {
      return reports.find((report) => report.met);
    },
  };
}

let nextTestWatchNumber = 1;
function testWatchID() {
  return `test-watch-${nextTestWatchNumber++}`;
}

test("textAppears in a page: the old 'Deployed' doesn't count, a new one does", { skip: skipWithoutLinkedom }, () => {
  const watchID = testWatchID();
  const page = watchedPage(
    `<ul id="runs"><li>Deployed v1 — 2 hours ago</li><li>abandoned run</li></ul>`,
    { watchId: watchID, condition: { kind: "textAppears", text: "deployed" } }
  );
  assert.equal(page.installResult.installed, true);
  page.advance(5000);
  assert.equal(page.metReport, undefined);

  page.change((document) => {
    const newRun = document.createElement("li");
    newRun.textContent = "Deployed v2 — just now";
    document.getElementById("runs").appendChild(newRun);
  });
  page.advance(1000);
  assert.equal(page.metReport.watchId, watchID);
  assert.equal(page.metReport.matchedText, "Deployed v2 — just now");
  // A met watch uninstalls itself.
  assert.ok(!pageWatch.installedWatchIDs().includes(watchID));
});

test("evaluations are throttled to one a second however busy the page is", { skip: skipWithoutLinkedom }, () => {
  const watchID = testWatchID();
  const page = watchedPage(`<pre id="log">start</pre>`, { watchId: watchID, condition: { kind: "textAppears", text: "BUILD SUCCEEDED" } });
  const readCountBefore = page.reports.length;
  for (let mutationIndex = 0; mutationIndex < 50; mutationIndex += 1) {
    page.change((document) => {
      document.getElementById("log").textContent += `\nline ${mutationIndex}`;
    });
  }
  page.change((document) => {
    document.getElementById("log").textContent += "\n** BUILD SUCCEEDED **";
  });
  page.advance(999);
  assert.equal(page.metReport, undefined, "nothing evaluated within the second");
  page.advance(1);
  assert.ok(page.metReport, "one evaluation after the second sees the line");
  assert.equal(page.reports.length - readCountBefore, 1);
});

test("textDisappears waits for the text to be seen, then gone twice", { skip: skipWithoutLinkedom }, () => {
  const watchID = testWatchID();
  const page = watchedPage(`<div id="status">Uploading… 40%</div>`, { watchId: watchID, condition: { kind: "textDisappears", text: "uploading" } });
  page.change((document) => {
    document.getElementById("status").textContent = "Upload complete";
  });
  page.advance(1000);
  assert.equal(page.metReport, undefined, "one absent reading isn't enough");
  page.advance(1500);
  assert.ok(page.metReport);
});

test("pageSettlesAfterChange needs a change and then ten quiet seconds", { skip: skipWithoutLinkedom }, () => {
  const watchID = testWatchID();
  const page = watchedPage(`<div id="progress">Exporting 10%</div>`, { watchId: watchID, condition: { kind: "pageSettlesAfterChange" } });
  page.advance(30000);
  assert.equal(page.metReport, undefined, "a page that never changes never settles");
  page.change((document) => {
    document.getElementById("progress").textContent = "Exporting 60%";
  });
  page.advance(1000);
  page.change((document) => {
    document.getElementById("progress").textContent = "Export finished";
  });
  page.advance(5000);
  assert.equal(page.metReport, undefined);
  page.advance(6000);
  assert.ok(page.metReport);
});

test("numberCrosses reads the price near its label and skips ignored regions", { skip: skipWithoutLinkedom }, () => {
  const watchID = testWatchID();
  const page = watchedPage(
    `<div data-wisp-ignore>Price $1.00 (secret)</div><h1>Headphones</h1><p>Price</p><p id="price">$89.99</p>`,
    { watchId: watchID, condition: { kind: "numberCrosses", nearText: "price", direction: "below", threshold: 80 } }
  );
  assert.equal(page.metReport, undefined, "$1.00 is in an ignored region");
  page.change((document) => {
    document.getElementById("price").textContent = "$79.99";
  });
  page.advance(1000);
  assert.ok(page.metReport);
  assert.match(page.metReport.matchedText, /79\.99/);
});

test("numberCrosses with a selector reads that element", { skip: skipWithoutLinkedom }, () => {
  const watchID = testWatchID();
  const page = watchedPage(
    `<span class="was">$120</span><span class="now">$1,050.00</span>`,
    { watchId: watchID, condition: { kind: "numberCrosses", selector: ".now", direction: "above", threshold: 1000 } }
  );
  assert.ok(page.metReport, "already past the threshold on the first reading");
  assert.match(page.metReport.matchedText, /1,050/);
});

test("a reinstalled watcher continues from the state it was handed", { skip: skipWithoutLinkedom }, () => {
  const firstWatchID = testWatchID();
  const firstPage = watchedPage(`<p>In stock: no</p><p>Sold out</p>`, { watchId: firstWatchID, condition: { kind: "textAppears", text: "in stock" } });
  const learnedState = firstPage.reports.at(-1).state;
  assert.equal(learnedState.fewestMatchingLineCount, 1);
  pageWatch.uninstall(firstWatchID);

  // After a reload the page has one more "in stock" line than the baseline.
  const reloadedPage = watchedPage(`<p>In stock: no</p><p>In stock — 3 left</p>`, {
    watchId: testWatchID(),
    condition: { kind: "textAppears", text: "in stock" },
    state: learnedState,
  });
  assert.ok(reloadedPage.metReport, "the reload's new line counts as appearing");
});

test("installing the same watch twice is harmless", { skip: skipWithoutLinkedom }, () => {
  const watchID = testWatchID();
  const page = watchedPage(`<p>hello</p>`, { watchId: watchID, condition: { kind: "textAppears", text: "goodbye" } });
  const secondInstall = pageWatch.install({ watchId: watchID, condition: { kind: "textAppears", text: "goodbye" } }, { document: page.document });
  assert.deepEqual(secondInstall, { installed: true, alreadyInstalled: true });
  pageWatch.uninstall(watchID);
});

// MARK: - The worker's list of watches

function grantedPagesReadChrome(options = {}) {
  const fakeChrome = createFakeChrome({
    grantedPermissions: ["scripting"],
    grantedOrigins: ["<all_urls>"],
    tabs: [
      { id: 7, windowId: 1, index: 0, active: true, title: "Run #42 · GitHub Actions", url: "https://github.com/acme/app/actions/runs/42" },
      { id: 8, windowId: 1, index: 1, active: false, title: "Headphones", url: "https://shop.example.com/headphones" },
      { id: 9, windowId: 1, index: 2, active: false, title: "Settings", url: "chrome://settings" },
    ],
    executeScript: (injection) => {
      if (injection.files) return [{ result: undefined }];
      return [{ result: options.pageResult ?? { installed: true } }];
    },
    ...options.fakeChromeOptions,
  });
  fakeChrome.alarms.clear = (alarmName) => {
    fakeChrome.calls.push(["alarms.clear", alarmName]);
    fakeChrome.state.alarms.delete(alarmName);
  };
  fakeChrome.tabs.reload = async (tabID) => {
    fakeChrome.calls.push(["tabs.reload", tabID]);
    if (!fakeChrome.state.tabs.some((tab) => tab.id === tabID)) throw new Error(`No tab with id: ${tabID}.`);
  };
  fakeChrome.extension = { isAllowedFileSchemeAccess: async () => false };
  return fakeChrome;
}

function makeWatcher(fakeChrome, overrides = {}) {
  const sentEvents = [];
  let currentTime = 1_000_000;
  let watchNumber = 0;
  const groupedTabIDs = [];
  const watcher = createPageWatcher({
    chromeAPI: () => fakeChrome,
    sendEvent: (eventName, eventData) => sentEvents.push([eventName, eventData]),
    currentTimeMilliseconds: () => currentTime,
    makeWatchID: () => `watch-${++watchNumber}`,
    groupTabWithWisp: async (tabID) => groupedTabIDs.push(tabID),
    ...overrides,
  });
  return {
    watcher,
    sentEvents,
    groupedTabIDs,
    advanceClock(milliseconds) {
      currentTime += milliseconds;
    },
    async storedWatches() {
      return (await fakeChrome.storage.session.get(PAGE_WATCH_STORAGE_KEY))[PAGE_WATCH_STORAGE_KEY];
    },
  };
}

test("conditions and reload intervals are validated before anything reaches a page", () => {
  assert.deepEqual(validatedCondition({ kind: "textAppears", text: "  Deployed " }), { kind: "textAppears", text: "Deployed" });
  assert.deepEqual(
    validatedCondition({ kind: "numberCrosses", nearText: "price", direction: "below", threshold: 80, extra: "dropped" }),
    { kind: "numberCrosses", direction: "below", threshold: 80, nearText: "price" }
  );
  assert.throws(() => validatedCondition({ kind: "eval", text: "x" }));
  assert.throws(() => validatedCondition({ kind: "textAppears", text: "" }));
  assert.throws(() => validatedCondition({ kind: "numberCrosses", direction: "below", threshold: 80 }));
  assert.throws(() => validatedCondition({ kind: "numberCrosses", nearText: "p", direction: "sideways", threshold: 80 }));
  assert.equal(validatedReloadEveryMinutes(undefined), null);
  assert.equal(validatedReloadEveryMinutes(1), 5, "at least every 5 minutes");
  assert.equal(validatedReloadEveryMinutes(30.4), 30);
  assert.throws(() => validatedReloadEveryMinutes(-3));
});

test("starting a watch needs pages.read", async () => {
  const fakeChrome = createFakeChrome({ tabs: [{ id: 7, windowId: 1, active: true, url: "https://example.com" }] });
  const { watcher } = makeWatcher(fakeChrome);
  await assert.rejects(
    watcher.handlers.startPageWatch({ condition: { kind: "textAppears", text: "Done" } }),
    { message: MISSING_PAGES_READ_ERROR }
  );
});

test("a watch on the showing tab is stored and injected with its state", async () => {
  const fakeChrome = grantedPagesReadChrome();
  const { watcher, storedWatches } = makeWatcher(fakeChrome);
  const startedWatch = await watcher.handlers.startPageWatch({ condition: { kind: "textAppears", text: "completed" }, label: "“completed” appears" });

  assert.equal(startedWatch.watchId, "watch-1");
  assert.equal(startedWatch.tabId, 7);
  assert.equal(startedWatch.ownsTab, false);
  assert.equal(startedWatch.expiresAt - startedWatch.startedAt, PAGE_WATCH_TIMEOUT_MILLISECONDS);
  assert.equal(startedWatch.state, undefined, "evaluator state never goes to Wisp");

  const injections = fakeChrome.calls.filter(([apiName]) => apiName === "scripting.executeScript").map(([, injection]) => injection);
  assert.deepEqual(injections[0].files, [PAGE_WATCH_SCRIPT_FILE]);
  assert.deepEqual(injections[1].args, [{ watchId: "watch-1", condition: { kind: "textAppears", text: "completed" }, state: {} }]);
  assert.ok(fakeChrome.state.alarms.has(PAGE_WATCH_SWEEP_ALARM_NAME));

  const stored = await storedWatches();
  assert.equal(stored.watches["watch-1"].origin, "https://github.com");

  const listed = await watcher.handlers.listPageWatches();
  assert.deepEqual(listed.watches.map((watch) => watch.label), ["“completed” appears"]);
});

test("pages Wisp may not read can't be watched", async () => {
  const fakeChrome = grantedPagesReadChrome();
  const { watcher } = makeWatcher(fakeChrome);
  await assert.rejects(watcher.handlers.startPageWatch({ tabId: 9, condition: { kind: "pageSettlesAfterChange" } }), /only watch web pages/);
});

test("at most five watches run at once", async () => {
  const fakeChrome = grantedPagesReadChrome();
  const { watcher } = makeWatcher(fakeChrome);
  for (let watchIndex = 0; watchIndex < MAXIMUM_ACTIVE_PAGE_WATCHES; watchIndex += 1) {
    await watcher.handlers.startPageWatch({ condition: { kind: "textAppears", text: `step ${watchIndex}` } });
  }
  await assert.rejects(watcher.handlers.startPageWatch({ condition: { kind: "textAppears", text: "one more" } }), /already watching 5 pages/);
});

test("a reloading watch opens its own background tab and reloads it on an alarm", async () => {
  const fakeChrome = grantedPagesReadChrome();
  const { watcher, groupedTabIDs } = makeWatcher(fakeChrome);
  const startedWatch = await watcher.handlers.startPageWatch({
    tabId: 8,
    condition: { kind: "textAppears", text: "in stock" },
    reloadEveryMinutes: 2,
  });

  assert.equal(startedWatch.ownsTab, true);
  assert.equal(startedWatch.reloadEveryMinutes, 5);
  assert.notEqual(startedWatch.tabId, 8, "the user's own tab is never reloaded");
  const createCall = fakeChrome.calls.find(([apiName]) => apiName === "tabs.create");
  assert.deepEqual(createCall[1], { windowId: 1, url: "https://shop.example.com/headphones", active: false });
  assert.deepEqual(groupedTabIDs, [startedWatch.tabId]);
  assert.deepEqual(fakeChrome.state.alarms.get(PAGE_WATCH_RELOAD_ALARM_PREFIX + "watch-1"), { periodInMinutes: 5 });

  await watcher.reloadWatchedTab("watch-1");
  assert.deepEqual(fakeChrome.calls.filter(([apiName]) => apiName === "tabs.reload"), [["tabs.reload", startedWatch.tabId]]);

  // The reload's page loading puts the watcher back, with its state.
  const injectionCountBefore = fakeChrome.calls.filter(([apiName]) => apiName === "scripting.executeScript").length;
  await watcher.handleNavigationCompleted({ tabId: startedWatch.tabId, frameId: 0, url: "https://shop.example.com/headphones" });
  const injectionCountAfter = fakeChrome.calls.filter(([apiName]) => apiName === "scripting.executeScript").length;
  assert.equal(injectionCountAfter - injectionCountBefore, 2);
});

test("a match from the watched tab ends the watch and tells Wisp; others are ignored", async () => {
  const fakeChrome = grantedPagesReadChrome();
  const { watcher, sentEvents, storedWatches } = makeWatcher(fakeChrome);
  await watcher.handlers.startPageWatch({ condition: { kind: "textAppears", text: "completed" } });

  // A report claiming to be from another tab changes nothing.
  await watcher.handlePageReport({ type: "wisp.pageWatch.report", watchId: "watch-1", met: true, matchedText: "forged" }, { tab: { id: 8 }, frameId: 0 });
  assert.deepEqual(sentEvents, []);

  await watcher.handlePageReport({ type: "wisp.pageWatch.report", watchId: "watch-1", met: false, state: { fewestMatchingLineCount: 0 } }, { tab: { id: 7 }, frameId: 0 });
  assert.deepEqual((await storedWatches()).watches["watch-1"].state, { fewestMatchingLineCount: 0 });

  await watcher.handlePageReport({ type: "wisp.pageWatch.report", watchId: "watch-1", met: true, matchedText: "Run completed in 3m" }, { tab: { id: 7 }, frameId: 0 });
  assert.deepEqual(sentEvents, [["watch.matched", {
    watchId: "watch-1",
    matchedText: "Run completed in 3m",
    tabId: 7,
    url: "https://github.com/acme/app/actions/runs/42",
    title: "Run #42 · GitHub Actions",
  }]]);
  const listed = await watcher.handlers.listPageWatches();
  assert.deepEqual(listed.watches, []);
  assert.equal(listed.recentlyEnded[0].reason, "matched");
  assert.equal(listed.recentlyEnded[0].matchedText, "Run completed in 3m");
});

test("closing the tab, leaving the site and the 24h limit each end a watch", async () => {
  const fakeChrome = grantedPagesReadChrome();
  const { watcher, sentEvents, advanceClock } = makeWatcher(fakeChrome);
  await watcher.handlers.startPageWatch({ tabId: 7, condition: { kind: "pageSettlesAfterChange" } });
  await watcher.handlers.startPageWatch({ tabId: 8, condition: { kind: "textAppears", text: "sale" } });

  await watcher.handleNavigationCompleted({ tabId: 7, frameId: 0, url: "https://github.com/acme/app/actions/runs/43" });
  assert.deepEqual(sentEvents, [], "same site: still watching");
  await watcher.handleNavigationCompleted({ tabId: 7, frameId: 0, url: "https://news.example.org/" });
  assert.deepEqual(sentEvents.at(-1), ["watch.ended", { watchId: "watch-1", reason: "navigatedAway" }]);

  await watcher.handlers.startPageWatch({ tabId: 7, condition: { kind: "textAppears", text: "done" } });
  await fakeChrome.tabs.remove(7);
  await watcher.handleTabRemoved(7);
  assert.deepEqual(sentEvents.at(-1), ["watch.ended", { watchId: "watch-3", reason: "tabClosed" }]);

  advanceClock(PAGE_WATCH_TIMEOUT_MILLISECONDS);
  await watcher.sweepWatches();
  assert.deepEqual(sentEvents.at(-1), ["watch.ended", { watchId: "watch-2", reason: "timedOut" }]);
  assert.deepEqual((await watcher.handlers.listPageWatches()).watches, []);
});

test("the sweep puts back a watcher the page lost", async () => {
  const fakeChrome = grantedPagesReadChrome({ pageResult: "notInstalled" });
  const { watcher } = makeWatcher(fakeChrome);
  await watcher.handlers.startPageWatch({ condition: { kind: "textAppears", text: "completed" } });
  const injectionCountBefore = fakeChrome.calls.filter(([apiName, injection]) => apiName === "scripting.executeScript" && injection.files).length;
  await watcher.sweepWatches();
  const injectionCountAfter = fakeChrome.calls.filter(([apiName, injection]) => apiName === "scripting.executeScript" && injection.files).length;
  assert.equal(injectionCountAfter - injectionCountBefore, 1);
});

test("stopping a reloading watch closes its tab unless the user is looking at it", async () => {
  const fakeChrome = grantedPagesReadChrome();
  const { watcher, sentEvents } = makeWatcher(fakeChrome);
  const reloadingWatch = await watcher.handlers.startPageWatch({ tabId: 8, condition: { kind: "textAppears", text: "in stock" }, reloadEveryMinutes: 10 });
  await watcher.handlers.startPageWatch({ tabId: 7, condition: { kind: "textAppears", text: "done" } });

  const stopResult = await watcher.handlers.stopPageWatch({ all: true });
  assert.equal(stopResult.stoppedCount, 2);
  assert.ok(!fakeChrome.state.tabs.some((tab) => tab.id === reloadingWatch.tabId), "Wisp's own tab is closed");
  assert.ok(fakeChrome.state.tabs.some((tab) => tab.id === 7), "the user's tab stays");
  assert.ok(!fakeChrome.state.alarms.has(PAGE_WATCH_RELOAD_ALARM_PREFIX + "watch-1"));
  assert.deepEqual(sentEvents, [], "Wisp asked, so no watch.ended");
});

test("listeners are added at start and earlier watches are put back", async () => {
  const fakeChrome = grantedPagesReadChrome();
  const { watcher } = makeWatcher(fakeChrome);
  await watcher.handlers.startPageWatch({ condition: { kind: "textAppears", text: "completed" } });

  // A new worker (same storage) starts listening.
  const { watcher: restartedWatcher } = makeWatcher(fakeChrome);
  const injectionCountBefore = fakeChrome.calls.filter(([apiName]) => apiName === "scripting.executeScript").length;
  await restartedWatcher.startListening();
  const injectionCountAfter = fakeChrome.calls.filter(([apiName]) => apiName === "scripting.executeScript").length;
  assert.equal(injectionCountAfter - injectionCountBefore, 2);
  assert.equal(fakeChrome.runtime.onMessage.listeners.length, 1);
  assert.equal(fakeChrome.tabs.onRemoved.listeners.length, 1);
  assert.equal(fakeChrome.webNavigation.onCompleted.listeners.length, 1);
});
