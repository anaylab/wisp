// The service worker's wiring: importing background.js against the fake
// Chrome registers every handler and listener, connects, and answers requests.

import { test } from "node:test";
import assert from "node:assert/strict";

import { createFakeChrome, FakeWebSocket } from "./fake-chrome.mjs";

test("background.js wires the bridge, handlers, capabilities and tab events", async () => {
  const fakeChrome = createFakeChrome({
    tabs: [{ id: 1, windowId: 1, index: 0, title: "One", url: "https://one.example" }],
  });
  globalThis.chrome = fakeChrome;
  globalThis.WebSocket = FakeWebSocket;
  FakeWebSocket.instances = [];

  await import("../background.js");

  // Listeners Chrome needs at wake-up are all in place.
  assert.equal(fakeChrome.tabs.onUpdated.listeners.length, 1);
  assert.equal(fakeChrome.windows.onFocusChanged.listeners.length, 1);
  // One for the capability broadcast, one that attaches the download
  // listeners when the user allows downloads.
  assert.equal(fakeChrome.permissions.onAdded.listeners.length, 2);
  // The bridge's reconnect alarm, and the page watchers' sweep and reloads.
  assert.equal(fakeChrome.alarms.onAlarm.listeners.length, 2);
  assert.equal(fakeChrome.webNavigation.onCommitted.listeners.length, 1);
  // The popup's Try again, and in-page pointing's clicks and dismissals.
  assert.equal(fakeChrome.runtime.onMessage.listeners.length, 2);
  // "Ask Wisp about this": menus, the omnibox and ⌘⇧Y.
  assert.equal(fakeChrome.contextMenus.onClicked.listeners.length, 1);
  assert.equal(fakeChrome.omnibox.onInputEntered.listeners.length, 1);
  assert.equal(fakeChrome.commands.onCommand.listeners.length, 1);
  // nav.completed, and putting page watchers back after a page loads.
  assert.equal(fakeChrome.webNavigation.onCompleted.listeners.length, 2);

  const socket = FakeWebSocket.instances[0];
  try {
    await checkWiring(fakeChrome, socket);
  } finally {
    // Closing stops the real keep-alive interval, so the test process can exit.
    socket.simulateClose();
  }
});

async function checkWiring(fakeChrome, socket) {
  await socket.simulateOpen();
  assert.deepEqual(socket.sentMessages[0].capabilities, ["tabs"]);

  await socket.simulateMessage({ id: 1, method: "getTabs", params: {} });
  await socket.simulateMessage({ id: 2, method: "getCapabilities", params: {} });
  assert.deepEqual(
    socket.sentMessages[1].result.tabs.map((tab) => tab.id),
    [1]
  );
  assert.deepEqual(socket.sentMessages[2], { id: 2, result: { capabilities: ["tabs"] } });

  // Granting a permission reaches Wisp as a capabilities message.
  await fakeChrome.permissions.request({ permissions: ["downloads"] });
  assert.deepEqual(socket.sentMessages.at(-1), { type: "capabilities", capabilities: ["tabs", "downloads"] });

  // The DOM controller's handlers are registered and answer (the fake page
  // has no agent to run, so this one answers with an error).
  await socket.simulateMessage({ id: 3, method: "snapshotPage", params: { tabId: 1 } });
  assert.equal(socket.sentMessages.at(-1).id, 3);
  assert.ok(socket.sentMessages.at(-1).error);
  // Allowing downloads attaches the download listeners at once.
  assert.equal(fakeChrome.downloads.onChanged.listeners.length, 1);

  // Tab events go out through the same socket.
  await fakeChrome.windows.onFocusChanged.dispatch(1);
  assert.equal(socket.sentMessages.at(-1).event, "window.focused");
}
