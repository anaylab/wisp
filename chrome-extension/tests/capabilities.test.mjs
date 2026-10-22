// Capability computation and the re-broadcast when permissions change.

import { test } from "node:test";
import assert from "node:assert/strict";

import { computeCapabilities, startCapabilityBroadcasts } from "../lib/capabilities.js";
import { createFakeChrome } from "./fake-chrome.mjs";

test("tabs alone when nothing optional is granted", async () => {
  assert.deepEqual(await computeCapabilities(createFakeChrome()), ["tabs"]);
});

test("pages.read needs both scripting and every site", async () => {
  assert.deepEqual(await computeCapabilities(createFakeChrome({ grantedPermissions: ["scripting"] })), ["tabs"]);
  assert.deepEqual(await computeCapabilities(createFakeChrome({ grantedOrigins: ["<all_urls>"] })), ["tabs"]);
  assert.deepEqual(
    await computeCapabilities(createFakeChrome({ grantedPermissions: ["scripting"], grantedOrigins: ["<all_urls>"] })),
    ["tabs", "pages.read"]
  );
});

test("downloads, and everything in a fixed order", async () => {
  assert.deepEqual(await computeCapabilities(createFakeChrome({ grantedPermissions: ["downloads"] })), [
    "tabs",
    "downloads",
  ]);
  assert.deepEqual(
    await computeCapabilities(
      createFakeChrome({ grantedPermissions: ["downloads", "scripting"], grantedOrigins: ["<all_urls>"] })
    ),
    ["tabs", "pages.read", "downloads"]
  );
});

test("a permission Chrome doesn't know reads as not granted", async () => {
  const fakeChrome = createFakeChrome({ grantedPermissions: ["downloads"], unknownPermissionNames: ["downloads"] });
  assert.deepEqual(await computeCapabilities(fakeChrome), ["tabs"]);
});

test("granting and removing a permission re-sends the fresh list", async () => {
  const fakeChrome = createFakeChrome();
  const broadcasts = [];
  startCapabilityBroadcasts((capabilities) => broadcasts.push(capabilities), fakeChrome);

  await fakeChrome.permissions.request({ permissions: ["scripting"], origins: ["<all_urls>"] });
  await fakeChrome.permissions.request({ permissions: ["downloads"] });
  await fakeChrome.permissions.remove({ permissions: ["scripting"], origins: ["<all_urls>"] });

  assert.deepEqual(broadcasts, [
    ["tabs", "pages.read"],
    ["tabs", "pages.read", "downloads"],
    ["tabs", "downloads"],
  ]);
});
