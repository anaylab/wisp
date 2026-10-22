// Downloads (phase 07): the two handlers, the three events, the payload shape,
// and attaching listeners only once the user allows downloads.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  DOWNLOADS_NOT_ALLOWED_MESSAGE,
  describeDownload,
  downloadHandlers,
  isDangerousDownload,
} from "../handlers/downloads.js";
import { startDownloadEvents } from "../events/downloads.js";
import { MAXIMUM_TEXT_FIELD_CHARACTERS } from "../lib/limits.js";
import { createFakeChrome } from "./fake-chrome.mjs";

function downloadItem(id, overrides = {}) {
  return {
    id,
    filename: `/Users/someone/Downloads/file-${id}.pdf`,
    url: `https://arxiv.org/pdf/2401.0000${id}`,
    finalUrl: `https://arxiv.org/pdf/2401.0000${id}`,
    referrer: `https://arxiv.org/abs/2401.0000${id}`,
    mime: "application/pdf",
    fileSize: 1000 * id,
    state: "complete",
    danger: "safe",
    exists: true,
    startTime: `2026-10-2${id}T10:00:00.000Z`,
    incognito: false,
    ...overrides,
  };
}

function startEvents({ downloads = [], tabs = [], grantedPermissions = ["downloads"] } = {}) {
  const fakeChrome = createFakeChrome({ downloads, tabs, grantedPermissions });
  const sentEvents = [];
  startDownloadEvents({
    chromeAPI: fakeChrome,
    sendEvent: (eventName, eventData) => sentEvents.push({ eventName, eventData }),
  });
  return { fakeChrome, sentEvents };
}

// MARK: - Payload

test("describeDownload keeps the fields Wisp files by and marks danger", () => {
  assert.deepEqual(describeDownload(downloadItem(1), { sourcePageUrl: "https://arxiv.org/abs/2401.00001", pageTitle: "A Paper" }), {
    id: 1,
    mime: "application/pdf",
    fileSize: 1000,
    state: "complete",
    error: "",
    danger: "safe",
    dangerous: false,
    exists: true,
    startTime: "2026-10-21T10:00:00.000Z",
    endTime: "",
    filename: "/Users/someone/Downloads/file-1.pdf",
    url: "https://arxiv.org/pdf/2401.00001",
    finalUrl: "https://arxiv.org/pdf/2401.00001",
    referrer: "https://arxiv.org/abs/2401.00001",
    sourcePageUrl: "https://arxiv.org/abs/2401.00001",
    pageTitle: "A Paper",
  });
});

test("anything but safe counts as dangerous, including a flagged file the user kept", () => {
  assert.equal(isDangerousDownload({ danger: "safe" }), false);
  assert.equal(isDangerousDownload({}), false);
  for (const danger of ["file", "url", "content", "uncommon", "host", "unwanted", "accepted"]) {
    assert.equal(isDangerousDownload({ danger }), true, danger);
  }
});

test("a huge data: URL is capped and the payload says so", () => {
  const description = describeDownload(downloadItem(1, { url: "data:text/plain," + "x".repeat(30000) }));
  assert.equal(description.url.length, MAXIMUM_TEXT_FIELD_CHARACTERS);
  assert.equal(description.truncated, true);
});

// MARK: - Handlers

test("getDownloads lists newest first, capped by limit", async () => {
  globalThis.chrome = createFakeChrome({
    grantedPermissions: ["downloads"],
    downloads: [downloadItem(1), downloadItem(3), downloadItem(2)],
  });
  const result = await downloadHandlers.getDownloads({ limit: 2 });
  assert.deepEqual(result.downloads.map((download) => download.id), [3, 2]);
  assert.equal(result.truncated, undefined);
});

test("getDownloads with a downloadId returns just that one", async () => {
  globalThis.chrome = createFakeChrome({ grantedPermissions: ["downloads"], downloads: [downloadItem(1), downloadItem(2)] });
  const result = await downloadHandlers.getDownloads({ downloadId: 2 });
  assert.deepEqual(result.downloads.map((download) => download.id), [2]);
});

test("getDownloads never lists an incognito download", async () => {
  globalThis.chrome = createFakeChrome({
    grantedPermissions: ["downloads"],
    downloads: [downloadItem(1), downloadItem(2, { incognito: true })],
  });
  const result = await downloadHandlers.getDownloads({});
  assert.deepEqual(result.downloads.map((download) => download.id), [1]);
});

test("without the downloads permission the handlers say how to allow it", async () => {
  globalThis.chrome = createFakeChrome({ downloads: [downloadItem(1)] });
  await assert.rejects(downloadHandlers.getDownloads({}), { message: DOWNLOADS_NOT_ALLOWED_MESSAGE });
  await assert.rejects(downloadHandlers.showDownload({ downloadId: 1 }), { message: DOWNLOADS_NOT_ALLOWED_MESSAGE });
});

test("showDownload reveals a known download and refuses an unknown id", async () => {
  const fakeChrome = createFakeChrome({ grantedPermissions: ["downloads"], downloads: [downloadItem(1)] });
  globalThis.chrome = fakeChrome;
  assert.deepEqual(await downloadHandlers.showDownload({ downloadId: 1 }), { shown: true });
  assert.deepEqual(fakeChrome.state.shownDownloadIDs, [1]);
  await assert.rejects(downloadHandlers.showDownload({ downloadId: 9 }), /no download with id 9/);
  await assert.rejects(downloadHandlers.showDownload({}), /needs a downloadId/);
});

