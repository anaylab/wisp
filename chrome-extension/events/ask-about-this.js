// Wisp Tabs — "Ask Wisp about this" (phase 06): reaching Wisp from inside
// Chrome without the notch.
//
//   user.askAboutSelection  right-click a selection → Ask Wisp about “…”
//   user.askAboutImage      right-click an image    → Ask Wisp about this image
//   user.askAboutLink       right-click a link      → Ask Wisp about this link
//   user.askAboutPage       right-click the page    → Ask Wisp about this page,
//                           or the ask-wisp-about-page command (⌘⇧Y)
//   user.omniboxQuestion    "w how do I …" in the address bar
//
// "Add to Wisp brain" (page, link or selection) sends the same event the
// matching "Ask" item would, with `intent: "addToBrain"`.
//
// Events carry ids and URLs only — `tabId`, `frameId`, `pageUrl`, and
// `srcUrl` / `linkUrl` / `selectionText` from Chrome's menu info — capped by
// lib/limits.js. Wisp reads the rest itself (the selection with its context,
// the page's text) through the phase 02 methods, so the page part arrives as
// exact data rather than being read back from a screenshot. The extension
// decides nothing about what the question means.
//
// Wisp may not be running. Events are dropped while disconnected (nothing is
// queued, contracts.md §1), so instead the toolbar icon shows "!" for a few
// seconds: the user clicked and deserves to know why nothing happened.
// There's no `notifications` permission, by design.

import { sendEvent as bridgeSendEvent, isConnectedToWisp as bridgeIsConnectedToWisp } from "../lib/bridge.js";
import { truncateText } from "../lib/limits.js";
import { pageAccessForURL, PAGE_ACCESS_ACT } from "../lib/page-access.js";

export const ASK_ABOUT_PAGE_COMMAND = "ask-wisp-about-page";

export const MENU_ITEM_IDS = {
  askAboutSelection: "wisp-ask-about-selection",
  askAboutImage: "wisp-ask-about-image",
  askAboutLink: "wisp-ask-about-link",
  askAboutPage: "wisp-ask-about-page",
  addToBrain: "wisp-add-to-brain",
};

// Chrome replaces %s with the selected text (and shortens it itself).
export const CONTEXT_MENU_ITEMS = [
  { id: MENU_ITEM_IDS.askAboutSelection, title: "Ask Wisp about “%s”", contexts: ["selection"] },
  { id: MENU_ITEM_IDS.askAboutImage, title: "Ask Wisp about this image", contexts: ["image"] },
  { id: MENU_ITEM_IDS.askAboutLink, title: "Ask Wisp about this link", contexts: ["link"] },
  { id: MENU_ITEM_IDS.askAboutPage, title: "Ask Wisp about this page", contexts: ["page"] },
  { id: MENU_ITEM_IDS.addToBrain, title: "Add to Wisp brain", contexts: ["page", "link", "selection"] },
];

export const INTENT_ASK = "ask";
export const INTENT_ADD_TO_BRAIN = "addToBrain";

export const NOT_CONNECTED_BADGE_TEXT = "!";
export const NOT_CONNECTED_BADGE_MILLISECONDS = 5000;
const NOT_CONNECTED_BADGE_COLOR = [196, 92, 72, 255];
const NOT_CONNECTED_TITLE = "Wisp isn't running on this Mac — start Wisp, then try again.";
const DEFAULT_ACTION_TITLE = "Wisp Tabs";

// An omnibox question is typed by hand; anything this long was pasted and is
// still plenty for a question.
export const MAXIMUM_OMNIBOX_QUESTION_CHARACTERS = 2000;

// Copies `value` into `payload[key]` capped, and marks the payload truncated
// when it was cut. Empty and non-string values are left out.
function putCappedText(payload, key, value, maximumCharacters) {
  if (typeof value !== "string" || value.length === 0) return;
  const capped = truncateText(value, maximumCharacters);
  payload[key] = capped.text;
  if (capped.truncated) payload.truncated = true;
}

