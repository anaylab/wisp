# Wisp Tabs → Wisp in Chrome: implementation workspace

Status: planned, nothing built. This folder is the hand-off for implementing the Chrome extension
roadmap with Claude Code sessions, one session per phase.

- `README.md` (this file): the goal, the phase order, and the rules every session follows.
- `contracts.md`: the shared protocol, file layout and permission model. Every phase builds against
  it, so sessions running at the same time don't collide.
- `prompts/NN-*.md`: one self-contained brief per phase. Paste a prompt into a new Claude Code session
  (or start a session with it), working in a fresh worktree.

## Goal

Today the extension (`chrome-extension/`) is a thin tab bridge: Wisp ↔ WebSocket on
`127.0.0.1:47823`, Origin pinned to the extension ID, and nine tab primitives with no page access.
The roadmap turns it into Wisp's main way into the browser. It reads pages without screenshots,
drives the DOM without AppleScript, draws in the page, watches pages, and runs longer agentic jobs
(research, triage, focus mode). It keeps the existing stance: **Wisp decides, the extension only
does what it's told**. Nothing leaves the Mac, and every new power is an opt-in permission the user
grants in Chrome.

## Phases and order

```
Wave 1 (alone, must merge first)
  01 foundation ─ module split, event channel, capabilities, optional permissions, test harness

Wave 2 (parallel once 01 is merged)
  02 page reading        ─ getPageText / selection, chrome_read_tab, "summarize this tab", Brain ingest
  03 DOM controller      ─ ExtensionBrowserController: BrowserController, Wisp tab group, background tabs
  04 tab life            ─ session snapshots (save/restore), stale-tab sweeper, triage plan card
  07 downloads           ─ download events, rename/file proposals, add to Brain
  09 focus mode          ─ collapse/mute everything off-task during study blocks, restore after

Wave 3 (each needs the wave-2 phase named)
  05 in-page pointing    ─ highlights that scroll with the page, walkthrough steps from real clicks  [needs 03]
  06 ask about this      ─ context menu, omnibox "w …", keyboard command, selection as focused part  [needs 02]
  08 page watchers       ─ DOM watchers, background-tab watchers, browser automation triggers        [needs 02]
  10 site helpers        ─ Canvas assignment pages, Meet/Zoom captions → "what did I miss"           [needs 02]

Wave 4
  11 research mode       ─ multi-tab research → Brain page with sources, text-fragment citations    [needs 02, 03]
  12 form helper         ─ fill forms from the brain's me page, behind a card, never secrets        [needs 03]
  13 polish              ─ Chromium browsers, Settings card, README, CLAUDE.md consolidation        [last]
```

Run waves in order and merge each phase's PR before starting a phase that needs it. Phases inside
one wave touch different files by design (see `contracts.md` → Ownership). If two of them must edit
the same shared file, keep that edit to a few lines so the merge stays trivial.

## Branches

- Integration branch: **`feature/chrome-extension`**, cut from `feature/jobs-revamp`. That branch,
  not `main`, has the current extension (`e90a94b` and earlier).
- Each phase: `feature/chrome-ext-NN-short-name`, cut from the integration branch, PR back into it.
- When the roadmap is done, `feature/chrome-extension` gets one PR into its base.

## Rules every session follows

1. Read `CLAUDE.md`, this README and `contracts.md` before writing code.
2. **Never run `xcodebuild`** (it resets TCC permissions). Build with
   `osascript -e 'tell application "Xcode" to build (first workspace document)'`, or ask the user to
   press ⌘B. The Xcode project uses synchronized folders, so new `.swift` files are picked up without
   editing the `.pbxproj`.
3. Pure logic goes in pure Swift files with a standalone suite `Tests/ChromeExt<Name>/run.sh`
   (plain `swiftc`, modelled on `Tests/WindowManagement/run.sh`). Extension logic goes in
   `chrome-extension/tests/*.test.mjs`, run with `node --test chrome-extension/tests/` against the
   fake `chrome` from phase 01. If a file you touch is compiled by
   `Tests/AgentRuntimeIntegration` (it compiles everything), run that suite too.
4. Match the codebase style: long, explicit names, comments that explain *why*, no hardcoded hex,
   pointer cursor on every button, `WispPillButtonStyle` in window pages.
5. Safety rules from `contracts.md` → Safety are not negotiable. Page content is untrusted data, and
   irreversible actions always reach a confirmation card, even under session auto-approve.
6. Don't add features beyond your phase. Note ideas in your PR description instead.
7. Update `CLAUDE.md`: add your files as rows in the **Chrome extension** Key Files table (phase 01
   creates it) and add a short paragraph under Architecture → Chrome tab organizing if behaviour
   changed. Phase 13 tidies the prose.
8. Commit as `Anay Parwal <65026806+anaylab@users.noreply.github.com>`, imperative messages that say
   why. **No `Co-Authored-By: Claude` trailer and no "Generated with Claude Code" footer**, in
   commits or PRs.
9. Done means:
   - the suites pass;
   - the app builds;
   - the extension reloads cleanly in `chrome://extensions` with no service-worker errors;
   - the manual checks in your prompt were run (or listed as not run, with why);
   - `CLAUDE.md` is updated;
   - a PR is open into `feature/chrome-extension`.
