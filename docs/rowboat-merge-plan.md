# Wisp × Rowboat — merge plan

Bringing the Rowboat desktop app's features (github.com/rowboatlabs/rowboat, Apache-2.0, checked at
`505de5a`, 2026-11-13) into Wisp. Decided on 2026-11-12:

- **Wisp stays native Swift/macOS.** Rowboat is ~347k lines of TypeScript (Electron app `apps/x`, the
  Harbor spaces server `apps/harbor` on Postgres, an Expo phone app). None of it runs inside Wisp, so we
  translate *behaviour and prompts* into Swift, not files. The notch, overlay, on-device Parakeet/Kokoro,
  Accessibility pointing and local-first defaults stay as they are.
- **The name stays Wisp.** The change is in positioning and surfaces: from "notch companion" to "an AI
  coworker on your Mac that remembers your work", with Inbox, Meetings, Code and Apps beside Buddies and
  the Brain.
- **Features to bring in:** email client with auto-drafts, meeting note taker, Spaces with people, code
  mode, mini apps.

What Wisp already has, so it is *not* ported: the Obsidian-style knowledge graph (Brain), background
agents on schedules/events (Automations), agent group chats with @mention handoff (buddy groups),
MCP + Composio, a Cowork browser agent.

## Rules that carry over from Wisp (and override Rowboat)

| Rowboat does | Wisp does instead |
|---|---|
| PostHog analytics in renderer, main and server (`apps/x/ANALYTICS.md`), installation id, `identify` with email | **Nothing.** No analytics code, no dependency. |
| Rowboat account sign-in, billing, hosted default models | Local Ollama stays the default; cloud models stay bring-your-own-key or subscription CLI, labelled. |
| Gmail/Outlook over Google/Microsoft OAuth (needs a Google Cloud client, `google-setup.md`) | Mail.app first (local, every account the user already added); Gmail via Composio only as an opt-in. |
| Deepgram / ElevenLabs keys for voice | Parakeet + Kokoro on device. |
| Agent-drafted messages posted for you | Nothing leaves the Mac or reaches another person without the user's click on something they can read and edit. |

**License.** Wisp is AGPL-3.0; Apache-2.0 code may be adapted into it. Any file that translates Rowboat
logic or prompt text gets a line in `NOTICE` (as Sentient OS has), and the Apache-2.0 text is kept beside
it. Nothing is copied from Rowboat's branding, screenshots or names.

## Order

1. **Inbox** (email + drafts) — daily value, fully local, builds on `Email/`.
2. **Meetings** — fully local, builds on `QuietModeMonitor` + Parakeet.
3. **Code mode** — builds on `ClaudeCodeWorker` and the subscription CLIs.
4. **Mini apps** — builds on Automations + the tool registry.
5. **Spaces** — last, because it is the one that sends conversations to a server and Harbor's
   protocol is "v0, deliberately unstable" (`apps/harbor/CONTRACT.md`).

Each phase is its own branch (`feature/inbox`, `feature/meetings`, …) and PR, with a pure core and a
`Tests/<Name>/run.sh` suite like the rest of the app.

---

## Phase 1 — Inbox (email triage + drafts) — built on `feature/email-inbox`

Rowboat reference: `packages/core/src/knowledge/sync_gmail.ts` (2168 lines), `classify_thread.ts`,
`email_labels.ts`, `email_importance_feedback.ts`, `email_instructions.ts`, style guide at
`knowledge/Agent Notes/style/email.md`.

- **Source.** `MailLibraryReader`: AppleScript over Mail.app (parameterised handler, like `MailAppSender`),
  reading the last 14 days of inbox threads — sender, recipients, subject, date, message id, a body
  excerpt (≤4 KB), whether the user has replied. Off-main, capped (500 threads), polled every 10 minutes
  while Wisp runs. Snapshot `inbox-snapshot.json` (0600, via `WispDemoMode.dataHome`). Needs Automation → Mail,
  which drafts already ask for.
