# Study mode plan

A Pomodoro-style focus timer that holds distractions back while a focus block runs.

## What the research says

- The Pomodoro Technique (Cirillo, late 1980s): work in timed blocks, short break between them, a longer
  break (15–30 min) after four. The 25/5 ratio is a convention, not an evidence-backed optimum: a 2025
  study of 94 students found classic 25/5 did not beat self-chosen breaks. So Study mode ships
  presets (Classic 25/5, Deep 50/10, Sprint 15/3, Marathon 90/20) and lets the user drag any length.
- Competing apps and what they teach us:
  - **Forest**: commitment is the hook. Giving up has a cost, and blocking lasts the whole session.
    We copy this with a *hold to give up* button (no accidental quitting, no lock-in either).
  - **Flow**: minimal, calm timer; app/site blocking is a toggle; session history shows patterns.
  - **Session / Focus To-Do / Pomofocus**: a goal for the block ("what are you working on?"),
    rounds shown as pips, stats by day.
- Take-aways for Wisp: one calm screen, a big ring that is itself the control, a stated goal,
  visible round progress, blocking that is automatic and explained, and breaks that feel like breaks.

## What it does

1. **Setup**: drag the ring to choose focus minutes (5–120, snaps to 5) or tap a preset; pick rounds;
   write what you're studying; choose what to block (categories + any running app + any site).
2. **Run**: focus → short break → … → long break after the 4th round → done. Ring fills, round pips fill,
   the screen tints sage for focus and lavender for breaks, breathing circle during breaks.
   Pause/resume, skip phase, hold-to-give-up. Auto-start of the next phase is a switch.
3. **Blocking (focus phases only, lifted on breaks)**:
   - *Apps*: when a blocked app comes to the front it is hidden at once and the count goes up.
   - *Websites*: while a browser (Chrome, Safari, Brave, Edge, Arc) is frontmost, the active tab's URL is
     checked every 2 s; a blocked host is replaced with a calm "Blocked while you focus" page
     (Back returns). Needs Automation permission for that browser; the page says so if missing.
   - Wisp itself, Finder and System Settings are never blocked.
   - No hosts-file edit and no admin rights: everything is reversible and ends with the session.
4. **Feedback**: sound cue + notification + island flash when a phase ends; menu bar item shows time left.
5. **History**: finished sessions logged locally (`study-log.json`, 0600, no content beyond the goal text);
   today's minutes, 7-day bars, streak.

## Code layout

| File | Role |
|---|---|
| `Study/StudyModel.swift` | Pure: `StudyPlan`, presets, `StudySession` state machine (injected dates, no timers), events |
| `Study/StudyBlocklist.swift` | Pure: categories, domain normalising and host matching, app rules |
| `Study/StudyStats.swift` | Pure: log entry, today/7-day/streak |
| `Study/StudyDistractionBlocker.swift` | App-activation observer + browser tab check |
| `Study/StudySessionController.swift` | `@MainActor` owner: tick, persistence, sounds, notifications |
| `WispWindow/Study/StudyPage.swift` + `StudyDial.swift` | Setup, running and finished views; draggable dial |
| `Tests/StudyMode` | swiftc suite for the pure files |

## Not in this pass

Voice command ("start a 25 minute study session"), Do Not Disturb, system-wide
website blocking via hosts file or a network extension.

## Notch

Built after the window: the island stays up during a session (glyph left, ring + countdown right), the hover card has
Pause / Skip / hold-to-end, and with nothing running it is a one-tap preset launcher.
