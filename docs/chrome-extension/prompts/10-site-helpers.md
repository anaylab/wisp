# Phase 10: Site helpers (Canvas, Meet/Zoom captions)

You're implementing phase 10 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 02 is merged. Branch `feature/chrome-ext-10-site-helpers` from `feature/chrome-extension`, and
open a PR back into it.

## Goal

Two narrow, high-value integrations, each a small content script with a fixed host match:

1. **Canvas.** On an assignment page (`*.instructure.com/courses/*/assignments/*` and the user's
   Canvas host from `CanvasFeedStore`'s saved feed host, never the URL itself), read the title, due
   date, points, rubric summary and description. Wisp can then:
   - say whether it's already on today's checklist / the Wisp calendar (`JobsEngine` data, keyed by
     Canvas UID where the page exposes it, else by title + due date);
   - "add to my checklist", through the existing builder path;
   - "plan this": `StudyBlockPlanner` proposals for just this item, behind the existing approval card.
2. **Meeting captions.** On Google Meet (and Zoom web client if feasible), when the user has turned on
   captions, the extension reads caption text from the DOM into a rolling buffer, kept in the page
   only and capped at 30 minutes. "What did I miss" / "summarize the last 5 minutes" fetches the buffer
   through `getMeetingCaptions({tabId, lastMinutes})`. No audio is captured, nothing is stored on disk,
   and the buffer dies with the tab. Wisp's quiet mode already detects the call. Leave it unchanged.

## Extension

- `content/canvas-assignment.js` and `content/meeting-captions.js`, injected by host match
  (`chrome.scripting.registerContentScripts` once `pages.read` is granted, so no manifest
  `content_scripts` is needed).
- `handlers/site-helpers.js`: `getCanvasAssignmentDetails`, `getMeetingCaptions`. Events
  `site.canvasAssignmentOpened {tabId, title, dueAt}` and `site.meetingCaptionsAvailable {tabId}`.
- Caption selectors are brittle. Isolate them in one table, fail soft ("couldn't find captions —
  turn them on with C"), and test against saved fixture HTML.

## Wisp

1. `ChromeExtension/CanvasPageHelper.swift`: matching (pure, tested) and the three actions. When a
   Canvas assignment opens and it's not on the checklist, the notch may show a one-line chip "Add to
   today?". That's gated by a switch, default on, and shown at most once per assignment.
2. `ChromeExtension/MeetingCaptionsHelper.swift`: a phrase route ("what did I miss", "summarize the
   meeting so far", only while a Meet tab has captions) → one text-only model turn with the captions
   fenced as data. The answer goes to the notch, spoken only in voice mode.
3. Agent tools: `chrome_canvas_assignment` (read) and `chrome_meeting_captions` (read).
4. Suites: `Tests/ChromeExtSiteHelpers/` for Canvas matching/dedup against checklist items, and the
   caption buffer windowing logic, if it's mirrored in Swift.

## Manual checks

A real Canvas assignment page (the user has one). A Meet test call with captions on: "what did I miss"
after 2 minutes.