- **Triage, deterministic first.** `InboxImportancePolicy` (pure): a person in Contacts, someone the user
  has written to, the user on To (not Cc/list), a question to them, a meeting/deadline word → important;
  bulk signals (List-Unsubscribe, noreply, newsletters) → everything else. Only unsure threads go to the
  model, one text-only call per thread on the local model at background priority (`ModelAccessGate`),
  with Rowboat's label set and the user's rules. Thread text is fenced as data.
- **It learns.** Moving a thread between Important and Everything else records a correction for that
  sender, which decides their mail from then on with no model call; the last 8 corrections and the
  user's own "what matters to you" text go in the triage prompt as examples. (Built this way instead of
  Rowboat's distilled rules page: deterministic, and works with the 3B model.)
- **Drafts.** For an important thread that asks something of the user, a draft is written ahead of time
  (`EmailDraftWriter`, the existing composer): context from Brain recall on the sender and subject, the
  next 7 days of calendar, and the user's "how you write" notes (Inbox settings). Drafts are stored, never sent;
  opening one shows the existing composer, and **Send (⌘↩) stays the only way anything leaves**.
- **Surface.** New window section **Inbox**: Important / Everything else, thread reader, "Draft ready"
  chip, Reply / Open in Mail. Today's "Needs you" gains "3 important emails, 2 drafts ready". The notch
  morning banner may name one.
- **Brain.** *(not built yet)* New senders feed `people/` pages with `.external` trust (append only, never `me`).
- **Inbox settings sheet:** on/off (off by default, turned on from the page), draft ahead on/off, local
  model or Wisp's chat model, what matters, how you write, forget stored mail. *(Choosing accounts: not built yet.)*
- **Tests.** `Tests/Inbox`: importance policy, correction → rules plan, AppleScript reply parsing, draft
  eligibility.

## Phase 2 — Meetings (note taker)

Rowboat reference: `packages/core/src/meetings/detector.ts`, `knowledge/summarize_meeting.ts`,
`meeting_prep*.ts`, and `apps/x/GRANOLA_PARITY.md` (the behaviour we copy: detect, offer, never
auto-record).

- **Detect.** `QuietModeMonitor` already sees which process is capturing the mic; `UpcomingEventMonitor`
  already sees the next calendar event. `MeetingDetector` (pure rules + that input): a known meeting app
  (Zoom, Teams, Meet in a browser, FaceTime, Slack huddle, Webex) capturing the mic, or a calendar event
  with 2+ attendees starting within a minute → the notch offers **"Meeting detected — Take notes"**.
  An ad-hoc call within 15 minutes of an event takes that event's name. Never records on its own.
- **Capture.** Mic through `AVAudioEngine` (labelled *You*) and the other side through a Core Audio
  process tap on the meeting app (`AudioHardwareCreateProcessTap`, labelled *Them*). Needs
  `NSAudioCaptureUsageDescription`. The island shows a red recording dot while it runs; one click stops.
- **Transcribe.** Parakeet, in ~30 s windows per channel (it is a batch model), into a live transcript
  in a Meetings page. Audio is kept only until transcribed, then deleted (a setting can keep it).
