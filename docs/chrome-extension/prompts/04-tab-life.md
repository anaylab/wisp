# Phase 04: Tab life (session snapshots, stale-tab sweeper, triage)

You're implementing phase 04 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 01 is merged. Branch `feature/chrome-ext-04-tab-life` from `feature/chrome-extension`, and open
a PR back into it. This phase needs only the `tabs` capability.

## Goal

Three things, all deterministic where possible, built on `ChromeTabOrganizer` and its planners:

1. **Session snapshots.** "Save these tabs as thesis research" / "save this window" / "restore thesis
   research" / "what tab sessions do I have".
2. **Stale-tab sweeper.** "Clean up old tabs": find loose, unpinned, silent tabs not accessed for N
   days (default 14, from `lastAccessed`). Propose closing them and save them as a session first, so
   the close is fully recoverable.
3. **Triage plan.** "Triage my tabs": one plan card combining duplicates, stale tabs and groups-to-make.
   The user approves the batch once.

## Extension

`handlers/tab-life.js`: `openTabs({urls, windowMode: "current"|"new", groupTitle?, groupColor?})`.
It's batched, returns the new tab ids, opens tabs inactive except the first, and caps at 60 tabs.
Tests with the fake chrome.

## Wisp

1. `ChromeExtension/ChromeTabSessionStore.swift`: sessions in
   `~/Library/Application Support/Wisp/chrome-tab-sessions.json` (0600). A session is: name, created
   date, windows → groups (title, colour) → tabs (URL, title, pinned). No tab ids, see contracts §1.
   It's capped at 200 sessions and supports rename/delete (delete asks). The pure parts (codec, name
   matching for "restore thesis", which is case/punctuation-insensitive and unique, never fuzzy) go in
   a pure file.
2. Optionally, a saved session also writes a Brain `source` page through `BrainEditPlanner` with
   provenance `.userAuthored`, listing the tabs as links. This is controlled by a switch in the session
   card that defaults to off, and it only runs when the brain is on.
3. `ChromeExtension/ChromeStaleTabFinder.swift` (pure): stale-tab selection rules. Never pinned,
   audible, active, or grouped by the user; respects a minimum age; `chrome://` tabs only if the user
   says "including chrome pages".
4. `ChromeExtension/ChromeTabTriagePlanner.swift` (pure): combines `ChromeDuplicateTabFinder`, the
   stale finder and the grouping planner into one ordered plan with counts.
5. Plain commands: add cases to `ChromeTabCommandRouter` for save / restore / list sessions, clean up
   old tabs, and triage. Keep it biased toward not matching.
6. Agent tools (`.browser`): `chrome_save_tab_session`, `chrome_restore_tab_session`,
   `chrome_list_tab_sessions` (read) and `chrome_close_stale_tabs`.
7. Confirmation: closing tabs and the triage plan go through a `ToolConfirmationCardBuilder` card:
   "Close 23 tabs · saved as 'Cleanup Oct 21' first" with up to 8 rows of titles. Restoring 10 or more
   tabs also asks.
8. Window UI: a small **Tab sessions** list inside the Chrome Tabs settings card (one row, per
   contracts §5) with Restore / Rename / Delete.
9. Suites: `Tests/ChromeExtTabLife/` for the codec, name matching, stale rules, triage ordering and
   router phrases (positive and negative).

## Manual checks

- Save a window with 2 groups, close it, restore it: the groups come back with titles and colours.
- "Clean up old tabs" with nothing stale says so and shows no card.
- The triage card's numbers match what happens.

## Out of scope

Focus mode (09). Model-based topic grouping already exists, so reuse it and don't rebuild it.