test("no handler moves, renames or deletes anything", () => {
  assert.deepEqual(Object.keys(downloadHandlers).sort(), ["getDownloads", "showDownload"]);
});

// MARK: - Events

test("a finished download becomes download.completed with the page it came from", async () => {
  const { fakeChrome, sentEvents } = startEvents({
    downloads: [downloadItem(1)],
    tabs: [{ id: 7, windowId: 1, url: "https://arxiv.org/abs/2401.00001", title: "[2401.00001] A Paper" }],
  });
  await fakeChrome.downloads.onChanged.dispatch({ id: 1, state: { previous: "in_progress", current: "complete" } });
  assert.equal(sentEvents.length, 1);
  assert.equal(sentEvents[0].eventName, "download.completed");
  assert.equal(sentEvents[0].eventData.filename, "/Users/someone/Downloads/file-1.pdf");
  assert.equal(sentEvents[0].eventData.sourcePageUrl, "https://arxiv.org/abs/2401.00001");
  assert.equal(sentEvents[0].eventData.pageTitle, "[2401.00001] A Paper");
});

test("with no tab showing the page, the referrer is still the source and the title is empty", async () => {
  const { fakeChrome, sentEvents } = startEvents({ downloads: [downloadItem(1)] });
  await fakeChrome.downloads.onChanged.dispatch({ id: 1, state: { current: "complete" } });
  assert.equal(sentEvents[0].eventData.sourcePageUrl, "https://arxiv.org/abs/2401.00001");
  assert.equal(sentEvents[0].eventData.pageTitle, "");
});

test("an incognito tab never lends its title", async () => {
  const { fakeChrome, sentEvents } = startEvents({
    downloads: [downloadItem(1)],
    tabs: [{ id: 7, windowId: 1, url: "https://arxiv.org/abs/2401.00001", title: "Secret", incognito: true }],
  });
  await fakeChrome.downloads.onChanged.dispatch({ id: 1, state: { current: "complete" } });
  assert.equal(sentEvents[0].eventData.pageTitle, "");
});

test("an interrupted download becomes download.failed with its error", async () => {
  const { fakeChrome, sentEvents } = startEvents({
    downloads: [downloadItem(1, { state: "interrupted", error: "NETWORK_FAILED" })],
  });
  await fakeChrome.downloads.onChanged.dispatch({ id: 1, state: { current: "interrupted" } });
  assert.equal(sentEvents[0].eventName, "download.failed");
  assert.equal(sentEvents[0].eventData.error, "NETWORK_FAILED");
});

test("progress and other changes send nothing", async () => {
  const { fakeChrome, sentEvents } = startEvents({ downloads: [downloadItem(1)] });
  await fakeChrome.downloads.onChanged.dispatch({ id: 1, bytesReceived: { current: 500 } });
  await fakeChrome.downloads.onChanged.dispatch({ id: 1, filename: { current: "/x.pdf" } });
  assert.deepEqual(sentEvents, []);
});

test("a new download sends download.created; incognito ones send nothing", async () => {
  const { fakeChrome, sentEvents } = startEvents();
  await fakeChrome.downloads.onCreated.dispatch(downloadItem(4, { state: "in_progress" }));
  await fakeChrome.downloads.onCreated.dispatch(downloadItem(5, { incognito: true }));
  assert.deepEqual(sentEvents.map((sentEvent) => [sentEvent.eventName, sentEvent.eventData.id]), [["download.created", 4]]);
});

test("a dangerous download is reported as dangerous", async () => {
  const { fakeChrome, sentEvents } = startEvents({ downloads: [downloadItem(1, { danger: "file" })] });
  await fakeChrome.downloads.onChanged.dispatch({ id: 1, state: { current: "complete" } });
  assert.equal(sentEvents[0].eventData.dangerous, true);
});

test("listeners attach only once downloads are allowed, and never twice", async () => {
  const { fakeChrome, sentEvents } = startEvents({ downloads: [downloadItem(1)], grantedPermissions: [] });
  assert.equal(fakeChrome.downloads, undefined);

  await fakeChrome.permissions.request({ permissions: ["downloads"] });
  assert.equal(fakeChrome.downloads.onChanged.listeners.length, 1);

  // Removing and granting again (the API comes back with the same events).
  await fakeChrome.permissions.remove({ permissions: ["downloads"] });
  await fakeChrome.permissions.request({ permissions: ["downloads"] });
  assert.equal(fakeChrome.downloads.onChanged.listeners.length, 1);
  assert.equal(fakeChrome.downloads.onCreated.listeners.length, 1);

  await fakeChrome.downloads.onChanged.dispatch({ id: 1, state: { current: "complete" } });
  assert.equal(sentEvents.length, 1);
});

test("granting some other permission doesn't touch downloads", async () => {
  const { fakeChrome } = startEvents({ grantedPermissions: [] });
  await fakeChrome.permissions.request({ permissions: ["scripting"], origins: ["<all_urls>"] });
  assert.equal(fakeChrome.downloads, undefined);
});