// A tab Wisp may be told about: a real tab, never an incognito one (the
// extension isn't allowed there, but a stray event shouldn't leak one).
function usableTab(tab) {
  return Boolean(tab) && Number.isInteger(tab.id) && tab.id >= 0 && !tab.incognito;
}

function basePayload(tab, pageURL, intent, source) {
  const payload = { tabId: tab.id, intent, source };
  if (Number.isInteger(tab.windowId)) payload.windowId = tab.windowId;
  putCappedText(payload, "pageUrl", pageURL ?? tab.url ?? "");
  return payload;
}

// Which event a menu click sends, and with what. Null when there's nothing
// to send (no usable tab, or an item this file didn't create). Exported for
// the tests.
export function contextMenuEventFor(clickInfo, tab) {
  if (!usableTab(tab) || !clickInfo) return null;
  const menuItemID = clickInfo.menuItemId;
  const pageURL = clickInfo.pageUrl ?? tab.url;
  // Chrome's menu text is only passed on from an ordinary web page and
  // outside a form field (contracts.md §6): a selection in a field may be a
  // password, and a local file or protected page isn't read without the
  // checks `getSelection` makes. Wisp reads the selection itself first, with
  // those checks, so leaving the text out only loses the fallback.
  const selectionTextFromMenu =
    clickInfo.editable !== true && pageAccessForURL(clickInfo.frameUrl ?? pageURL) === PAGE_ACCESS_ACT
      ? clickInfo.selectionText
      : undefined;
  const frameFields = (payload) => {
    if (Number.isInteger(clickInfo.frameId)) payload.frameId = clickInfo.frameId;
    return payload;
  };

  const selectionEvent = (intent) => {
    const payload = frameFields(basePayload(tab, pageURL, intent, "contextMenu"));
    putCappedText(payload, "selectionText", selectionTextFromMenu);
    return { eventName: "user.askAboutSelection", data: payload };
  };
  const linkEvent = (intent) => {
    const payload = frameFields(basePayload(tab, pageURL, intent, "contextMenu"));
    putCappedText(payload, "linkUrl", clickInfo.linkUrl);
    putCappedText(payload, "selectionText", selectionTextFromMenu);
    return { eventName: "user.askAboutLink", data: payload };
  };
  const pageEvent = (intent) => ({
    eventName: "user.askAboutPage",
    data: basePayload(tab, pageURL, intent, "contextMenu"),
  });

  switch (menuItemID) {
    case MENU_ITEM_IDS.askAboutSelection:
      return selectionEvent(INTENT_ASK);
    case MENU_ITEM_IDS.askAboutImage: {
      const payload = frameFields(basePayload(tab, pageURL, INTENT_ASK, "contextMenu"));
      putCappedText(payload, "srcUrl", clickInfo.srcUrl);
      if (typeof clickInfo.mediaType === "string") payload.mediaType = clickInfo.mediaType;
      return { eventName: "user.askAboutImage", data: payload };
    }
    case MENU_ITEM_IDS.askAboutLink:
      return linkEvent(INTENT_ASK);
    case MENU_ITEM_IDS.askAboutPage:
      return pageEvent(INTENT_ASK);
    case MENU_ITEM_IDS.addToBrain:
      // The most specific thing the user right-clicked: what they selected,
      // else the link, else the page.
      if (typeof clickInfo.selectionText === "string" && clickInfo.selectionText.trim()) {
        return selectionEvent(INTENT_ADD_TO_BRAIN);
      }
      if (typeof clickInfo.linkUrl === "string" && clickInfo.linkUrl) {
        return linkEvent(INTENT_ADD_TO_BRAIN);
      }
      return pageEvent(INTENT_ADD_TO_BRAIN);
    default:
      return null;
  }
}

