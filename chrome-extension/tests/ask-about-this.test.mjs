// events/ask-about-this.js: context menus, the omnibox and ⌘⇧Y become
// user.* events carrying ids and URLs only; a click while Wisp is away shows
// "!" on the toolbar icon for a few seconds instead.

import { test } from "node:test";
import assert from "node:assert/strict";

import { createFakeChrome, createManualTimers } from "./fake-chrome.mjs";
import {
  startAskAboutThisEvents,
  contextMenuEventFor,
  omniboxEventFor,
  CONTEXT_MENU_ITEMS,
  MENU_ITEM_IDS,
  ASK_ABOUT_PAGE_COMMAND,
  NOT_CONNECTED_BADGE_MILLISECONDS,
  MAXIMUM_OMNIBOX_QUESTION_CHARACTERS,
} from "../events/ask-about-this.js";

const pageTab = { id: 7, windowId: 2, url: "https://docs.example.com/guide", title: "Guide", active: true, incognito: false };

function startWithFakes({ isConnected = true, tabs = [pageTab] } = {}) {
  const fakeChrome = createFakeChrome({
    windows: [{ id: 2, type: "normal", focused: true, incognito: false }],
    tabs,
  });
  const sentEvents = [];
  const timers = createManualTimers();
  let connected = isConnected;
  const handlers = startAskAboutThisEvents({
    chromeAPI: fakeChrome,
    sendEvent: (name, data) => sentEvents.push([name, data]),
    isConnectedToWisp: () => connected,
    setTimeoutFunction: timers.setTimeout,
    clearTimeoutFunction: timers.clearTimeout,
  });
  return { fakeChrome, sentEvents, timers, handlers, setConnected: (value) => (connected = value) };
}

test("installing creates the five menu items, and an update doesn't duplicate them", async () => {
  const { fakeChrome } = startWithFakes();
  await fakeChrome.runtime.onInstalled.dispatch({ reason: "install" });
  await fakeChrome.runtime.onInstalled.dispatch({ reason: "update" });

  assert.deepEqual(
    fakeChrome.state.menuItems.map((menuItem) => [menuItem.id, menuItem.contexts]),
    CONTEXT_MENU_ITEMS.map((menuItem) => [menuItem.id, menuItem.contexts])
  );
  assert.equal(fakeChrome.state.menuItems[0].title, "Ask Wisp about “%s”");
  assert.deepEqual(fakeChrome.state.menuItems.find((item) => item.id === MENU_ITEM_IDS.addToBrain).contexts, ["page", "link", "selection"]);
  assert.equal(fakeChrome.state.omniboxDefaultSuggestion.description, "Ask Wisp: %s");
});

test("each menu item sends its event with ids and URLs only", async () => {
  const { fakeChrome, sentEvents } = startWithFakes();
  const dispatchClick = (info) => fakeChrome.contextMenus.onClicked.dispatch({ pageUrl: pageTab.url, frameId: 0, ...info }, pageTab);

  await dispatchClick({ menuItemId: MENU_ITEM_IDS.askAboutSelection, selectionText: "the mitochondria" });
  await dispatchClick({ menuItemId: MENU_ITEM_IDS.askAboutImage, srcUrl: "https://cdn.example.com/cell.png", mediaType: "image" });
  await dispatchClick({ menuItemId: MENU_ITEM_IDS.askAboutLink, linkUrl: "https://example.com/next" });
  await dispatchClick({ menuItemId: MENU_ITEM_IDS.askAboutPage });

  const base = { tabId: 7, windowId: 2, pageUrl: "https://docs.example.com/guide", source: "contextMenu" };
  assert.deepEqual(sentEvents, [
    ["user.askAboutSelection", { ...base, intent: "ask", frameId: 0, selectionText: "the mitochondria" }],
    ["user.askAboutImage", { ...base, intent: "ask", frameId: 0, srcUrl: "https://cdn.example.com/cell.png", mediaType: "image" }],
    ["user.askAboutLink", { ...base, intent: "ask", frameId: 0, linkUrl: "https://example.com/next" }],
    ["user.askAboutPage", { ...base, intent: "ask" }],
  ]);
  // Nothing from the page beyond what Chrome's menu info carries: no title.
  for (const [, data] of sentEvents) assert.equal("title" in data, false);
});

test("Add to Wisp brain picks the selection, else the link, else the page", () => {
  const brainClick = (info) => contextMenuEventFor({ menuItemId: MENU_ITEM_IDS.addToBrain, pageUrl: pageTab.url, ...info }, pageTab);

  const selection = brainClick({ selectionText: "quote", linkUrl: "https://example.com/x" });
  assert.equal(selection.eventName, "user.askAboutSelection");
  assert.equal(selection.data.intent, "addToBrain");

  const link = brainClick({ linkUrl: "https://example.com/x", selectionText: "   " });
  assert.equal(link.eventName, "user.askAboutLink");
  assert.equal(link.data.intent, "addToBrain");
  assert.equal(link.data.linkUrl, "https://example.com/x");

  const page = brainClick({});
  assert.equal(page.eventName, "user.askAboutPage");
  assert.equal(page.data.intent, "addToBrain");
});

