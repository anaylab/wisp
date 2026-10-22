# Phase 06: "Ask Wisp about this" (context menu, omnibox, keyboard command)

You're implementing phase 06 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 02 (page reading) is merged. Branch `feature/chrome-ext-06-ask-about-this` from
`feature/chrome-extension`, and open a PR back into it.

## Goal

Reach Wisp from inside Chrome without the notch: right-click a selection, image, link or page →
**Ask Wisp…**; type `w how do I …` in the address bar; or press ⌘⇧Y. The page part arrives in Wisp as
exact data, the DOM equivalent of Ask About a Part, so it's never approximated by OCR.

## Extension

- `events/ask-about-this.js`:
  - Context menu items (created on install). "Ask Wisp about “%s”" for a selection, "Ask Wisp about
    this image", "Ask Wisp about this link", "Ask Wisp about this page", plus "Add to Wisp brain" for
    a page, link or selection. The brain item sends the same event with `intent: "addToBrain"`.
  - Omnibox: `onInputEntered` → `user.omniboxQuestion {text, tabId}`.
  - Command `ask-wisp-about-page` → `user.askAboutPage`.
  - Events carry ids and URLs only: `tabId`, `pageUrl`, `srcUrl` / `linkUrl` / `selectionText` from
    Chrome's menu info, capped by `lib/limits.js`. Wisp fetches the rest.
- If Wisp isn't connected, show a one-time Chrome notification-free hint in the popup badge (badge
  text "!" for 5s). There's no `notifications` permission.

## Wisp

1. `ChromeExtension/ChromeAskAboutThisRouter.swift`: subscribes to the `user.*` events.
   - **Selection**: read context with `getSelection` and open the text composer with an "About:
     selected text ✕" chip. This reuses the composer's focused-region chip pattern, with a new case for
     page text rather than a screen region. The turn carries the selection fenced as page data and skips
     the screenshot unless the question needs the look.
   - **Image**: the composer gets an image chip. On send, Wisp downloads `srcUrl` itself (https only,
     ≤10 MB, no cookies, same rules as `CanvasFeedStore`) and attaches it as an image. If that fails,
     it falls back to a screenshot close-up of the element's rect, through the phase 03 screen-point
     helper if it's available, otherwise the screenshot path.
   - **Link**: "about this link" reads the link's text + URL. "What's behind it" fetches nothing. The
     model can call `chrome_read_tab` after opening it with `browser_task` if the user asks.
   - **Page**: same as a screen-referring turn on that tab with phase 02's text path.
   - **Omnibox**: runs as a typed question (`askTypedQuestion`) with the tab as context. The answer
     shows in the notch.
   - **addToBrain**: `BrainIngestQueue` with page text / selection / link URL.
2. Every entry point closes nothing and steals no focus from Chrome except the composer panel, which
   must be keyable.
3. Suites: `Tests/ChromeExtAskAboutThis/` for event-payload decoding, the image download rules, and
   which context each intent builds.

## Manual checks

All five entry points, with Wisp running and not running. Plus a selection inside a Google Doc:
expect a graceful "couldn't read that selection" if Docs' canvas hides it.
