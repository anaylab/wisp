// The connection to Wisp: hello, the request dispatcher, events, keep-alive
// and the reconnect wiring, driven through a fake WebSocket.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  createBridge,
  KEEP_ALIVE_INTERVAL_MILLISECONDS,
  RECONNECT_ALARM_NAME,
  WISP_BRIDGE_URL,
} from "../lib/bridge.js";
import { createFakeChrome, createManualTimers, FakeWebSocket } from "./fake-chrome.mjs";

function makeBridge({ fakeChrome = createFakeChrome(), getCapabilities, timers = createManualTimers() } = {}) {
  FakeWebSocket.instances = [];
  const bridge = createBridge({
    chromeAPI: fakeChrome,
    WebSocketImplementation: FakeWebSocket,
    getCapabilities,
    setIntervalFunction: timers.setInterval,
    clearIntervalFunction: timers.clearInterval,
    currentTimeMilliseconds: () => 1700000000000,
  });
  return { bridge, fakeChrome, timers };
}

async function connectedBridge(options) {
  const made = makeBridge(options);
  made.bridge.connectToWisp();
  const socket = FakeWebSocket.instances[0];
  await socket.simulateOpen();
  socket.sentMessages.length = 0;
  return { ...made, socket };
}

test("hello carries the version, browser name and capabilities", async () => {
  const { bridge, fakeChrome } = makeBridge({
    fakeChrome: createFakeChrome({ grantedPermissions: ["downloads"] }),
  });
  bridge.connectToWisp();
  const socket = FakeWebSocket.instances[0];
  assert.equal(socket.url, WISP_BRIDGE_URL);
  await socket.simulateOpen();

  assert.deepEqual(socket.sentMessages[0], {
    type: "hello",
    extensionVersion: "1.1.0",
    browserName: "Chrome",
    capabilities: ["tabs", "downloads"],
  });
  assert.equal(fakeChrome.state.sessionStorage.isConnectedToWisp, true);
});

test("hello falls back to tabs when the capability check fails", async () => {
  const { bridge } = makeBridge({
    getCapabilities: async () => {
      throw new Error("boom");
    },
  });
  bridge.connectToWisp();
  await FakeWebSocket.instances[0].simulateOpen();
  assert.deepEqual(FakeWebSocket.instances[0].sentMessages[0].capabilities, ["tabs"]);
});

test("connecting twice while a socket is open or opening makes one socket", async () => {
  const { bridge } = makeBridge();
  bridge.connectToWisp();
  bridge.connectToWisp();
  assert.equal(FakeWebSocket.instances.length, 1);
  await FakeWebSocket.instances[0].simulateOpen();
  bridge.connectToWisp();
  assert.equal(FakeWebSocket.instances.length, 1);
});

test("a closed socket is replaced on the next connect", async () => {
  const { bridge, socket, fakeChrome } = await connectedBridge();
  socket.simulateClose();
  assert.equal(bridge.isConnectedToWisp(), false);
  assert.equal(fakeChrome.state.sessionStorage.isConnectedToWisp, false);
  bridge.connectToWisp();
  assert.equal(FakeWebSocket.instances.length, 2);
});

test("a WebSocket constructor that throws records the extension as disconnected", () => {
  const fakeChrome = createFakeChrome();
  const bridge = createBridge({
    chromeAPI: fakeChrome,
    WebSocketImplementation: class {
      constructor() {
        throw new Error("refused");
      }
    },
  });
  bridge.connectToWisp();
  assert.equal(fakeChrome.state.sessionStorage.isConnectedToWisp, false);
});

// MARK: - Dispatcher

test("an unknown method gets an error reply", async () => {
  const { bridge, socket } = await connectedBridge();
  bridge.registerHandlers({ async knownMethod() {} });
  await socket.simulateMessage({ id: 7, method: "noSuchMethod", params: {} });
  assert.deepEqual(socket.sentMessages, [{ id: 7, error: "unknown method noSuchMethod" }]);
});

test("inherited object names are not methods", async () => {
  const { socket } = await connectedBridge();
  await socket.simulateMessage({ id: 8, method: "toString" });
  await socket.simulateMessage({ id: 9, method: "__proto__" });
  assert.deepEqual(socket.sentMessages, [
    { id: 8, error: "unknown method toString" },
    { id: 9, error: "unknown method __proto__" },
  ]);
});

test("a handler that throws gets an error reply with its message", async () => {
  const { bridge, socket } = await connectedBridge();
  bridge.registerHandlers({
    async failingMethod() {
      throw new Error("tabIds must be a non-empty list of tab ids");
    },
    async throwsAString() {
      throw "plain text";
    },
  });
  await socket.simulateMessage({ id: 1, method: "failingMethod", params: {} });
  await socket.simulateMessage({ id: 2, method: "throwsAString" });
  assert.deepEqual(socket.sentMessages, [
    { id: 1, error: "tabIds must be a non-empty list of tab ids" },
    { id: 2, error: "plain text" },
  ]);
});

