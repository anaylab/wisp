// Wisp Tabs — site helper scripts and their events (phase 10).
//
//   site.canvasAssignmentOpened    {tabId, windowId, url, title, dueAt}
//   site.meetingCaptionsAvailable  {tabId, windowId, url, title, site}
//
// The two helper scripts (content/canvas-assignment.js, content/meeting-
// captions.js) are registered with `chrome.scripting.registerContentScripts`
// while `pages.read` is allowed, so the manifest needs no `content_scripts`
// and nothing runs on any page until the user grants it. They tell this worker
// when an assignment opens or captions appear (`chrome.runtime.sendMessage`),
// and this file adds the tab and passes it on to Wisp.
//
// The Canvas script matches every https page whose path looks like a Canvas
// assignment, because schools run Canvas on their own domains. It reads
// nothing until the page proves to be Canvas, and Wisp only acts on hosts it
// trusts as Canvas (`*.instructure.com`, or the host of the saved Canvas feed).

import { sendEvent as bridgeSendEvent } from "../lib/bridge.js";
import { computeCapabilities, CAPABILITY_PAGES_READ } from "../lib/capabilities.js";
import { truncateText } from "../lib/limits.js";
import {
  CANVAS_ASSIGNMENT_SCRIPT_FILE,
  MEETING_CAPTIONS_SCRIPT_FILE,
  isCanvasAssignmentURL,
  meetingSiteForURL,
} from "../handlers/site-helpers.js";

export const SITE_HELPER_CONTENT_SCRIPTS = [
  {
    id: "wisp-canvas-assignment",
    matches: ["https://*/courses/*/assignments/*"],
    js: [CANVAS_ASSIGNMENT_SCRIPT_FILE],
    runAt: "document_idle",
    allFrames: false,
  },
  {
    id: "wisp-meeting-captions",
    matches: ["https://meet.google.com/*", "https://*.zoom.us/wc/*"],
    js: [MEETING_CAPTIONS_SCRIPT_FILE],
    runAt: "document_idle",
    allFrames: false,
  },
];

const CANVAS_ASSIGNMENT_OPENED_MESSAGE = "wisp.site.canvasAssignmentOpened";
const MEETING_CAPTIONS_AVAILABLE_MESSAGE = "wisp.site.meetingCaptionsAvailable";

function cappedString(value, maximumCharacters) {
  return truncateText(typeof value === "string" ? value : "", maximumCharacters).text;
}

// An ISO date the page reported, or "" — never free text from the page.
function validDateString(value) {
  if (typeof value !== "string" || value.length > 40) return "";
  return Number.isNaN(Date.parse(value)) ? "" : value;
}

export function startSiteHelperEvents({ chromeAPI = globalThis.chrome, sendEvent = bridgeSendEvent } = {}) {
  const contentScriptIDs = SITE_HELPER_CONTENT_SCRIPTS.map((contentScript) => contentScript.id);

  // Registers whichever helper scripts aren't registered yet. Registrations
  // survive a worker restart, so this usually finds both already there.
  async function registerContentScriptsIfAllowed() {
    const capabilities = await computeCapabilities(chromeAPI);
    const scriptingAPI = chromeAPI.scripting;
    if (!capabilities.includes(CAPABILITY_PAGES_READ) || !scriptingAPI?.registerContentScripts) return false;
    try {
      const registeredScripts = await scriptingAPI.getRegisteredContentScripts({ ids: contentScriptIDs });
      const registeredIDs = new Set(registeredScripts.map((contentScript) => contentScript.id));
      const missingScripts = SITE_HELPER_CONTENT_SCRIPTS.filter((contentScript) => !registeredIDs.has(contentScript.id));
      if (missingScripts.length > 0) {
        await scriptingAPI.registerContentScripts(missingScripts);
      }
      return true;
    } catch (error) {
      console.warn("Wisp Tabs: couldn't register the site helper scripts", error);
      return false;
    }
  }

  // When reading pages is taken away the scripts would no longer be allowed
  // to run anyway; unregistering keeps Chrome's list honest.
  async function unregisterContentScriptsIfNotAllowed() {
    const capabilities = await computeCapabilities(chromeAPI);
    if (capabilities.includes(CAPABILITY_PAGES_READ)) return;
    try {
      await chromeAPI.scripting?.unregisterContentScripts?.({ ids: contentScriptIDs });
    } catch (error) {
      // Not registered, or `scripting` itself was removed: nothing to undo.
    }
  }

  // Messages come only from this extension's own scripts, in a real
  // (non-incognito) tab's top frame, and only these two kinds.
  function handleRuntimeMessage(message, sender) {
    if (!message || typeof message.type !== "string") return false;
    if (message.type !== CANVAS_ASSIGNMENT_OPENED_MESSAGE && message.type !== MEETING_CAPTIONS_AVAILABLE_MESSAGE) return false;
    if (sender?.id !== chromeAPI.runtime.id) return false;
    const senderTab = sender?.tab;
    if (!senderTab || senderTab.incognito || !Number.isInteger(senderTab.id)) return false;
    if (sender.frameId !== undefined && sender.frameId !== 0) return false;
    const tabURL = senderTab.url ?? sender.url ?? "";

    if (message.type === CANVAS_ASSIGNMENT_OPENED_MESSAGE) {
      if (!isCanvasAssignmentURL(tabURL)) return false;
      sendEvent("site.canvasAssignmentOpened", {
        tabId: senderTab.id,
        windowId: senderTab.windowId,
        url: cappedString(tabURL, 2000),
        title: cappedString(message.title, 300),
        dueAt: validDateString(message.dueAt),
      });
    } else {
      const site = meetingSiteForURL(tabURL);
      if (!site) return false;
      sendEvent("site.meetingCaptionsAvailable", {
        tabId: senderTab.id,
        windowId: senderTab.windowId,
        url: cappedString(tabURL, 2000),
        title: cappedString(senderTab.title, 300),
        site,
      });
    }
    // No reply: events are fire-and-forget.
    return false;
  }

  chromeAPI.runtime.onMessage.addListener(handleRuntimeMessage);
  chromeAPI.permissions.onAdded.addListener(() => registerContentScriptsIfAllowed());
  chromeAPI.permissions.onRemoved.addListener(() => unregisterContentScriptsIfNotAllowed());
  registerContentScriptsIfAllowed();

  // Exposed for tests.
  return { handleRuntimeMessage, registerContentScriptsIfAllowed, unregisterContentScriptsIfNotAllowed };
}
