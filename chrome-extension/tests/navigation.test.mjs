// events/navigation.js: main-frame navigations become nav.committed /
// nav.completed; subframes are ignored.

import { test } from "node:test";
import assert from "node:assert/strict";

import { createFakeChrome } from "./fake-chrome.mjs";
import { startNavigationEvents } from "../events/navigation.js";

test("main-frame commits and completions are sent, subframes are not", async () => {
  const fakeChrome = createFakeChrome();
  const sentEvents = [];
  startNavigationEvents({ chromeAPI: fakeChrome, sendEvent: (name, data) => sentEvents.push([name, data]) });

  await fakeChrome.webNavigation.onCommitted.dispatch({ tabId: 4, frameId: 0, url: "https://a.example/", transitionType: "link" });
  await fakeChrome.webNavigation.onCommitted.dispatch({ tabId: 4, frameId: 9, url: "https://ads.example/" });
  await fakeChrome.webNavigation.onCompleted.dispatch({ tabId: 4, frameId: 0, url: "https://a.example/" });
  await fakeChrome.webNavigation.onCompleted.dispatch({ tabId: 4, frameId: 9, url: "https://ads.example/" });

  assert.deepEqual(sentEvents, [
    ["nav.committed", { tabId: 4, url: "https://a.example/", transitionType: "link" }],
    ["nav.completed", { tabId: 4, url: "https://a.example/" }],
  ]);
});

test("a huge URL is capped and marked truncated", async () => {
  const fakeChrome = createFakeChrome();
  const sentEvents = [];
  startNavigationEvents({ chromeAPI: fakeChrome, sendEvent: (name, data) => sentEvents.push([name, data]) });

  await fakeChrome.webNavigation.onCompleted.dispatch({ tabId: 1, frameId: 0, url: "https://a.example/?" + "x".repeat(30000) });

  assert.equal(sentEvents[0][1].url.length, 20000);
  assert.equal(sentEvents[0][1].truncated, true);
});