test("a successful handler gets its params and replies with its result", async () => {
  const { bridge, socket } = await connectedBridge();
  let receivedParams;
  bridge.registerHandlers({
    async echo(params) {
      receivedParams = params;
      return { echoed: params.value };
    },
    async returnsNothing() {},
  });
  await socket.simulateMessage({ id: 3, method: "echo", params: { value: 42, timeoutSeconds: 20 } });
  await socket.simulateMessage({ id: 4, method: "returnsNothing" });
  assert.deepEqual(receivedParams, { value: 42, timeoutSeconds: 20 });
  assert.deepEqual(socket.sentMessages, [
    { id: 3, result: { echoed: 42 } },
    { id: 4, result: {} },
  ]);
});

test("missing params reach the handler as an empty object", async () => {
  const { bridge, socket } = await connectedBridge();
  let receivedParams;
  bridge.registerHandlers({
    async inspect(params) {
      receivedParams = params;
    },
  });
  await socket.simulateMessage({ id: 5, method: "inspect" });
  assert.deepEqual(receivedParams, {});
});

test("malformed frames and frames without a numeric id or method are ignored", async () => {
  const { bridge, socket } = await connectedBridge();
  bridge.registerHandlers({ async method() {} });
  await socket.simulateMessage("{not json");
  await socket.simulateMessage({ id: "1", method: "method" });
  await socket.simulateMessage({ id: 1 });
  await socket.simulateMessage("null");
  assert.deepEqual(socket.sentMessages, []);
});

test("registering the same method twice throws", () => {
  const { bridge } = makeBridge();
  bridge.registerHandlers({ async getTabs() {} });
  assert.throws(() => bridge.registerHandlers({ async getTabs() {} }), /already registered/);
});

// MARK: - Events and capabilities

test("events are sent with name, data and time while connected", async () => {
  const { bridge, socket } = await connectedBridge();
  bridge.sendEvent("tab.removed", { id: 4 });
  bridge.sendEvent("window.focused");
  assert.deepEqual(socket.sentMessages, [
    { type: "event", event: "tab.removed", data: { id: 4 }, at: 1700000000000 },
    { type: "event", event: "window.focused", data: {}, at: 1700000000000 },
  ]);
});

test("events while disconnected are dropped, not queued", async () => {
  const { bridge } = makeBridge();
  bridge.sendEvent("tab.created", { id: 1 });
  bridge.connectToWisp();
  const socket = FakeWebSocket.instances[0];
  bridge.sendEvent("tab.created", { id: 2 }); // still connecting
  await socket.simulateOpen();
  assert.deepEqual(
    socket.sentMessages.map((message) => message.type),
    ["hello"]
  );
});

test("capabilities are sent as their own message", async () => {
  const { bridge, socket } = await connectedBridge();
  bridge.sendCapabilities(["tabs", "pages.read"]);
  assert.deepEqual(socket.sentMessages, [{ type: "capabilities", capabilities: ["tabs", "pages.read"] }]);
});

// MARK: - Keep-alive and lifecycle

test("a ping goes out every 20 seconds while connected, and stops on close", async () => {
  const { socket, timers } = await connectedBridge();
  timers.advance(KEEP_ALIVE_INTERVAL_MILLISECONDS * 2);
  assert.deepEqual(socket.sentMessages, [{ type: "ping" }, { type: "ping" }]);
  socket.simulateClose();
  assert.equal(timers.pendingTimerCount, 0);
});

test("startBridge creates the 30s reconnect alarm, connects, and reconnects on the alarm", async () => {
  const { bridge, fakeChrome } = makeBridge();
  bridge.startBridge();
  assert.deepEqual(fakeChrome.state.alarms.get(RECONNECT_ALARM_NAME), { periodInMinutes: 0.5 });
  assert.equal(FakeWebSocket.instances.length, 1);

  FakeWebSocket.instances[0].simulateClose();
  await fakeChrome.alarms.onAlarm.dispatch({ name: "some-other-alarm" });
  assert.equal(FakeWebSocket.instances.length, 1);
  await fakeChrome.alarms.onAlarm.dispatch({ name: RECONNECT_ALARM_NAME });
  assert.equal(FakeWebSocket.instances.length, 2);
});

test("the popup's reconnect message reconnects and answers", async () => {
  const { bridge, fakeChrome } = makeBridge();
  bridge.startBridge();
  FakeWebSocket.instances[0].simulateClose();
  let response;
  await fakeChrome.runtime.onMessage.dispatch({ type: "reconnect" }, {}, (reply) => {
    response = reply;
  });
  assert.deepEqual(response, { ok: true });
  assert.equal(FakeWebSocket.instances.length, 2);
});
