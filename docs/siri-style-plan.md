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

## Phase 1 — Calendar, end to end (done)

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

## Phase 2 — Reminders on the same pieces (done)

1. **Fast path** (`ReminderCommandParser`, `Tests/ReminderCommand`): "remind me to call
   the bank tomorrow at 9", "remind me at 6 to call mom", "remind me in 20 minutes to
   stretch", "create a reminder to renew my passport", "add milk to my shopping list".
   - The time is read by Phase 1's `CalendarEventWhenResolver`. A reminder may have no
     time (it's saved undated), but a time phrase the resolver can't read goes to
     extraction rather than being dropped.
   - A day with no time is due that day with no alarm; a time gets an alarm.
   - Declined: questions ("remind me what time…"), recurrence, "add this/it to…", and
     other apps' lists ("my reading list"). "To-do" means the default list. Any other
     named list is matched when saving; if Reminders has no such list, the reminder goes
     to the default list and the reply says so.
2. **On-device fallback**: Phase 1's Foundation Models call moved into a shared
   `OnDeviceModelExtraction.extract`, with a `ReminderDraftExtractor` (`{title,
   whenPhrase}`). A time the user said that the model's answer leaves out is rejected.
3. **"New Reminder" confirmation card** (Title, Due in words, List). Before this,
   `create_reminder` showed only the raw call. The editable title replaces the Title row.
4. **"Reminder Added" result card**: a ring in the list's colour, title, relative due
   text ("Tomorrow at 9:00 AM"), list, **Open Reminders** and **Undo**, for both the fast
   path and the agent tool (`CreatedReminderStore`). Reminders has no documented link to
   a single reminder, so the button opens the app.

## Phase 3 — Personal context (done)

"When is mom's flight?", "what's my dentist's address?", "find the invoice from Acme",
"what did Sam text me about dinner": answered from the user's own data, searched on this
Mac (`PersonalContext/`, `Tests/PersonalContext`).

| Source | How | Gate |
|---|---|---|
| Calendar, Reminders | EventKit | Calendar/Reminders access |
| Contacts | `ContactsDirectory` (address, birthday; "mom" through the Me card) | Contacts access |
| Files | `NSMetadataQuery`, scoped to Documents, Desktop, Downloads, iCloud Drive | Allow in Settings (see below) |
| Mail | AppleScript: inbox by subject/sender, opening of the top two | Automation → Mail, and Mail open |
| Notes | AppleScript: title or text | Automation → Notes, and Notes open |
| Messages | `chat.db` via SQLite, read-only | Full Disk Access, and switched on (off by default) |

What was learned building it:

- **Searching never asks for anything.** Each source reports whether it can be searched
  without a prompt and is skipped otherwise. Files needed an explicit setup: a Spotlight
  query scoped to Documents raised macOS's folder prompt mid-search, and there is no API
  to read that permission silently. So file search stays off until the user presses
  Allow in Settings, which touches each folder once.
- **Only personal questions search, and the slow sources only when named.** A question
  qualifies by "my"/"mom's"/topic/source words; "how do I center a div" doesn't. Fast
  sources get 0.8s, and Mail/Notes/Messages get 2.5s, only when the request mentions
  them. A source still answering at the deadline is left out of that turn.
- **The data goes before the question.** With the block after the question, the local
  3B model answered "I couldn't find a specific event called Columbus Day" while the
  entry was right there; placed first, with a header that leads with "answer from
  these", it answered correctly.
- **Visible and private.** History records "Searched your data on this Mac — N matches:
  Calendar". The block is stripped from conversation history. Cloud models get none of
  it unless the user turns on "Also with cloud models"; the `search_personal_context`
  tool refuses then too, and cloud buddies never get it.

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
