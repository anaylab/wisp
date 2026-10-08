# Siri-style actions for Wisp

The new Siri feels good for four reasons: it knows the user's data, it acts through apps'
own typed actions, its on-device model fills in structured requests reliably, and every
action is shown as a native card before it happens (to confirm) and after (the result,
with undo). This plan brings each of those into Wisp without changing its local-first
default. Nothing here sends data off the Mac.

## Where Wisp starts

| Siri capability | Wisp already has | Gap |
|---|---|---|
| Personal context | Brain (BM25 over ingested pages), Calendar/Reminders reads, Contacts | No live search of Mail, Notes or files without ingesting them first |
| App actions | Hand-built tools (Calendar, Reminders, Messages, windows), Shortcuts as tools | Each app is hand-written; nothing calls Wisp from Siri/Spotlight |
| Structured requests | `[TOOL:…]` text tags + hand-written fast-path parsers | The 3B local model is unreliable at tool calls, so each fast path needs its own parser |
| Native cards | Confirmation cards ("New Event", "New Message") with editable text fields | Raw ISO timestamps on the card; after an action, only a line of text — no result card, no undo |

## Rules every phase keeps

- **Dates are never computed by a language model.** A model may pick out *which words* say
  when ("friday at 1"); turning those words into a date is `NSDataDetector` plus a few
  deterministic rules. A model is wrong about "next Tuesday" often enough to matter.
- **Every write is shown first** on the existing confirmation card (session auto-approve
  is respected as it is today), and **every write Wisp makes can be undone** from the
  result card for as long as Wisp is running.
- **Undo only ever touches something Wisp itself created** in this session. It can't be
  pointed at any other event.
- **The parsers lean toward not matching.** Anything they aren't sure of goes on to the
  ordinary model turn, which still has the tools.
- **Apple's on-device model (Foundation Models) is optional.** It's used only when
  Apple Intelligence is on. Without it, Wisp behaves as before.

## Phase 1 — Calendar, end to end (this change)

The full Siri loop on one app, so the next apps reuse the same pieces.

1. **Fast path for "add lunch with Sam Friday at 1 at Tartine"**. `CalendarEventCommandParser`
   (pure, `Tests/CalendarEventCommand`) recognises scheduling phrasing ("schedule …",
   "add/put … on my calendar", "create an event/meeting/appointment …", "new event …").
   It declines recurring requests ("every Monday"), which go to the model.
   - **When**: `NSDataDetector` over the sentence, plus deterministic handling of a bare
     "at 6" (next upcoming 6 o'clock, afternoon for 1–6) and "in 2 hours". It knows
     whether a time of day was said ("October 12" becomes an all-day event, not noon),
     and reads durations ("for an hour", "for 30 minutes", "from 2 to 3:30").
   - **What and where**: the remaining words. Temporal words inside the detected span are
     removed, but other words in it are kept ("dinner tonight at 7" → "Dinner"). A
     trailing "at <place>" outside the time phrase becomes the location.
2. **Foundation Models fallback** (`CalendarEventDraftExtractor`). When the phrasing is
   clearly a scheduling request but the parser can't separate title, place and time,
   Apple's on-device model fills a `@Generable` struct `{title, location, whenPhrase}`.
   Its output is checked: `whenPhrase` must be words from the sentence and is resolved
   by the same deterministic date code, and the title must come from the user's own
   words. If the model is unavailable or the check fails, the request goes to the
   ordinary model turn.
3. **Apple-style confirmation**. The direct route asks through the same
   `create_calendar_event` consent as the agent tool. The "New Event" card shows
   "Fri, Oct 9 at 1:00 PM" instead of `2026-10-09T13:00`, and title and location stay
   editable.
4. **Result card with Undo**. Every event Wisp creates is recorded in
   `CreatedCalendarEventStore`, from both the direct route and the agent's tool.
   The notch then shows an "Event Added" card: the calendar's colour, title, day and
   time range, location, calendar name, **Open in Calendar** and **Undo**. Undo removes
   that event and nothing else. The agent path shows the card too, unless the model
   sent its own `[CARD:]`.

## Phase 2 — Reminders on the same pieces

- "Remind me to call the bank tomorrow at 9" as a fast path. The when-resolver from
  Phase 1 is shared, and the Foundation Models fallback reuses the same shape.
- A result card with Undo for `create_reminder`, with a list-colour dot and
  Open in Reminders.

## Phase 3 — Personal context (the "knows my data" part)

A `PersonalContextSource` protocol with on-device sources, each gated by its own macOS
permission and listed in Settings with a switch:

| Source | How | Gate |
|---|---|---|
| Calendar, Reminders | EventKit (exists) | Calendar/Reminders access |
| Contacts | `ContactsDirectory` (exists) | Contacts access |
| Files | `NSMetadataQuery` (the Spotlight index) | none beyond the query scope |
| Mail | AppleScript with parameters (as `MessagesAppSender` does) | Automation → Mail |
| Notes | AppleScript (as the brain's notes import does) | Automation → Notes |
| Messages history | `chat.db`, read-only | Full Disk Access, opt-in, off by default |

Each turn, a ranked handful of hits (titles + one line, ~600 chars total) is added to
the user message like `BrainPromptContext`, so the prefix cache is unaffected, and is
stripped from history. A `search_personal_context` tool handles follow-ups. Results
are framed as data, never instructions. Mail and messages are written by other people.

## Phase 4 — Wisp in Siri, Spotlight and Shortcuts

App Intents exposed *by* Wisp: **Ask Wisp** (text in, answer out), **Run Routine**
(an `AppEntity` over `RoutineStore`), **Run Buddy**, **Add to Brain** (file/URL).
macOS 26 shows these in Spotlight and the Shortcuts app, and lets Siri call them.

## Phase 5 — Other apps' actions through Shortcuts

macOS doesn't let a third-party app call another app's App Intents directly; Shortcuts
is the bridge, and `run_shortcut` already exists. When a request names an app action
Wisp has no tool for, suggest the shortcut to build, and match it by name next time.

## Out of scope for now

- A Foundation Models `ModelProvider` for whole text-only turns. It's worth measuring
  after Phase 1 shows how reliable its guided generation is in practice.
- Editing a card's time with a picker. Times stay read-only on the confirmation card
  (see `EditableConfirmationFields`); Undo plus asking again covers a wrong time.
