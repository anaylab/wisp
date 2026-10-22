// Wisp Tabs — what the user has let the extension do (contracts.md §3).
//
// Everything beyond tabs is an optional Chrome permission the user grants on
// the options page. Wisp can't grant anything itself (Chrome only shows the
// permission prompt from a click inside an extension page), so the extension
// tells Wisp what it currently has: in `hello`, and again in a `capabilities`
// message whenever a permission is granted or removed. A feature that needs a
// missing capability then says so in plain words instead of failing.
//
// This module never touches `chrome` at import time, so the popup, the
// options page and the tests can all import it.

export const CAPABILITY_TABS = "tabs";
export const CAPABILITY_PAGES_READ = "pages.read";
export const CAPABILITY_DOWNLOADS = "downloads";

// The Chrome permissions behind each optional capability, in the shape
// `chrome.permissions.contains` / `request` / `remove` take. A capability
// counts as granted only when all of it is.
export const OPTIONAL_CAPABILITY_PERMISSIONS = {
  [CAPABILITY_PAGES_READ]: { permissions: ["scripting"], origins: ["<all_urls>"] },
  [CAPABILITY_DOWNLOADS]: { permissions: ["downloads"] },
};

// Tabs are always there (they're required permissions), followed by each
// optional capability that is fully granted, in a fixed order.
export async function computeCapabilities(chromeAPI = globalThis.chrome) {
  const grantedCapabilities = [CAPABILITY_TABS];
  for (const [capability, requiredPermissions] of Object.entries(OPTIONAL_CAPABILITY_PERMISSIONS)) {
    let isGranted = false;
    try {
      isGranted = await chromeAPI.permissions.contains(requiredPermissions);
    } catch (error) {
      // An unknown permission name (an older Chrome) reads as not granted.
      isGranted = false;
    }
    if (isGranted) {
      grantedCapabilities.push(capability);
    }
  }
  return grantedCapabilities;
}

// Calls `onCapabilitiesChanged(list)` with the fresh list whenever the user
// grants or removes a permission, from the options page or from Chrome's own
// extension settings.
export function startCapabilityBroadcasts(onCapabilitiesChanged, chromeAPI = globalThis.chrome) {
  const broadcastCurrentCapabilities = async () => {
    onCapabilitiesChanged(await computeCapabilities(chromeAPI));
  };
  chromeAPI.permissions.onAdded.addListener(broadcastCurrentCapabilities);
  chromeAPI.permissions.onRemoved.addListener(broadcastCurrentCapabilities);
}
