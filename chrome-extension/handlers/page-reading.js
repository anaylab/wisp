// Wisp Tabs — reading a tab's text, selection and headings (phase 02).
//
// Wisp asks for a page's text instead of encoding a screenshot when the
// question is about what the page says ("summarize this tab", "what's the
// price"). The reading itself is content/read-page.js, injected on demand;
// this file decides which tab, refuses pages the extension must never read
// (contracts.md §6), and caps what goes back over the socket.
//
// Needs the `pages.read` capability (scripting + <all_urls>). Without it every
// method fails with "missing capability pages.read", which Wisp turns into
// plain words about where to allow it.

import { computeCapabilities, CAPABILITY_PAGES_READ } from "../lib/capabilities.js";
import { truncateText, capList, MAXIMUM_TEXT_FIELD_CHARACTERS } from "../lib/limits.js";
import { isExtensionStoreURL } from "../lib/page-access.js";

export const PAGE_READER_SCRIPT_FILE = "content/read-page.js";
export const MISSING_PAGES_READ_ERROR = `missing capability ${CAPABILITY_PAGES_READ}`;

// Chrome refuses scripting on the Web Store anyway; refusing first gives a
// clear reason instead of Chrome's "cannot be scripted".

// Why a page can't be read, or null when it can. http(s) pages are readable;
// file:// only when the user turned on "Allow access to file URLs" for the
// extension (and then only to read); everything else — chrome://,
// chrome-extension://, devtools://, view-source:, about:, data: — never.
export function forbiddenPageReason(pageURL, { isFileSchemeAccessAllowed = false } = {}) {
  let parsedURL;
  try {
    parsedURL = new URL(pageURL);
  } catch (error) {
    return "this tab has no web page to read";
  }
  const protocol = parsedURL.protocol.toLowerCase();
  if (protocol === "http:" || protocol === "https:") {
    if (isExtensionStoreURL(pageURL)) {
      return "the browser doesn't let extensions read its extension store";
    }
    return null;
  }
  if (protocol === "file:") {
    return isFileSchemeAccessAllowed
      ? null
      : "reading local files needs \"allow access to file urls\" turned on for wisp tabs in chrome://extensions";
  }
  return `wisp doesn't read ${protocol.replace(/:$/, "")}: pages`;
}

async function requirePagesReadCapability() {
  const capabilities = await computeCapabilities(chrome);
  if (!capabilities.includes(CAPABILITY_PAGES_READ)) {
    throw new Error(MISSING_PAGES_READ_ERROR);
  }
}

// The tab to read: the one asked for, or the showing tab of the window the
// user was last in.
async function resolveTab(tabId) {
  if (tabId !== undefined && tabId !== null) {
    if (!Number.isInteger(tabId)) {
      throw new Error("tabId must be a tab id");
    }
    return chrome.tabs.get(tabId);
  }
  const lastFocusedWindow = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
  const activeTabs = await chrome.tabs.query({ active: true, windowId: lastFocusedWindow.id });
  // Filtered again here: the window id is what decides, not the query alone.
  const activeTab = activeTabs.find((tab) => tab.active && tab.windowId === lastFocusedWindow.id);
  if (!activeTab) {
    throw new Error("there's no tab showing in chrome");
  }
  return activeTab;
}

async function isFileSchemeAccessAllowed() {
  try {
    return Boolean(await chrome.extension?.isAllowedFileSchemeAccess?.());
  } catch (error) {
    return false;
  }
}

// Runs one reader function in the tab's top frame and returns its result.
async function readInTab(tab, readerFunctionName, readerOptions) {
  if (tab.incognito) {
    throw new Error("wisp doesn't read incognito tabs");
  }
  const tabURL = tab.url || tab.pendingUrl || "";
  const refusalReason = forbiddenPageReason(tabURL, { isFileSchemeAccessAllowed: await isFileSchemeAccessAllowed() });
  if (refusalReason) {
    throw new Error(refusalReason);
  }

  let injectionResults;
  try {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: [PAGE_READER_SCRIPT_FILE] });
    injectionResults = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      // Serialised by Chrome and run in the page's isolated world, where the
      // file above defined `wispPageReader`. It closes over nothing.
      func: (functionName, options) => globalThis.wispPageReader[functionName](document, options),
      args: [readerFunctionName, readerOptions ?? {}],
    });
  } catch (error) {
    throw new Error(`couldn't read the page: ${String(error?.message ?? error)}`);
  }

  const readerResult = injectionResults?.[0]?.result;
  if (!readerResult || typeof readerResult !== "object") {
    throw new Error("couldn't read the page: it returned nothing");
  }
  return readerResult;
}

