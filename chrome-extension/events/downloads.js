// Wisp Tabs — download events for Wisp (phase 07, the download concierge).
//
//   download.created    a download started
//   download.completed  it finished and the file is on disk
//   download.failed     it was interrupted (network, disk full, cancelled…)
//
// Each carries the `describeDownload` shape (absolute `filename`, `mime`,
// `fileSize`, `url`/`finalUrl`, `referrer`, `danger`/`dangerous`) plus
// `sourcePageUrl` and `pageTitle`: the page the download came from, when a tab
// still shows it. Wisp uses the title to suggest a meaningful name for a PDF or
// image, so it is looked up here, where the tabs are.
//
// `chrome.downloads` only exists after the user allows the optional
// `downloads` permission. So listeners are attached at startup when it is
// already granted, and again the moment it is granted while the worker runs.
// When the worker restarts later, the startup path finds the API in place.

import { sendEvent as bridgeSendEvent } from "../lib/bridge.js";
import { describeDownload } from "../handlers/downloads.js";

// Only these changes are reported; progress ticks (bytesReceived) would
// make the channel chatty and Wisp has no use for them.
const COMPLETED_STATE = "complete";
const INTERRUPTED_STATE = "interrupted";

export function startDownloadEvents({ chromeAPI = globalThis.chrome, sendEvent = bridgeSendEvent } = {}) {
  // The page a download came from: the referrer when Chrome kept one, or the
  // tab showing the file itself (a PDF opened in Chrome's viewer and then
  // saved). Never an incognito tab, and "" when nothing matches.
  async function sourcePageFor(downloadItem) {
    const candidateURLs = [downloadItem.referrer, downloadItem.finalUrl, downloadItem.url].filter(
      (candidateURL) => typeof candidateURL === "string" && /^https?:/i.test(candidateURL)
    );
    let openTabs = [];
    try {
      openTabs = await chromeAPI.tabs.query({});
    } catch (error) {
      openTabs = [];
    }
    for (const candidateURL of candidateURLs) {
      const matchingTab = openTabs.find((tab) => !tab.incognito && tab.url === candidateURL);
      if (matchingTab) {
        return { sourcePageUrl: candidateURL, pageTitle: matchingTab.title ?? "" };
      }
    }
    return { sourcePageUrl: candidateURLs[0] ?? "", pageTitle: "" };
  }

  async function sendDownloadEvent(eventName, downloadItem) {
    if (!downloadItem || downloadItem.incognito) return;
    const sourcePage = await sourcePageFor(downloadItem);
    sendEvent(eventName, describeDownload(downloadItem, sourcePage));
  }

  async function handleCreated(downloadItem) {
    await sendDownloadEvent("download.created", downloadItem);
  }

  async function handleChanged(downloadDelta) {
    const newState = downloadDelta?.state?.current;
    if (newState !== COMPLETED_STATE && newState !== INTERRUPTED_STATE) return;
    let matchingDownloads = [];
    try {
      matchingDownloads = await chromeAPI.downloads.search({ id: downloadDelta.id });
    } catch (error) {
      return;
    }
    const downloadItem = matchingDownloads[0];
    if (!downloadItem) return;
    await sendDownloadEvent(newState === COMPLETED_STATE ? "download.completed" : "download.failed", downloadItem);
  }

  // Safe to call more than once: `hasListener` keeps a grant that fires
  // twice (or a grant after startup already attached) from doubling events.
  function attachDownloadListenersIfAllowed() {
    const downloadsAPI = chromeAPI.downloads;
    if (!downloadsAPI) return false;
    if (!downloadsAPI.onCreated.hasListener(handleCreated)) downloadsAPI.onCreated.addListener(handleCreated);
    if (!downloadsAPI.onChanged.hasListener(handleChanged)) downloadsAPI.onChanged.addListener(handleChanged);
    return true;
  }

  chromeAPI.permissions.onAdded.addListener((addedPermissions) => {
    if ((addedPermissions?.permissions ?? []).includes("downloads")) {
      attachDownloadListenersIfAllowed();
    }
  });

  attachDownloadListenersIfAllowed();

  // Exposed for tests.
  return { handleCreated, handleChanged, attachDownloadListenersIfAllowed };
}
