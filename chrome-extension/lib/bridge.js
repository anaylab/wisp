// Wisp Tabs — the connection to Wisp.
//
// Why a WebSocket that the extension dials out on: an MV3 service worker cannot
// listen for connections, and Wisp already runs on the same machine. The socket
// only ever goes to 127.0.0.1, and Wisp only accepts it because the handshake's
// Origin is this extension's fixed ID (pinned by the "key" in manifest.json).
//
// This module owns that socket: connecting, the keep-alive, the reconnect
// alarm, answering Wisp's requests with whichever handler was registered for
// the method, and sending unsolicited events. It knows nothing about tabs or
// any other feature; those live in handlers/ and events/.
//
// `createBridge` takes its dependencies (WebSocket, chrome, timers) so the
// tests can drive it without a real socket. The service worker uses the shared
// instance behind the plain exported functions at the bottom.

import { computeCapabilities } from "./capabilities.js";

// Must match `ChromeExtensionBridge.listeningPort` in Wisp.
export const WISP_BRIDGE_URL = "ws://127.0.0.1:47823";

// Chrome ends an idle MV3 service worker after ~30s. Traffic on an open
// WebSocket extends its life (Chrome 116+), so a small ping keeps it resident
// while Wisp is connected.
export const KEEP_ALIVE_INTERVAL_MILLISECONDS = 20 * 1000;

// When Wisp isn't running there is no socket to keep the worker alive, so an
// alarm wakes it to try again. 30s is the shortest period Chrome allows.
export const RECONNECT_ALARM_NAME = "wisp-reconnect";
export const RECONNECT_ALARM_PERIOD_MINUTES = 0.5;

// Where the per-profile id sent in `hello` is kept.
export const INSTANCE_ID_STORAGE_KEY = "wispInstanceId";

// WebSocket.OPEN / CONNECTING, spelled out so an injected fake needn't
// carry the constants.
const SOCKET_STATE_CONNECTING = 0;
const SOCKET_STATE_OPEN = 1;