test("menu text from a form field or a protected page isn't passed on (contracts §6)", () => {
  const selectionClick = (info) =>
    contextMenuEventFor({ menuItemId: MENU_ITEM_IDS.askAboutSelection, selectionText: "hunter2", ...info }, pageTab);

  const inField = selectionClick({ pageUrl: pageTab.url, editable: true });
  assert.equal(inField.eventName, "user.askAboutSelection");
  assert.equal("selectionText" in inField.data, false);

  assert.equal("selectionText" in selectionClick({ pageUrl: "file:///Users/me/notes.html" }).data, false);
  assert.equal("selectionText" in selectionClick({ pageUrl: "https://chromewebstore.google.com/detail/x" }).data, false);
  assert.equal(
    "selectionText" in selectionClick({ pageUrl: pageTab.url, frameUrl: "chrome-extension://abc/page.html" }).data,
    false,
    "the frame the selection is in is what counts"
  );
  assert.equal(selectionClick({ pageUrl: pageTab.url }).data.selectionText, "hunter2", "ordinary page text still goes");

  const brainInField = contextMenuEventFor(
    { menuItemId: MENU_ITEM_IDS.addToBrain, pageUrl: pageTab.url, editable: true, selectionText: "secret" },
    pageTab
  );
  assert.equal(brainInField.eventName, "user.askAboutSelection", "still a selection, which Wisp reads with getSelection");
  assert.equal("selectionText" in brainInField.data, false);
});

test("no tab, an incognito tab or someone else's menu item sends nothing", () => {
  assert.equal(contextMenuEventFor({ menuItemId: MENU_ITEM_IDS.askAboutPage }, undefined), null);
  assert.equal(contextMenuEventFor({ menuItemId: MENU_ITEM_IDS.askAboutPage }, { id: -1 }), null);
  assert.equal(contextMenuEventFor({ menuItemId: MENU_ITEM_IDS.askAboutPage }, { ...pageTab, incognito: true }), null);
  assert.equal(contextMenuEventFor({ menuItemId: "someone-else" }, pageTab), null);
});

test("a huge selection or image address is capped and marked truncated", () => {
  const event = contextMenuEventFor(
    { menuItemId: MENU_ITEM_IDS.askAboutSelection, selectionText: "x".repeat(30000), pageUrl: pageTab.url },
    pageTab
  );
  assert.equal(event.data.selectionText.length, 20000);
  assert.equal(event.data.truncated, true);

  const imageEvent = contextMenuEventFor(
    { menuItemId: MENU_ITEM_IDS.askAboutImage, srcUrl: "data:image/png;base64," + "A".repeat(40000), pageUrl: pageTab.url },
    pageTab
  );
  assert.equal(imageEvent.data.srcUrl.length, 20000);
  assert.equal(imageEvent.data.truncated, true);
});

test("the omnibox sends the trimmed question with the showing tab", async () => {
  const { fakeChrome, sentEvents } = startWithFakes();
  await fakeChrome.omnibox.onInputEntered.dispatch("  how do I cite this?  ", "currentTab");
  await fakeChrome.omnibox.onInputEntered.dispatch("   ", "currentTab");

  assert.deepEqual(sentEvents, [
    ["user.omniboxQuestion", { text: "how do I cite this?", tabId: 7, windowId: 2, pageUrl: "https://docs.example.com/guide", source: "omnibox" }],
  ]);
  assert.equal(omniboxEventFor("q".repeat(5000), null).data.text.length, MAXIMUM_OMNIBOX_QUESTION_CHARACTERS);
  assert.deepEqual(omniboxEventFor("hi", null).data, { text: "hi", source: "omnibox" });
});

test("⌘⇧Y sends user.askAboutPage for the tab it was pressed in", async () => {
  const { fakeChrome, sentEvents } = startWithFakes();
  await fakeChrome.commands.onCommand.dispatch(ASK_ABOUT_PAGE_COMMAND, pageTab);
  // Without a tab from Chrome, the showing tab.
  await fakeChrome.commands.onCommand.dispatch(ASK_ABOUT_PAGE_COMMAND, undefined);
  await fakeChrome.commands.onCommand.dispatch("some-other-command", pageTab);

  const expected = ["user.askAboutPage", { tabId: 7, windowId: 2, pageUrl: "https://docs.example.com/guide", intent: "ask", source: "command" }];
  assert.deepEqual(sentEvents, [expected, expected]);
});

test("while Wisp isn't connected, a click shows ! on the toolbar icon for 5s and sends nothing", async () => {
  const { fakeChrome, sentEvents, timers, setConnected } = startWithFakes({ isConnected: false });
  await fakeChrome.contextMenus.onClicked.dispatch({ menuItemId: MENU_ITEM_IDS.askAboutPage, pageUrl: pageTab.url }, pageTab);

  assert.equal(sentEvents.length, 0);
  assert.equal(fakeChrome.state.badgeText, "!");
  assert.match(fakeChrome.state.actionTitle, /isn't running/);

  timers.advance(NOT_CONNECTED_BADGE_MILLISECONDS - 1);
  assert.equal(fakeChrome.state.badgeText, "!");
  timers.advance(1);
  // The reset runs in an async callback.
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(fakeChrome.state.badgeText, "");

  // A second click restarts the 5s rather than stacking timers.
  await fakeChrome.commands.onCommand.dispatch(ASK_ABOUT_PAGE_COMMAND, pageTab);
  await fakeChrome.commands.onCommand.dispatch(ASK_ABOUT_PAGE_COMMAND, pageTab);
  assert.equal(timers.pendingTimerCount, 1);

  setConnected(true);
  await fakeChrome.commands.onCommand.dispatch(ASK_ABOUT_PAGE_COMMAND, pageTab);
  assert.equal(sentEvents.length, 1);
});
