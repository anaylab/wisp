# Wisp Tabs (Chrome extension)

Lets Wisp organize your Chrome tabs. Say (or type) to Wisp:

- **"organize my tabs"**: groups loose tabs by topic (one call to your selected model; falls back to grouping by site)
- **"group my tabs by site"**: one group per website, with no model call
- **"close duplicate tabs"**: keeps one copy of each page (never closes pinned tabs or tabs playing sound)
- **"ungroup my tabs"**
- **"collapse my tab groups"** / **"expand my tab groups"**
- **"mute my tabs"** / **"unmute my tabs"**: mutes only tabs making sound

With agent mode on, the model also gets `chrome_list_tabs`, `chrome_close_tabs` ("close all my youtube tabs"), `chrome_focus_tab` ("go to my gmail tab"), `chrome_pin_tabs`, `chrome_mute_tabs` and `chrome_move_tabs_to_new_window`.

Pinned tabs and groups you made yourself are never touched. Tabs never move between windows.

## Install

1. Open `chrome://extensions` (or the **Open Extensions** button in Wisp → Settings → Agent → Chrome Tabs).
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and choose this `chrome-extension` folder.

The toolbar popup shows whether it's connected and what it's allowed to do. It retries every 30 seconds while Wisp isn't running.

After pulling a new version, click the reload arrow on the extension's card in `chrome://extensions`.

## Permissions

Out of the box the extension can only work with tabs (titles and addresses, never page content). Anything
more is optional and off until you allow it on the extension's **permissions page**: open it from the
popup's **Permissions…** link, from **Wisp → Settings → Agent → Chrome Tabs → Choose what Wisp can do in
Chrome…**, or from **Extension options** in `chrome://extensions`.

| Capability | Chrome permission | Lets Wisp |
|---|---|---|
| `tabs` | always on | see, group, pin, mute, focus and close tabs |
| `pages.read` | `scripting` + all sites | read a page's text when you ask about it |
| `downloads` | `downloads` | notice finished downloads |

Remove any of them on the same page, or in Chrome's own extension settings. Wisp's Settings card updates
either way. The extension never runs in incognito windows (`"incognito": "not_allowed"`).

## How it talks to Wisp

The extension opens a WebSocket to `ws://127.0.0.1:47823`, which Wisp listens on (loopback only).
Wisp accepts the connection only when the handshake's `Origin` is this extension's ID,
`kpblnefdnmlodeagdnfodnbbdbkacnce`, which is pinned by the `key` in `manifest.json`. A web page can't
forge `Origin`, so sites you visit can't connect and read your tabs. Nothing leaves your Mac.

The extension only exposes primitives (`getTabs`, `groupTabs`, `ungroupTabs`, `closeTabs`, `focusTab`, `pinTabs`, `muteTabs`, `setGroupsCollapsed`, `moveTabsToNewWindow`, plus `getCapabilities` and `openPermissionsPage`). Wisp decides
what to do with them (`ChromeTabOrganizer.swift`). If you change the `key`, update
`ChromeExtensionBridge.allowedExtensionID` to match.

It also sends Wisp tab events (`tab.created`, `tab.updated`, `tab.removed`, `tab.activated`,
`window.focused`) and its capability list whenever a permission changes. The wire protocol, file layout and
permission model are in [`docs/chrome-extension/contracts.md`](../docs/chrome-extension/contracts.md).

## Layout and tests

```
background.js        wiring only
lib/bridge.js        the socket to Wisp, request dispatcher, events, reconnecting
lib/capabilities.js  what the user has allowed
lib/limits.js        payload caps (20,000 characters per text field, 500 items per list)
handlers/*.js        request handlers, one map per feature
events/*.js          chrome.* listeners that send events to Wisp
options.html/.js     the permissions page
popup.html/.js       the toolbar popup
tests/               node tests against an in-memory fake of chrome.*
```

Run the tests (Node 22 or newer) from the repo root:

```bash
node --test chrome-extension/tests/
```

`package.json` is only there so Node treats the `.js` files as ES modules, as Chrome does.
