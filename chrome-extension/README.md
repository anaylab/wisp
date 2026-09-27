# Wisp Tabs (Chrome extension)

Lets Wisp organize your Chrome tabs. Say (or type) to Wisp:

- **"organize my tabs"**: groups loose tabs by topic (one call to your selected model; falls back to grouping by site)
- **"group my tabs by site"**: one group per website, with no model call
- **"close duplicate tabs"**: keeps one copy of each page (never closes pinned tabs or tabs playing sound)
- **"ungroup my tabs"**

With agent mode on, the model also gets `chrome_list_tabs` and `chrome_close_tabs` ("close all my youtube tabs").

Pinned tabs and groups you made yourself are never touched. Tabs never move between windows.

## Install

1. Open `chrome://extensions` (or the **Open Extensions** button in Wisp → Settings → Agent → Chrome Tabs).
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and choose this `chrome-extension` folder.

The toolbar popup shows whether it's connected. It retries every 30 seconds while Wisp isn't running.

## How it talks to Wisp

The extension opens a WebSocket to `ws://127.0.0.1:47823`, which Wisp listens on (loopback only).
Wisp accepts the connection only when the handshake's `Origin` is this extension's ID,
`kpblnefdnmlodeagdnfodnbbdbkacnce`, which is pinned by the `key` in `manifest.json`. A web page can't
forge `Origin`, so sites you visit can't connect and read your tabs. Nothing leaves your Mac.

The extension only exposes primitives (`getTabs`, `groupTabs`, `ungroupTabs`, `closeTabs`). Wisp decides
what to do with them (`ChromeTabOrganizer.swift`). If you change the `key`, update
`ChromeExtensionBridge.allowedExtensionID` to match.
