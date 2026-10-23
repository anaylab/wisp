# Wisp Tabs (browser extension)

Wisp's way into your browser. With it, Wisp can organize and save your tabs, read the page you ask about
instead of squinting at a screenshot, point at things inside the page, watch a tab for you, work in its own
background tab, and fill a form from what it knows about you. Wisp decides everything; the extension only
does what Wisp asks, and only what you've allowed.

It works in Chrome and the other Chromium browsers: Arc, Brave, Edge, Vivaldi, Opera and Chrome
Beta/Dev/Canary.

## Install

1. Open `chrome://extensions` (Edge: `edge://extensions`, Brave: `brave://extensions`, Arc: Extensions →
   Manage extensions). Wisp → Settings → Agent → **Browser** has an **Open Extensions** button for Chrome.
2. Turn on **Developer mode**.
3. Click **Load unpacked** and choose this `chrome-extension` folder.
4. Open the extension's **Permissions…** page (from its toolbar popup, or **Allow…** in Wisp's Browser card)
   and allow what you want Wisp to do. See below.

The popup shows whether it's connected. It retries every 30 seconds while Wisp isn't running. After pulling
a new version, click the reload arrow on the extension's card.

**More than one browser?** Load it in each. Wisp keeps a connection per browser (and per profile), names
each one in its Browser card, and works in the browser you're using. While something Wisp started in one
browser is still going (a task tab, research, focus mode, a page watch), Wisp stays with that browser until
it's done, because a tab in one browser means nothing to another.

## Permissions

Out of the box the extension can only work with tabs: titles and addresses, never page content. Everything
else is optional, off until you allow it on the permissions page, and removable there or in the browser's own
extension settings. Wisp's Browser card updates either way.

| Capability | Browser permission | Lets Wisp |
|---|---|---|
| Tabs | always on | see, group, pin, mute, focus, save and close tabs |
| Read pages | `scripting` + all sites | read, point at and work in pages you ask about |
| Downloads | `downloads` | offer to file finished downloads |

The extension never runs in incognito windows (`"incognito": "not_allowed"`). It never reads the browser's
own pages, extension stores, or local files (unless you turn on **Allow access to file URLs**, and then
only to read).

## What you can say

Talk to Wisp (hold ⌃⌥) or type to it. With **Tabs** alone:

- "organize my tabs" · "group my tabs by site" · "close duplicate tabs" · "ungroup my tabs"
- "collapse my tab groups" · "mute my tabs"
- "save these tabs as thesis research" · "restore thesis research" · "what tab sessions do i have"
- "clean up old tabs" (saves them first) · "triage my tabs" (one card for duplicates, stale tabs and groups)
- "focus on my essay for 45 minutes" · "stop focus": off-task groups collapse, distractions go quiet, nothing
  is closed, and it all comes back when the time's up

With **Read pages**:

- "summarize this tab" · "what does this page say about pricing" · "add this page to my brain"
- "where's the sign-in button?": marked inside the page, following it as you scroll
- right-click a selection, image, link or page → **Ask Wisp…** or **Add to Wisp brain**; type `w` then a
  space and a question in the address bar; or press ⌘⇧Y
- "tell me when this tab says Deployed" · "tell me when the price drops below $80" · "check this page every
  10 minutes and tell me when it says in stock"
- on a Canvas assignment: "is this on my checklist?" · "add this to today" · "plan this"
- in a Google Meet or Zoom call with captions on: "what did I miss?" · "summarize the last 5 minutes"
- "research the best budget mechanical keyboards (and save it to my brain)": a cited report, every quote
  checked against its page
- "fill this form": from your contact card and Wisp's notes about you, on a card you can edit first
- web tasks ("search youtube for lofi", "open my github notifications") run in Wisp's own background tab,
  in a purple **Wisp** tab group

With **Downloads**: a finished download gets **File**, **Just brain** or **Ignore** in the notch.

With agent mode on, the model can also use the `chrome_*` tools (list, close, focus, pin, mute and move tabs;
read a tab; sessions; downloads; research; site helpers; `fill_form`).

## What stays private, and what always asks

- **Nothing leaves your Mac because of the extension.** It only talks to Wisp over `ws://127.0.0.1:47823`.
  Wisp accepts the connection only when its `Origin` is this extension's ID,
  `kpblnefdnmlodeagdnfodnbbdbkacnce` (pinned by the `key` in `manifest.json`), which a web page can't forge.
  If you've chosen a cloud model in Wisp, page text you ask about goes to it like any question, labelled as
  leaving the Mac.
- **Never read:** password, card, one-time-code and new-password fields, anything marked
  `data-wisp-ignore`, incognito tabs, and the protected pages above. Page text only ever reaches a model as
  quoted data, never as instructions.
- **Always asks, even with auto-approve on:** closing tabs, cleaning up or triaging tabs, restoring 10 or
  more tabs, filing a download, filling a form, closing research tabs you've used, and any click that sends,
  buys, posts or deletes. Forms are never submitted.
- **Never stored:** meeting captions stay in the meeting tab's memory for 30 minutes. A per-profile random id
  in the extension's local storage lets Wisp tell two profiles apart; it identifies nothing outside your Mac.
- The extension never moves, renames or deletes a file; Wisp does that on disk after you say so.

## How it's built

The extension exposes primitives and events, and Wisp decides what to do with them. The wire protocol, every
method and event, the permission model and the safety rules are in
[`docs/chrome-extension/contracts.md`](../docs/chrome-extension/contracts.md); what each phase added is in
[`docs/chrome-extension/README.md`](../docs/chrome-extension/README.md). If you change the `key`, update
`ChromeExtensionBridge.allowedExtensionID` to match.

```
manifest.json        MV3, version 2.0.0
background.js        wiring only
lib/bridge.js        the socket to Wisp, request dispatcher, events, reconnecting
lib/capabilities.js  what the user has allowed
lib/limits.js        payload caps (20,000 characters per text field, 500 items per list)
lib/page-access.js   which pages may be read or acted in
handlers/*.js        request handlers, one map per feature
events/*.js          chrome.* listeners that send events to Wisp
content/*.js         scripts injected into a page only when Wisp asks
options.html/.js     the permissions page
popup.html/.js       the toolbar popup
tests/               node tests against an in-memory fake of chrome.*
```

Run the tests (Node 22 or newer) from the repo root:

```bash
cd chrome-extension && npm install && cd ..
node --test chrome-extension/tests/
```

`npm install` brings in linkedom (a dev-only DOM for the page-reading tests; they skip without it).
`package.json` also tells Node to treat the `.js` files as ES modules, as the browser does.
