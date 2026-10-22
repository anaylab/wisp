# Phase 08: Page watchers and browser automation triggers

You're implementing phase 08 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phases 01 and 02 are merged. Branch `feature/chrome-ext-08-page-watchers` from
`feature/chrome-extension`, and open a PR back into it.

## Goal

1. **DOM watchers.** "Tell me when this tab says Deployed" / "when the price drops below $80" / "when
   this page changes" are watched with a `MutationObserver` in the tab, even when it's in the
   background. This beats OCR polling: the existing `ScreenWatcherStore` only sees what's on screen.
2. **Reloading watchers.** For pages that don't update by themselves ("tell me when tickets are back
   in stock"), reload the tab on an interval (≥5 min, from `alarms`) in a background tab and re-check.
3. **Browser automation triggers.** New `AutomationEvent` cases: a page watch matched, a tab opened on
   a site, and time on a site over N minutes.

## Extension

- `content/page-watch.js`: conditions mirror `ScreenWatchCondition`:
  - `textAppears` (whole-word, case/accent-insensitive, counting matches like the screen watcher so
    existing text doesn't fire);
  - `textDisappears`;
  - `pageSettlesAfterChange`;
  - `numberCrosses {selector?, nearText, below|above}` (finds the first number near the given text,
    so "$79.99" parses).

  Throttled to at most one evaluation per second.
- `handlers/page-watchers.js`: `startPageWatch({tabId, condition, reloadEveryMinutes?})` → watchId,
  `stopPageWatch`, `listPageWatches`. Watches live in `chrome.storage.session` and are re-injected on
  `nav.completed` and service-worker restart. Max 5, 24h timeout. Events `watch.matched {watchId,
  matchedText}` and `watch.ended {watchId, reason}`.
- Tests: each condition against fixture DOM changes, and the number parser (currencies, thousands
  separators).

## Wisp

1. Routing: `ScreenWatchRequestParser` already recognises "tell me when …". When the frontmost app is
   Chrome with `pages.read`, `ChromePageWatchRouter` (pure decision) starts a page watch instead of a
   screen watch and says "watching this tab". Add the "below/above $N" phrasing to the parser
   conservatively.
2. `ChromeExtension/ChromePageWatchStore.swift`: mirrors `ScreenWatcherStore`'s endings (notification,
   `flashIsland(.success)`, notch line when idle, spoken in voice mode, quiet mode respected). The notch
   live section lists page watches beside screen watches, with Stop.
3. Agent tools: extend `watch_screen` with an optional `in_chrome_tab` argument, or add
   `watch_chrome_tab`. Pick one and justify it in the PR. `stop_screen_watch` stops both kinds.
4. Automations: add `AutomationEvent.chromePageWatchMatched(watchDescription)`, `.chromeTabOpened(host)`
   and `.chromeTimeOnSite(host, minutes)`, with schedule-free triggers in `AutomationEngine`. Keep the
   `AutomationDraftParser` phrases deterministic ("when I open youtube", "if I'm on reddit for 30
   minutes"). Unattended runs keep `AutomationToolPolicy`.
5. Suites: `Tests/ChromeExtPageWatchers/` for the router decision, new parser phrases, and the time-on-site
   accumulator (pure: tab activations + window focus → minutes per host, paused when Chrome isn't
   frontmost or the Mac is idle). Extend `Tests/AutomationDraft` and `Tests/AutomationEngine`.

## Manual checks

- Watch a GitHub Actions run page for "completed" with the tab in the background.
- A price watch on a product page fires once.
- "If I'm on youtube for 1 minute, remind me to study" drafts the automation correctly and fires.
