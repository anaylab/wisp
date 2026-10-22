// Wisp Tabs — reading Chrome's downloads (phase 07, the download concierge).
//
// Two primitives: list recent downloads, and show one in Finder. The extension
// never renames, moves or deletes a downloaded file: Wisp does that on disk,
// after the user said yes, because Wisp owns the decision and the filesystem.
//
// `chrome.downloads` only exists once the user has allowed the optional
// `downloads` permission (the "downloads" capability), so every handler checks
// for it and says what to do when it's missing.

import { capList, truncateText } from "../lib/limits.js";

// One request lists at most this many; Wisp asks for far fewer.
export const MAXIMUM_LISTED_DOWNLOADS = 100;
export const DEFAULT_LISTED_DOWNLOADS = 20;

export const DOWNLOADS_NOT_ALLOWED_MESSAGE =
  "downloads aren't allowed yet. in chrome, open the wisp tabs extension's options and allow downloads.";

// Chrome's `danger` values other than these mean Chrome (or Safe Browsing)
// flagged the file. "accepted" is a flagged file the user chose to keep, which
// is still not something Wisp should rename or move on its own.
const SAFE_DANGER_VALUES = new Set(["safe", ""]);

export function requireDownloadsAPI(chromeAPI = globalThis.chrome) {
  if (!chromeAPI?.downloads) {
    throw new Error(DOWNLOADS_NOT_ALLOWED_MESSAGE);
  }
  return chromeAPI.downloads;
}

export function isDangerousDownload(downloadItem) {
  return !SAFE_DANGER_VALUES.has(downloadItem?.danger ?? "");
}

// The shape Wisp knows a download by, shared by `getDownloads` and the
// download events. `filename` is Chrome's absolute path on disk. Every text
// field is capped (a data: URL can be enormous) and `truncated` says so.
// `sourcePageUrl` / `pageTitle` are filled in by the events, which can look
// for the tab the download came from; they are "" here.
export function describeDownload(downloadItem, { sourcePageUrl = "", pageTitle = "" } = {}) {
  const textFields = {
    filename: downloadItem.filename ?? "",
    url: downloadItem.url ?? "",
    finalUrl: downloadItem.finalUrl ?? downloadItem.url ?? "",
    referrer: downloadItem.referrer ?? "",
    sourcePageUrl,
    pageTitle,
  };
  const description = {
    id: downloadItem.id,
    mime: downloadItem.mime ?? "",
    fileSize: Math.max(downloadItem.fileSize ?? downloadItem.totalBytes ?? 0, 0),
    state: downloadItem.state ?? "",
    error: downloadItem.error ?? "",
    danger: downloadItem.danger ?? "",
    dangerous: isDangerousDownload(downloadItem),
    exists: downloadItem.exists !== false,
    startTime: downloadItem.startTime ?? "",
    endTime: downloadItem.endTime ?? "",
  };
  let wasTruncated = false;
  for (const [fieldName, fieldText] of Object.entries(textFields)) {
    const cappedField = truncateText(fieldText);
    description[fieldName] = cappedField.text;
    wasTruncated ||= cappedField.truncated;
  }
  if (wasTruncated) {
    description.truncated = true;
  }
  return description;
}

function clampedLimit(requestedLimit) {
  const numericLimit = Number.isInteger(requestedLimit) ? requestedLimit : DEFAULT_LISTED_DOWNLOADS;
  return Math.min(Math.max(numericLimit, 1), MAXIMUM_LISTED_DOWNLOADS);
}

export const downloadHandlers = {
  // The most recent downloads, newest first. `downloadId` narrows it to one
  // download, which is how Wisp re-reads a file's current path before moving it.
  async getDownloads({ limit, downloadId } = {}) {
    const downloadsAPI = requireDownloadsAPI(chrome);
    const query = Number.isInteger(downloadId)
      ? { id: downloadId }
      : { orderBy: ["-startTime"], limit: clampedLimit(limit) };
    const downloadItems = await downloadsAPI.search(query);
    // Incognito downloads never reach the extension ("incognito": "not_allowed");
    // this is a second lock on the same door.
    const visibleDownloads = downloadItems.filter((downloadItem) => !downloadItem.incognito).map((downloadItem) => describeDownload(downloadItem));
    const cappedDownloads = capList(visibleDownloads);
    const result = { downloads: cappedDownloads.items };
    if (cappedDownloads.truncated) result.truncated = true;
    return result;
  },

  // Reveals the file in Finder (Chrome's own "Show in folder"). Read-only.
  async showDownload({ downloadId } = {}) {
    const downloadsAPI = requireDownloadsAPI(chrome);
    if (!Number.isInteger(downloadId)) {
      throw new Error("showDownload needs a downloadId");
    }
    const matchingDownloads = await downloadsAPI.search({ id: downloadId });
    if (matchingDownloads.length === 0 || matchingDownloads[0].incognito) {
      throw new Error(`no download with id ${downloadId}`);
    }
    downloadsAPI.show(downloadId);
    return { shown: true };
  },
};