// What every reply starts with: which tab it was, in the shape Wisp knows.
function tabIdentity(tab, readerResult) {
  const cappedTitle = truncateText(readerResult.title || tab.title || "", 500);
  return {
    tabId: tab.id,
    windowId: tab.windowId,
    url: tab.url || tab.pendingUrl || "",
    title: cappedTitle.text,
  };
}

function cappedField(value, maximumCharacters) {
  return truncateText(typeof value === "string" ? value : "", maximumCharacters).text;
}

export const pageReadingHandlers = {
  // The main text of a page as lines (headings as "#", list items as "- ",
  // table rows joined with " | "), plus its metadata.
  async getPageText({ tabId, maximumCharacters } = {}) {
    await requirePagesReadCapability();
    const tab = await resolveTab(tabId);
    const requestedMaximum = Number.isInteger(maximumCharacters)
      ? Math.min(Math.max(maximumCharacters, 1), MAXIMUM_TEXT_FIELD_CHARACTERS)
      : MAXIMUM_TEXT_FIELD_CHARACTERS;
    const readerResult = await readInTab(tab, "readPageText", { maximumCharacters: requestedMaximum });
    const cappedText = truncateText(readerResult.text, requestedMaximum);
    return {
      ...tabIdentity(tab, readerResult),
      canonicalUrl: cappedField(readerResult.canonicalUrl, 2000),
      lang: cappedField(readerResult.lang, 40),
      description: cappedField(readerResult.description, 1000),
      publishedDate: cappedField(readerResult.publishedDate, 100),
      text: cappedText.text,
      wordCount: Number.isInteger(readerResult.wordCount) ? readerResult.wordCount : 0,
      characterCount: Number.isInteger(readerResult.characterCount) ? readerResult.characterCount : cappedText.text.length,
      truncated: Boolean(readerResult.truncated) || cappedText.truncated,
    };
  },

  // What the user selected, with ~300 characters either side for context.
  async getSelection({ tabId } = {}) {
    await requirePagesReadCapability();
    const tab = await resolveTab(tabId);
    const readerResult = await readInTab(tab, "readSelection", {});
    const cappedSelection = truncateText(readerResult.selectedText);
    return {
      ...tabIdentity(tab, readerResult),
      hasSelection: Boolean(readerResult.hasSelection) && cappedSelection.text.length > 0,
      selectedText: cappedSelection.text,
      contextBefore: cappedField(readerResult.contextBefore, 2000),
      contextAfter: cappedField(readerResult.contextAfter, 2000),
      truncated: Boolean(readerResult.truncated) || cappedSelection.truncated,
    };
  },

  // The page's headings in order, with their levels.
  async getPageOutline({ tabId } = {}) {
    await requirePagesReadCapability();
    const tab = await resolveTab(tabId);
    const readerResult = await readInTab(tab, "readPageOutline", {});
    const validHeadings = (Array.isArray(readerResult.headings) ? readerResult.headings : [])
      .filter((heading) => heading && typeof heading.text === "string" && heading.text.length > 0)
      .map((heading) => ({
        level: Number.isInteger(heading.level) ? Math.min(Math.max(heading.level, 1), 6) : 2,
        text: cappedField(heading.text, 300),
      }));
    const cappedHeadings = capList(validHeadings);
    return {
      ...tabIdentity(tab, readerResult),
      headings: cappedHeadings.items,
      truncated: Boolean(readerResult.truncated) || cappedHeadings.truncated,
    };
  },
};
