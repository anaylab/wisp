# Wisp Tabs → Wisp in Chrome: implementation workspace

Status: **all 13 phases built** and merged into `feature/chrome-extension` (extension 2.0.0). Every suite
passes; none of it has been tried by hand in a real browser yet. That's `manual-checklist.md`.

- `README.md` (this file): the goal, what shipped, what didn't, the phase order, and the rules every
  session followed.
- `contracts.md`: the shared protocol, file layout, permission model and safety rules. Binding for any
  further work.
- `manual-checklist.md`: every hands-on check the phase briefs asked for, in one sitting's order.
- `prompts/NN-*.md`: the brief each phase was built from.

The user-facing description (install, permissions, everything you can say, privacy) is
[`chrome-extension/README.md`](../../chrome-extension/README.md); the architecture is in `CLAUDE.md` →
Architecture → Browser extension.

## What shipped

| Phase | PR | What it does |
|---|---|---|
| 01 foundation | anaylab/wisp#42 | ES-module service worker, request dispatcher, events, capabilities, optional permissions, options page, node test harness |
| 02 page reading | anaylab/wisp#43 | `getPageText` / selection / outline; page text instead of a screenshot for content questions; `chrome_read_tab`; "add this page to my brain" |
| 03 DOM controller | anaylab/wisp#47 | `ExtensionBrowserController`: browser tasks in a background tab in the Wisp group, cross-origin frames, one decoder for both controllers |
| 04 tab life | anaylab/wisp#45 | Tab sessions (save/restore), "clean up old tabs", "triage my tabs" |
| 05 in-page pointing | anaylab/wisp#48 | Marks drawn inside the page that follow the element; walkthrough steps finished by real clicks |
| 06 ask about this | anaylab/wisp#49 | Context menu, omnibox `w`, ⌘⇧Y; the selected part rides the next questions |
| 07 downloads | anaylab/wisp#46 | Download concierge: file / brain / ignore, rules, undo; the extension never touches files |
| 08 page watchers | anaylab/wisp#50 | In-page watchers (text, numbers, settling), reloading watches, browser automation triggers |
| 09 focus mode | anaylab/wisp#44 | Collapse/mute/group off-task tabs for a while, restore after; study-block auto-start |
| 10 site helpers | anaylab/wisp#51 | Canvas assignment pages ↔ checklist; Meet/Zoom captions → "what did I miss" |
| 11 research mode | anaylab/wisp#53 | Multi-tab research with verified quotes, text-fragment citations, Save to Brain |
| 12 form helper | anaylab/wisp#52 | Fill forms from the Me card and me page, behind an editable card, never secrets, never submits |
| 13 polish | (this phase) | Other Chromium browsers (a connection per browser profile, the active browser, route holds), one Browser settings card, a §6 audit with fixes, docs, 2.0.0 |

## What didn't ship, and known gaps

- **Nothing has been run by hand** in a real browser with the real Wisp. `manual-checklist.md` lists it all.
- **Other browsers** are tested by rule and by one live check (finding the app behind a socket), not with Arc,
  Brave, Vivaldi, Opera or Chrome Canary connected, nor two browsers at once.
- **Two profiles of one browser** stay connected side by side, but Wisp can't tell which profile's window is in
  front, so it keeps the one it was using (or the first).
- **Only the active browser's events reach Wisp.** A download finished in a browser you aren't using isn't
  offered; a page watch keeps its browser active until it ends, so its match isn't lost.
- **AppleScript paths stay Chrome/Safari only**: plain tab commands ("new tab", "go back") and the fallback
  controller don't drive Edge, Arc or Brave.
- **The close-tabs card shows tab ids**, not titles, for the agent's `chrome_close_tabs` (it now always asks;
  a titled card would need the input prepared before the card, as `chrome_close_stale_tabs` does).
- The extension is still called **Wisp Tabs**, and its popup and options page still say "Chrome".
- Ideas noted by phases but out of scope: per-site permissions instead of all sites, the browser's own search
  engine for research (needs the `search` permission), titled cards for every tab-closing tool.

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

## Rules every session followed

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
