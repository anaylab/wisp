# Phase 09: Focus mode for study blocks

You're implementing phase 09 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 01 is merged. Branch `feature/chrome-ext-09-focus-mode` from `feature/chrome-extension`, and
open a PR back into it. This needs only the `tabs` capability.

## Goal

"Focus on my essay for 45 minutes" (or a study block from `StudyBlockPlanner` starting): collapse
every tab group that isn't on-task, group the loose on-task tabs as "Focus", mute audible off-task
tabs, and optionally move distracting-site tabs into a minimised "Later" window. When the block ends,
or on "stop focus", put everything back exactly. Nothing is closed, ever.

## Extension

`handlers/focus-mode.js`:
- `applyFocusLayout({keepTabIds, keepGroupIds, distractingTabIds, moveDistractingToLaterWindow})`
  returns a restore token. The prior state (group collapsed flags, muted flags, window and index of
  moved tabs) is kept in `chrome.storage.session` under the token.
- `restoreFocusLayout({token})` restores it, tolerating tabs that were closed or moved meanwhile.

Tests: apply then restore round trips with the fake chrome, including a tab closed mid-focus.

## Wisp

1. `ChromeExtension/ChromeFocusPlanner.swift` (pure): given the snapshot (`ChromeTabsSnapshot`), the
   focus topic words, an allow-list of hosts, and a distraction list (default: youtube, reddit, x,
   instagram, tiktok, netflix; editable), decide keep / collapse / mute / move. On-task means the
   host is allow-listed, or the title/URL shares a content word with the topic. When unsure, keep the
   tab rather than hide it.
2. `ChromeExtension/ChromeFocusSession.swift`: start/stop and a timer via `WispTimerStore`, so the
   notch shows the countdown card. It restores at the end and flashes success. Only one session runs
   at a time. A session interrupted by quitting Wisp is restored on next launch (persist the token +
   end date).
3. Triggers:
   - the phrase via `ChromeTabCommandRouter` ("focus on X for N minutes", "stop focus");
   - an `AutomationAction.startChromeFocus(topic, minutes)`, added to the action set;
   - the "Focus block" template gains an optional "also focus Chrome" switch;
   - approved study blocks (`JobsEngine`) offer it as a chip.
4. Agent tool: `chrome_focus_mode` (start/stop), `.writing(.localMachine)`.
5. Suites: `Tests/ChromeExtFocusMode/` for the planner decisions and the phrase parsing.

## Manual checks

Start 1-minute focus with three groups and a playing YouTube tab. Everything comes back as it was.
Quit Wisp mid-focus, relaunch, and it restores.
