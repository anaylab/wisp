// Wisp Tabs — background service worker.
//
// This extension is deliberately thin. It holds one WebSocket to Wisp on this
// Mac and exposes primitives (tab ops today; page reading and more as the user
// grants them). Every decision about *what* to do is made by Wisp, where it
// can be tested and where the model lives; the extension only does what it is
// told, and only through Chrome's APIs.
//
// This file only wires the pieces together (contracts.md §4):
//   lib/bridge.js         the socket to Wisp, requests, events, reconnecting
//   lib/capabilities.js   what the user has allowed, re-sent when it changes
//   handlers/*.js         one map of request handlers per feature
//   events/*.js           chrome.* listeners that send events to Wisp
//
// Everything here runs synchronously at the top level, so Chrome finds every
// listener in place when it wakes the worker for an event.

import { registerHandlers, sendCapabilities, startBridge } from "./lib/bridge.js";
import { startCapabilityBroadcasts } from "./lib/capabilities.js";
import { tabHandlers } from "./handlers/tabs.js";
import { capabilityHandlers } from "./handlers/capabilities.js";
import { startTabEvents } from "./events/tabs.js";

registerHandlers(tabHandlers);
registerHandlers(capabilityHandlers);

startCapabilityBroadcasts(sendCapabilities);
startTabEvents();

startBridge();