- **Notes.** The user types their own notes beside the transcript (Granola's model). On stop, one call
  turns notes + transcript into a summary — decisions, action items with owners, follow-ups — merged
  into the user's notes, not replacing them. Local model by default; a long meeting chunks first.
- **Brain + actions.** The meeting becomes a `meetings/` page (new `BrainPageKind`) linked to attendees'
  `people/` pages; action items for the user can go to Reminders on one approval card.
- **Prep.** The existing "Meeting prep" automation template gets Rowboat's brief shape (who, last time
  you spoke, open threads from Inbox, what they'll likely ask).
- **Consent.** First use explains that recording laws vary and others may need to be told. No bot
  joins the call.
- **Tests.** `Tests/Meetings`: detection rules, event merge window, transcript windowing, summary merge.

## Phase 3 — Code mode

Rowboat reference: `packages/core/src/code-mode/`, `apps/x/CODE_MODE_ENGINES_PLAN.md` (their lesson:
driving the user's installed CLIs is fragile — version skew, PATH lost under a GUI launch).

- A **Code** section: pick a git repo, describe tasks, start several **coding sessions in parallel**, each
  in its own git worktree, each a Claude Code (`claude`) or Codex (`codex`) process the user already has
  signed in (`CodingAgentCLIs` already finds them; `LoginShellEnvironment` already fixes PATH).
- Unlike the subscription chat providers, these sessions **do** run the CLI's own tools inside the
  worktree — that is the point — so starting one is an approval card naming the folder and the agent.
  Nothing runs outside the worktree; Wisp never reads or forwards the CLIs' credentials.
- Wisp drives them with context: the task, relevant Brain pages, and (opt-in) the current screen's
  error text. Live status per session from the CLI's stream-json, a diff view, and Merge / Discard /
  Open in editor. A buddy (Coder specialty) can be the one that starts and follows sessions.
- **Tests.** `Tests/CodeMode`: worktree naming, stream event parsing, session state machine.

## Phase 4 — Mini apps

Rowboat reference: `packages/core/src/apps/`, `apps/x/MINI_APPS_PLAN.md`.

- A mini app is **one self-contained HTML file** (UI) + an **automation** that produces fresh
  `data.json` on its trigger + optional state, shown as a card in an **Apps** section and opened in a
  sandboxed `WKWebView` (no network, no file access).
- A scoped bridge `window.wisp.call(tool, args)` lets the page call only the tools the app declared, and
  every call goes through `AgentToolRegistry.invoke`, so confirmation cards and the `ToolCallSafety`
  floor apply exactly as everywhere else.
- **Build one by describing it**: one call produces the matched triple (HTML, data schema, automation
  instructions). Needs a capable model (Claude); the local 3B model is offered templates only.
- Stored under `Application Support/Wisp/apps/<id>/`; shared as a `.wisp` file (setup only, reviewed on
  import, like buddies). No hosted publishing.
- **Tests.** `Tests/MiniApps`: manifest validation, bridge allow-list, data schema check.

## Phase 5 — Spaces with people

Rowboat reference: `apps/harbor` (server, `CONTRACT.md`, `SPEC.md`), `packages/core/src/spaces/`,
`packages/spaces-client`.

- Wisp becomes a **Harbor client**: the user adds a server (Rowboat's hosted one, or self-hosted Harbor),
  signs in in the browser (OIDC through `ASWebAuthenticationSession`; dev tokens for a local Harbor), and
  the token lives in the Keychain. REST `/v1/*` + the `/v1/live` stream.
- Spaces and DMs appear in the Buddies list column beside buddies and groups. People and agents in the
  same rooms; the user's buddies can be members, attributed "Name (via Wisp)".
- **`@wisp` in a space** runs a turn on this Mac with the user's context and replies as the user — with
  the rule Rowboat itself states: what it reads may be private, what it posts lands in front of the team,
  so **every post an agent writes is shown for approval** (editable card) unless the user turns that off
  per space.
- This is a new **opt-in network use** that sends messages to a server, labelled as such, off until a
  server is added. The local path never depends on it.
- Pinned to one protocol version; a version mismatch shows "this server is newer than Wisp" rather than
  guessing.
- **Tests.** `Tests/Spaces`: protocol decoding against Harbor's fixtures, attribution, approval rules.

## The rebrand (name kept)

- README, site and App icon text: "Wisp — an AI coworker on your Mac that remembers your work." The
  notch stays the fast way in; the window becomes the workplace.
- Window rail order: Today, Inbox, Meetings, Buddies (+ Spaces), Code, Apps, Brain, Settings. Inbox,
  Meetings, Code and Apps sit behind **Advanced features** until each phase is solid.
- Today leads with: important email + drafts, the next meeting with its prep, running code sessions.
- Visual identity (Graphite theme, ribbon mark) stays unless a new look is asked for.

## Not brought in (for now)

Rowboat's built-in isolated browser (Wisp drives the user's own browser in its own tab), whiteboards,
live notes, decks/spreadsheets, Slack/Fireflies/Granola importers, the phone app.
