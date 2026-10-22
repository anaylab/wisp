// Wisp Tabs — main-frame navigation events for Wisp (phase 03).
//
//   nav.committed  { tabId, url, transitionType }  a navigation took effect
//   nav.completed  { tabId, url }                  its page finished loading
//
// Main frames only: subframe navigations (ads, embeds) would flood the
// channel and say nothing about where the tab is. Fire-and-forget like every
// event, and dropped while Wisp isn't connected. Incognito tabs never reach
// the extension ("incognito": "not_allowed").

import { sendEvent as bridgeSendEvent } from "../lib/bridge.js";
import { truncateText } from "../lib/limits.js";

const MAIN_FRAME_ID = 0;

function navigationPayload(details, extraFields) {
  const cappedURL = truncateText(details.url ?? "");
  const payload = { tabId: details.tabId, url: cappedURL.text, ...extraFields };
  if (cappedURL.truncated) payload.truncated = true;
  return payload;
}

export function startNavigationEvents({ chromeAPI = globalThis.chrome, sendEvent = bridgeSendEvent } = {}) {
  chromeAPI.webNavigation.onCommitted.addListener((details) => {
    if (details.frameId !== MAIN_FRAME_ID) return;
    sendEvent("nav.committed", navigationPayload(details, { transitionType: details.transitionType ?? "" }));
  });

  chromeAPI.webNavigation.onCompleted.addListener((details) => {
    if (details.frameId !== MAIN_FRAME_ID) return;
    sendEvent("nav.completed", navigationPayload(details, {}));
  });
}
