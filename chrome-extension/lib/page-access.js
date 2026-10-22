// Wisp Tabs — which pages the extension may read or act in (contracts.md §6).
//
// Pure (no `chrome`), so the rule is tested on its own and every feature that
// injects into a page asks the same question before it does.
//
// Never: Chrome's own pages (chrome://, chrome-extension://, devtools://,
// edge://, view-source:…), the Chrome Web Store, data:/blob:/javascript:
// URLs, and file:// unless the user turned on "Allow access to file URLs" —
// and even then only to read. Incognito tabs never reach the extension (the
// manifest says "incognito": "not_allowed"); callers still check
// `tab.incognito` as a second lock.

export const PAGE_ACCESS_ACT = "act";
export const PAGE_ACCESS_READ_ONLY = "read";
// about:blank: nothing to read and nothing to act on, but not an error —
// Wisp's own task tab starts there.
export const PAGE_ACCESS_BLANK = "blank";
export const PAGE_ACCESS_REFUSED = "refused";

const CHROME_WEB_STORE_HOSTS = new Set(["chrome.google.com", "chromewebstore.google.com"]);

export function pageAccessForURL(pageURL, { isFileSchemeAccessAllowed = false } = {}) {
  if (typeof pageURL !== "string" || pageURL === "" || pageURL === "about:blank") {
    return PAGE_ACCESS_BLANK;
  }
  let parsedURL;
  try {
    parsedURL = new URL(pageURL);
  } catch (error) {
    return PAGE_ACCESS_REFUSED;
  }
  if (parsedURL.protocol === "http:" || parsedURL.protocol === "https:") {
    if (CHROME_WEB_STORE_HOSTS.has(parsedURL.hostname) &&
        (parsedURL.hostname !== "chrome.google.com" || parsedURL.pathname.startsWith("/webstore"))) {
      return PAGE_ACCESS_REFUSED;
    }
    return PAGE_ACCESS_ACT;
  }
  if (parsedURL.protocol === "file:") {
    return isFileSchemeAccessAllowed ? PAGE_ACCESS_READ_ONLY : PAGE_ACCESS_REFUSED;
  }
  return PAGE_ACCESS_REFUSED;
}

// Where Wisp may send a tab: ordinary web pages, or a blank tab to start in.
export function isNavigableURL(pageURL) {
  if (pageURL === "about:blank") return true;
  try {
    const parsedURL = new URL(pageURL);
    return (parsedURL.protocol === "http:" || parsedURL.protocol === "https:") &&
      pageAccessForURL(pageURL) === PAGE_ACCESS_ACT;
  } catch (error) {
    return false;
  }
}
