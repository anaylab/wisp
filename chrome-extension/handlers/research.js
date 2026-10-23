// Wisp Tabs — research mode's one primitive (phase 11).
//
// Research itself happens in Wisp: it searches in its own tab, opens sources
// in the Wisp group (openTab / openTabs), reads them (getPageText), writes the
// answer and checks every quote against the text it read. What it needs from
// here is a way to show a citation: when the user clicks one, Wisp focuses the
// source's tab and asks this handler to mark the quote in the page.
//
//   highlightTextFragments({tabId, quotes:[text], color?, scrollToFirst?})
//       → {tabId, found:[quote indexes], missing:[quote indexes]}
//
// The marks stay until the user presses Esc in the page or the page goes away.
//
// Chrome's own text fragments (`#:~:text=`) are what Wisp uses when it has to
// open a source again. For a tab that is already open, navigating to a
// fragment either reloads the page or does nothing, and never says whether it
// matched; this handler does both jobs in place and reports what it found.
//
// Needs `pages.read`. Pages the extension must never touch (contracts.md §6)
// are refused before anything is injected.

import { computeCapabilities, CAPABILITY_PAGES_READ } from "../lib/capabilities.js";
import { PAGE_ACCESS_BLANK, PAGE_ACCESS_REFUSED, pageAccessForURL } from "../lib/page-access.js";

export const QUOTE_HIGHLIGHTER_FILE = "content/quote-highlight.js";
export const MISSING_PAGES_READ_ERROR = `missing capability ${CAPABILITY_PAGES_READ}`;
export const MAXIMUM_QUOTES_PER_REQUEST = 8;
const MAXIMUM_QUOTE_CHARACTERS = 400;

// Strings only, trimmed, capped; at least one.
export function cleanedQuotesParameter(quotes) {
  if (!Array.isArray(quotes)) throw new Error("quotes must be a list of text");
  const cleanedQuotes = quotes
    .filter((quote) => typeof quote === "string" && quote.trim().length > 0)
    .slice(0, MAXIMUM_QUOTES_PER_REQUEST)
    .map((quote) => quote.trim().slice(0, MAXIMUM_QUOTE_CHARACTERS));
  if (cleanedQuotes.length === 0) throw new Error("quotes must hold at least one piece of text");
  return cleanedQuotes;
}

export function createResearchHandlers({ chromeAPI = () => globalThis.chrome } = {}) {
  async function requirePagesReadCapability() {
    const capabilities = await computeCapabilities(chromeAPI());
    if (!capabilities.includes(CAPABILITY_PAGES_READ)) throw new Error(MISSING_PAGES_READ_ERROR);
  }

  async function isFileSchemeAccessAllowed() {
    try {
      return Boolean(await chromeAPI().extension?.isAllowedFileSchemeAccess?.());
    } catch (error) {
      return false;
    }
  }

  return {
    async highlightTextFragments({ tabId, quotes, color, scrollToFirst = true } = {}) {
      if (!Number.isInteger(tabId)) throw new Error("tabId must be a tab id");
      const cleanedQuotes = cleanedQuotesParameter(quotes);
      await requirePagesReadCapability();

      const chrome = chromeAPI();
      const tab = await chrome.tabs.get(tabId);
      if (tab.incognito) throw new Error("wisp never reads or acts in incognito tabs");
      const pageAccess = pageAccessForURL(tab.url ?? tab.pendingUrl ?? "", {
        isFileSchemeAccessAllowed: await isFileSchemeAccessAllowed(),
      });
      if (pageAccess === PAGE_ACCESS_REFUSED) {
        throw new Error("wisp doesn't draw on chrome's own pages, the web store or other protected pages");
      }
      if (pageAccess === PAGE_ACCESS_BLANK) throw new Error("the tab is empty — there's nothing to highlight");

      let injectionResults;
      try {
        await chrome.scripting.executeScript({ target: { tabId }, files: [QUOTE_HIGHLIGHTER_FILE] });
        injectionResults = await chrome.scripting.executeScript({
          target: { tabId },
          // Serialised by Chrome and run in the isolated world, where the file
          // above defined `wispQuoteHighlighter`. It closes over nothing.
          func: (highlightOptions) => globalThis.wispQuoteHighlighter.showQuotes(highlightOptions),
          args: [{ quotes: cleanedQuotes, color, scrollToFirst: scrollToFirst !== false }],
        });
      } catch (error) {
        throw new Error(`couldn't highlight in the page: ${String(error?.message ?? error)}`);
      }

      const highlightResult = injectionResults?.[0]?.result;
      const found = Array.isArray(highlightResult?.found) ? highlightResult.found.filter(Number.isInteger) : [];
      const missing = Array.isArray(highlightResult?.missing)
        ? highlightResult.missing.filter(Number.isInteger)
        : cleanedQuotes.map((quote, quoteIndex) => quoteIndex).filter((quoteIndex) => !found.includes(quoteIndex));
      return { tabId, found, missing };
    },
  };
}

export const researchHandlers = createResearchHandlers();
