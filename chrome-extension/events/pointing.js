// Wisp Tabs — what happens to Wisp's in-page marks, sent to Wisp (phase 05).
//
//   page.elementClicked     { tabId, elementId }                      the user clicked a watched element
//   page.highlightDismissed { tabId, reason, elementIds, elementId? }  Esc, or a click on a mark's label
//
// content/highlight.js sees these inside the page and posts them to the
// service worker; this file adds which tab (and frame) they came from and
// forwards them. Only this extension's own content scripts can post here
// (there is no externally_connectable), and the sender is checked anyway.

import { sendEvent as bridgeSendEvent } from "../lib/bridge.js";
import { capList } from "../lib/limits.js";
import { wireElementID } from "../handlers/pointing.js";

export const POINTING_MESSAGE_TYPE = "wisp.pointing";
const FORWARDED_EVENT_NAMES = new Set(["page.elementClicked", "page.highlightDismissed"]);
const DISMISSAL_REASONS = new Set(["escape", "label"]);
const LOCAL_ELEMENT_ID_PATTERN = /^e\d{1,9}$/;

// The event to send for a message from a content script, or null to drop it.
export function pointingEventFromMessage(message, sender, extensionID) {
  if (!message || message.type !== POINTING_MESSAGE_TYPE || !FORWARDED_EVENT_NAMES.has(message.event)) return null;
  if (!sender || sender.id !== extensionID || !sender.tab || sender.tab.incognito) return null;
  const frameId = Number.isInteger(sender.frameId) ? sender.frameId : 0;
  const toWireID = (localElementID) =>
    typeof localElementID === "string" && LOCAL_ELEMENT_ID_PATTERN.test(localElementID)
      ? wireElementID(frameId, localElementID)
      : null;
  const data = message.data ?? {};

  if (message.event === "page.elementClicked") {
    const elementId = toWireID(data.elementId);
    if (!elementId) return null;
    return { eventName: message.event, payload: { tabId: sender.tab.id, elementId } };
  }

  const payload = {
    tabId: sender.tab.id,
    reason: DISMISSAL_REASONS.has(data.reason) ? data.reason : "escape",
    elementIds: capList((Array.isArray(data.elementIds) ? data.elementIds : []).map(toWireID).filter(Boolean)).items,
  };
  const dismissedElementID = toWireID(data.elementId);
  if (dismissedElementID) payload.elementId = dismissedElementID;
  return { eventName: message.event, payload };
}

export function startPointingEvents({ chromeAPI = globalThis.chrome, sendEvent = bridgeSendEvent } = {}) {
  chromeAPI.runtime.onMessage.addListener((message, sender) => {
    const pointingEvent = pointingEventFromMessage(message, sender, chromeAPI.runtime.id);
    if (pointingEvent) sendEvent(pointingEvent.eventName, pointingEvent.payload);
    // No reply: the content script doesn't wait for one.
    return false;
  });
}