export function createBridge({
  chromeAPI = globalThis.chrome,
  WebSocketImplementation = globalThis.WebSocket,
  bridgeURL = WISP_BRIDGE_URL,
  getCapabilities = () => computeCapabilities(chromeAPI),
  setIntervalFunction = globalThis.setInterval,
  clearIntervalFunction = globalThis.clearInterval,
  currentTimeMilliseconds = () => Date.now(),
} = {}) {
  let wispSocket = null;
  let keepAliveTimerID = null;
  const requestHandlers = {};

  // MARK: - Connection

  function connectToWisp() {
    if (
      wispSocket &&
      (wispSocket.readyState === SOCKET_STATE_OPEN || wispSocket.readyState === SOCKET_STATE_CONNECTING)
    ) {
      return;
    }

    let socket;
    try {
      socket = new WebSocketImplementation(bridgeURL);
    } catch (error) {
      recordConnectionStatus(false);
      return;
    }
    wispSocket = socket;

    socket.onopen = async () => {
      // Wisp treats the extension as connected only once `hello` arrives, so
      // no request can reach a handler before the capabilities are known.
      let capabilities;
      try {
        capabilities = await getCapabilities();
      } catch (error) {
        capabilities = ["tabs"];
      }
      let instanceId;
      try {
        instanceId = await installationIdentifier();
      } catch (error) {
        instanceId = undefined;
      }
      if (wispSocket !== socket) return;
      sendToWisp({
        type: "hello",
        extensionVersion: extensionVersion(),
        browserName: browserName(),
        capabilities,
        instanceId,
      });
      startKeepAlive();
      recordConnectionStatus(true);
    };

    // Returns the handling promise so tests can wait for the reply; Chrome
    // ignores it.
    socket.onmessage = (event) => handleMessageFromWisp(event.data);

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

  function isConnectedToWisp() {
    return Boolean(wispSocket && wispSocket.readyState === SOCKET_STATE_OPEN);
  }

  // Sends one JSON message if the socket is open, and drops it otherwise.
  // Nothing is queued: Wisp re-reads whatever state it needs when the
  // extension connects again.
  function sendToWisp(message) {
    if (isConnectedToWisp()) {
      wispSocket.send(JSON.stringify(message));
    }
  }

  // Unsolicited, fire-and-forget: Wisp never replies to an event.
  function sendEvent(eventName, eventData) {
    sendToWisp({ type: "event", event: eventName, data: eventData ?? {}, at: currentTimeMilliseconds() });
  }

  function sendCapabilities(capabilities) {
    sendToWisp({ type: "capabilities", capabilities });
  }

  function startKeepAlive() {
    stopKeepAlive();
    keepAliveTimerID = setIntervalFunction(() => sendToWisp({ type: "ping" }), KEEP_ALIVE_INTERVAL_MILLISECONDS);
  }

  function stopKeepAlive() {
    if (keepAliveTimerID !== null) {
      clearIntervalFunction(keepAliveTimerID);
      keepAliveTimerID = null;
    }
  }

  function recordConnectionStatus(isConnected) {
    chromeAPI.storage.session.set({ isConnectedToWisp: isConnected, connectionStatusChangedAt: currentTimeMilliseconds() });
  }

  function extensionVersion() {
    return chromeAPI.runtime.getManifest().version;
  }

  // The browser's own brand ("Google Chrome", "Microsoft Edge", "Opera").
  // Brave hides its brand but exposes `navigator.brave`. Arc and Vivaldi
  // report only "Chromium", which is what they're called here; Wisp names
  // them properly from the app that owns the socket, which the extension
  // can't see.
  function browserName() {
    if (globalThis.navigator?.brave) return "Brave";
    const userAgentBrands = globalThis.navigator?.userAgentData?.brands;
    if (!Array.isArray(userAgentBrands)) return "Chrome";
    const namedBrand = userAgentBrands.find((brand) => !/not.a.brand|chromium/i.test(brand.brand));
    if (namedBrand) return namedBrand.brand;
    return userAgentBrands.some((brand) => /chromium/i.test(brand.brand)) ? "Chromium" : "Chrome";
  }

  // A random id kept in this profile's local storage, so Wisp can tell two
  // profiles of one browser apart (each runs its own copy of the extension).
  // It identifies nothing outside this Mac and never leaves the loopback
  // socket.
  async function installationIdentifier() {
    const storedItems = await chromeAPI.storage.local.get(INSTANCE_ID_STORAGE_KEY);
    const storedIdentifier = storedItems?.[INSTANCE_ID_STORAGE_KEY];
    if (typeof storedIdentifier === "string" && storedIdentifier) return storedIdentifier;
    const newIdentifier = globalThis.crypto.randomUUID();
    await chromeAPI.storage.local.set({ [INSTANCE_ID_STORAGE_KEY]: newIdentifier });
    return newIdentifier;
  }

  // MARK: - Requests from Wisp

  // Each feature file exports a map of method name → async handler(params).
  // A name registered twice is a bug (two phases claiming one method), so it
  // throws at startup instead of one silently replacing the other.
  function registerHandlers(handlerMap) {
    for (const [methodName, handler] of Object.entries(handlerMap)) {
      if (Object.prototype.hasOwnProperty.call(requestHandlers, methodName)) {
        throw new Error(`handler for ${methodName} is already registered`);
      }
      requestHandlers[methodName] = handler;
    }
  }

  async function handleMessageFromWisp(rawMessage) {
    let request;
    try {
      request = JSON.parse(rawMessage);
    } catch (error) {
      return;
    }
    if (typeof request?.id !== "number" || typeof request.method !== "string") {
      return;
    }

    const handler = Object.prototype.hasOwnProperty.call(requestHandlers, request.method)
      ? requestHandlers[request.method]
      : undefined;
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

  // MARK: - Lifecycle

  // Listeners are added synchronously so they are in place when Chrome wakes
  // the worker for the alarm or for startup.
  function startBridge() {
    chromeAPI.alarms.create(RECONNECT_ALARM_NAME, { periodInMinutes: RECONNECT_ALARM_PERIOD_MINUTES });

    chromeAPI.alarms.onAlarm.addListener((alarm) => {
      if (alarm.name === RECONNECT_ALARM_NAME) connectToWisp();
    });

    chromeAPI.runtime.onStartup.addListener(connectToWisp);
    chromeAPI.runtime.onInstalled.addListener(connectToWisp);

    // The popup's "Try again" button.
    chromeAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
      if (message?.type === "reconnect") {
        connectToWisp();
        sendResponse({ ok: true });
      }
    });

    connectToWisp();
  }

  return {
    connectToWisp,
    isConnectedToWisp,
    sendToWisp,
    sendEvent,
    sendCapabilities,
    registerHandlers,
    handleMessageFromWisp,
    startBridge,
  };
}

// MARK: - The service worker's shared bridge

let sharedBridge = null;

function bridge() {
  sharedBridge ??= createBridge();
  return sharedBridge;
}

export function registerHandlers(handlerMap) {
  bridge().registerHandlers(handlerMap);
}

export function sendEvent(eventName, eventData) {
  bridge().sendEvent(eventName, eventData);
}

export function sendCapabilities(capabilities) {
  bridge().sendCapabilities(capabilities);
}

export function isConnectedToWisp() {
  return bridge().isConnectedToWisp();
}

export function startBridge() {
  bridge().startBridge();
}
