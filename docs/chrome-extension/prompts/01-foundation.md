# Phase 01: Foundation (module split, event channel, capabilities, permissions, test harness)

You're implementing phase 01 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
They're binding. Branch `feature/chrome-ext-01-foundation` from `feature/chrome-extension`, and open
a PR back into it. Every other phase builds on this one, so get the contracts exactly right and keep
behaviour identical for today's features.

## Goal

Turn the single-file extension into the modular, event-capable, permission-aware base described in
`contracts.md` §1, §3 and §4. Give Wisp a typed way to receive events and know what the extension is
allowed to do.

## Extension (`chrome-extension/`)

1. Switch the service worker to an ES module (`"type": "module"`). Split `background.js` into
   `lib/bridge.js` (connection, keep-alive, reconnect alarm, `sendEvent`, `registerHandlers`, the
   request dispatcher), `lib/capabilities.js`, `lib/limits.js` and `handlers/tabs.js` (today's nine
   primitives moved verbatim). `background.js` only wires them together. Keep every existing comment
   that explains *why*.
2. Write the full manifest from contracts §3: required + optional permissions,
   `"incognito": "not_allowed"`, `omnibox` keyword `w`, the `ask-wisp-about-page` command,
   `options_page`. Bump the version to `1.1.0`. Leave `key` alone, since it pins the extension ID that
   `ChromeExtensionBridge.allowedExtensionID` checks.
3. Capabilities: `lib/capabilities.js` computes `["tabs", "pages.read"?, "downloads"?]` from
   `chrome.permissions.contains`. Send them in `hello`, and send them again as a `capabilities` message
   on `chrome.permissions.onAdded` and `onRemoved`. Add the `getCapabilities` method.
4. `options.html` / `options.js`: a calm, plain page that lists each optional capability, what it
   lets Wisp do, and that nothing leaves the Mac, with an Allow / Remove button that calls
   `chrome.permissions.request` / `remove`. Add `openPermissionsPage`, which opens it with
   `chrome.runtime.openOptionsPage()`.
5. Tab events (`events/tabs.js`): `tab.created`, `tab.updated` (only when `status`, `url`, `title`
   or `audible` changed, debounced ~250ms per tab), `tab.removed`, `tab.activated` and
   `window.focused`, using the payload fields of today's `getTabs` tab objects. Never include
   incognito tabs. Don't send anything while disconnected, and don't queue events (Wisp re-reads state
   on connect).
6. Popup: one extra line listing the granted capabilities and a "Permissions…" link to the options page.
7. Test harness: `tests/fake-chrome.mjs` (an in-memory fake of `tabs`, `tabGroups`, `windows`,
   `permissions`, `alarms`, `storage`, `runtime`, plus a `scripting` stub later phases fill in) and
   `tests/*.test.mjs` covering:
   - the request dispatcher (unknown method, thrown error, success);
   - each tab primitive's argument validation;
   - event debouncing;
   - capability computation;
   - `lib/limits.js` truncation.

   Run them with `node --test chrome-extension/tests/` (Node 26 is installed). `bridge.js` must be
   importable without opening a real socket, so inject `WebSocket`.

## Wisp (Swift)

1. `leanring-buddy/ChromeExtension/ChromeExtensionEvent.swift` and `ChromeExtensionCapability.swift`,
   exactly as contracts §1 sketches. Put a pure parser for incoming frames
   (`ChromeExtensionIncomingMessage` → hello / ping / capabilities / event / reply) in a pure file so it
   can be tested.
2. `ChromeExtensionBridge`: route events to `extensionEventPublisher`. Keep `grantedCapabilities` from
   `hello` / `capabilities`, and clear it on disconnect. Add a `timeoutSeconds:` overload of
   `sendRequest` (capped at 30s). Existing call sites keep compiling unchanged.
3. Settings → Agent → **Chrome Tabs** card (`AgentTab.swift`): add a capability row per capability
   (granted / not granted). Add a "Choose what Wisp can do in Chrome…" button calling
   `openPermissionsPage`, disabled while disconnected. Use `WispPillButtonStyle`. Keep copy short.
4. Add `Tests/ChromeExtFoundation/run.sh` + `main.swift` for the frame parser and payload decoding
   (malformed JSON, missing fields, unknown type, oversized payload).
5. `CLAUDE.md`: add a `### Chrome extension` Key Files table with the new files, and update the
   "Chrome tab organizing" architecture paragraph (module layout, events, capabilities, options page).
   Update `chrome-extension/README.md` (permissions page, test command).

## Manual checks

- Reload the unpacked extension: no service-worker errors, and the popup shows Connected + `tabs`.
- "organize my tabs", "close duplicate tabs" and "mute my tabs" still work exactly as before.
- Allow then Remove "read pages" on the options page. The Settings card row updates live, both ways.
- Quit Wisp. The extension retries every 30s and reconnects when Wisp relaunches.

## Out of scope

Any handler beyond `getCapabilities` / `openPermissionsPage`. Any content script. Any new agent tool.