// The omnibox question as an event, or null for an empty one.
export function omniboxEventFor(typedText, tab) {
  const question = typeof typedText === "string" ? typedText.trim() : "";
  if (!question) return null;
  const payload = {};
  putCappedText(payload, "text", question, MAXIMUM_OMNIBOX_QUESTION_CHARACTERS);
  // The question still goes without a tab (a new window, the Web Store…):
  // Wisp answers it as an ordinary typed question.
  if (usableTab(tab)) {
    payload.tabId = tab.id;
    if (Number.isInteger(tab.windowId)) payload.windowId = tab.windowId;
    putCappedText(payload, "pageUrl", tab.url ?? "");
  }
  payload.source = "omnibox";
  return { eventName: "user.omniboxQuestion", data: payload };
}

export function commandEventFor(tab) {
  if (!usableTab(tab)) return null;
  return { eventName: "user.askAboutPage", data: basePayload(tab, tab.url, INTENT_ASK, "command") };
}

export function startAskAboutThisEvents({
  chromeAPI = globalThis.chrome,
  sendEvent = bridgeSendEvent,
  isConnectedToWisp = bridgeIsConnectedToWisp,
  setTimeoutFunction = globalThis.setTimeout,
  clearTimeoutFunction = globalThis.clearTimeout,
} = {}) {
  let badgeTimerID = null;

  // Menu items persist across browser restarts, so they're (re)made on
  // install and update only. removeAll first: an update would otherwise fail
  // with "duplicate id".
  async function createContextMenus() {
    try {
      await chromeAPI.contextMenus.removeAll();
    } catch (error) {
      // Nothing to remove.
    }
    for (const menuItem of CONTEXT_MENU_ITEMS) {
      try {
        chromeAPI.contextMenus.create({ ...menuItem });
      } catch (error) {
        // A malformed item would break every later one if it threw here.
      }
    }
  }

  async function showNotConnectedHint() {
    if (badgeTimerID !== null) clearTimeoutFunction(badgeTimerID);
    try {
      await chromeAPI.action.setBadgeBackgroundColor({ color: NOT_CONNECTED_BADGE_COLOR });
      await chromeAPI.action.setBadgeText({ text: NOT_CONNECTED_BADGE_TEXT });
      await chromeAPI.action.setTitle({ title: NOT_CONNECTED_TITLE });
    } catch (error) {
      return;
    }
    badgeTimerID = setTimeoutFunction(async () => {
      badgeTimerID = null;
      try {
        await chromeAPI.action.setBadgeText({ text: "" });
        await chromeAPI.action.setTitle({ title: DEFAULT_ACTION_TITLE });
      } catch (error) {
        // The worker is going away; Chrome resets the badge with it anyway.
      }
    }, NOT_CONNECTED_BADGE_MILLISECONDS);
  }

  async function deliver(builtEvent) {
    if (!builtEvent) return;
    if (!isConnectedToWisp()) {
      await showNotConnectedHint();
      return;
    }
    sendEvent(builtEvent.eventName, builtEvent.data);
  }

  async function showingTab() {
    try {
      const [activeTab] = await chromeAPI.tabs.query({ active: true, lastFocusedWindow: true });
      return activeTab ?? null;
    } catch (error) {
      return null;
    }
  }

  async function handleContextMenuClick(clickInfo, tab) {
    await deliver(contextMenuEventFor(clickInfo, tab));
  }

  async function handleOmniboxInput(typedText) {
    await deliver(omniboxEventFor(typedText, await showingTab()));
  }

  // Chrome passes the tab since 86; the query covers anything older.
  async function handleCommand(command, tab) {
    if (command !== ASK_ABOUT_PAGE_COMMAND) return;
    await deliver(commandEventFor(tab ?? (await showingTab())));
  }

  chromeAPI.runtime.onInstalled.addListener(createContextMenus);
  chromeAPI.contextMenus.onClicked.addListener(handleContextMenuClick);
  chromeAPI.omnibox.onInputEntered.addListener(handleOmniboxInput);
  chromeAPI.commands.onCommand.addListener(handleCommand);
  try {
    chromeAPI.omnibox.setDefaultSuggestion({ description: "Ask Wisp: %s" });
  } catch (error) {
    // Only the hint under the address bar is lost.
  }

  // Exposed for tests.
  return { createContextMenus, handleContextMenuClick, handleOmniboxInput, handleCommand };
}
