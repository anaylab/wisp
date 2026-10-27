# Learned shortcuts — plan

Status: phases 1–5 built (promotion: a manual button for any shortcut; a schedule or event only when no step asks — today just music play/pause, by the owner's decision to allow that one exception) (replay behind Settings → Agent → Learned shortcuts, off by default) (core + offer/save card, notch only; History offer deferred because History keeps step text, not structured calls). Known gap: tools that report "i couldn't…" as ordinary text are judged by wording (`ShortcutToolResultJudgement`), a heuristic that errs toward failed. Inspired by Atticus ("a new task is worked out once, then repeated
requests run without AI" + an ask log of every exact command the AI issued).

## Goal

A request the model solved with tools once can be saved, with the user's say-so, as a **learned
shortcut**. The next time the user says the same thing, Wisp replays the recorded tool calls
directly: no model call, no screenshot, ~10–100 ms instead of seconds of vision encoding. The
model is still the fallback for everything else.

Why it fits Wisp: model residency is the binding constraint on 18 GB, a screenshot costs ~4 s of
vision encoding, and `FastCommandRouter` already proves the pattern for a closed set of hard-coded
commands. This makes that set user-grown instead of hand-written.

## Non-goals (v1)

- Not a macro recorder for mouse/keyboard. Only registry tool calls.
- Not automatic learning. Nothing is saved without a click on a card showing the exact calls.
- Not scheduled/triggered running. That is what Automations are for (see "Promote" below).
- No fuzzy or model-based phrase matching. Deterministic only.

## How it works

```
turn ends successfully with tool calls
  -> ShortcutRecorder decides: replayable? -> offer "Save as shortcut" (answer actions + History)
  -> user confirms in an editable card (phrase, slots, steps) -> LearnedShortcutStore

later utterance
  sendTranscriptToClaudeWithScreenshot
    FastCommandRouter / other parsers (unchanged, they run first, they are more exact)
    -> LearnedShortcutMatcher.match(transcript)        // pure
    -> LearnedShortcutRunner.run(shortcut, slots)      // each step via AgentToolRegistry.invoke
    -> on any failure: fall back to an ordinary model turn
```

### Recording

`AgentTurnRunner.Outcome` gains `executedToolCalls: [ExecutedToolCall]` (tool name,
`executedToolInput` after preparation and user edits, ok/error, order). `AgentToolRegistry.invoke`
already returns `executedToolInput`, and History step detail already stores it as a string; the
recorder needs the structured `JSONValue`, so it must not be parsed back out of the string.

A turn is a **candidate** only if all hold (pure `ShortcutReplayability`):

1. Every call succeeded, none declined, no assistant error.
2. Every tool is on a **replayable allow-list** (`arrange_windows`, `control_music`, `run_shortcut`,
   `create_reminder`, `chrome_*` organizing tools, `draft_email` open-only, `set` style tools…).
   Allow-list, not deny-list: a tool that registers later is not replayable until someone decides.
3. No argument is **ephemeral**: cua-driver `element_token`/`pid`, Wisp's `a12`/`t7` ids, browser
   `e7` element ids, tab ids, task ids. These are per-turn and would replay stale.
4. No argument is **model-authored content** the user didn't say: an email body, a post, a message the
   model wrote, a search query it invented. Replaying those would send yesterday's text. Rule: every
   string argument must either be a *constant the user can see and approve* on the save card or
   a *slot* filled from the new utterance.
5. No read tool whose **result the model interpreted** to decide the next call (e.g. `list_windows`
   -> choose one). Reads are allowed only if their output isn't needed by a later call's arguments
   (v1: simplest rule is "no later argument depends on an earlier result"; a model-free check is
   "no later argument value appears only in an earlier result, not in the utterance or constants").
6. `browser_task`, `do_in_background`, `delegate_coding_task`, `ask_buddy` and anything
   `ToolCallSafety` classes as arbitrary command execution are **never** candidates.

### Slots (parameters)

Deterministic, no model: find argument strings that occur in the transcript (case/punctuation
insensitive, longest first). Each hit becomes a slot with the surrounding words as the phrase
template: "put **Notes** on the left" -> `put {app} on the {side}` is *not* inferred (too clever).
v1 rule: a slot is only created for a literal that appears verbatim in the utterance; the rest of
the utterance is the fixed phrase. The save card shows the template and lets the user toggle each
slot to constant, so "move Safari left" can become "move {app} left" or stay literal.

### Matching

`LearnedShortcutMatcher` is pure, same bias as `FastCommandRouter`: **toward not matching**.

- Normalised whole-utterance match against the template (lowercase, strip punctuation and
  courtesy words, same helper the router uses). Slots capture one run of words, must not be empty,
  must satisfy a validator per slot kind (app name resolves to exactly one running regular app as
  `WindowLayoutApplicationNameMatcher` does; free text capped at N words).
- Exact template or nothing. No prefix, substring or similarity matching in v1.
- Two shortcuts matching one utterance -> match nothing (model turn).
- Skipped for dictation turns, titled routine/skill turns, and while a confirmation is pending.

### Running

`LearnedShortcutRunner` calls `AgentToolRegistry.invoke(name:input:)` for each step, in order.
That is the only path to a tool, so **confirmation, the `ToolCallSafety` floor, editable cards and
Automation tool policy behave exactly as in a model turn.** A replay that sends, deletes or
runs a shortcut still shows its card. "Learned" never means "pre-approved". Session auto-approve
behaves as it does today.

- Stop at the first failed or declined step; report which step and why in the notch.
- On failure with no side effects yet (first step failed), fall back to a normal model turn with the
  original transcript. After a side effect, don't fall back (the model would repeat it); say so.
- Record a task in `AgentTaskRegistry`: title = transcript, first step "Learned shortcut — no model
  call", then each tool step with its executed input (same as History shows today).
- Reply is a short fixed line from the shortcut ("done — Safari left.") plus `flashIsland(.success)`,
  like the window-layout reply. Voice mode speaks it via the normal `[SAY:]`-less path used by
  `FastCommandRouter` outcomes.

### Drift and trust

- Each shortcut tracks `successCount`, `consecutiveFailures`, `lastRunAt`.
- Two consecutive failures -> disabled with a visible reason; one tap to re-enable or delete.
- Shown in Settings with the full call list, so the user can read exactly what it does.
- Editing a shortcut's steps re-runs the replayability check.

## Storage and privacy

- `~/Library/Application Support/Wisp/learned-shortcuts.json`, 0600, debounced save, flush on quit,
  same shape as `AutomationStore`.
- Contains the user's phrase and tool arguments. Arguments can hold names, paths, text. **Local only**;
  never logged, never in the usage log, never exported by `WispShareBundle`, never sent to a model.
- A shortcut is created only from the user's own turn (not buddy/automation runs), so a model that
  read a web page can't plant one. Saving requires a click on the exact steps.
- No screenshots, no OCR, no transcript beyond the phrase.

## UI

1. **Offer:** a "Save as shortcut" button next to Copy on a qualifying answer (notch reply actions and
   History detail, beside "Save as routine" / "Save as automation"). Only shown when the replayability
   check passes. Not shown for a cloud-model turn whose arguments came from private tools? (see open questions)
2. **Save card:** phrase (editable), detected slots (toggle constant/slot), the steps in plain words
   (reuse `ToolConfirmationCardBuilder` descriptions), Save / Cancel. One card, no wizard.
3. **Manage:** Settings -> Agent -> "Learned shortcuts" card: list, enable switch, run count,
   last run, disabled reason, Delete, "Promote to automation".
4. **Menu bar / notch:** nothing new.

## Promote to automation / routine (v2)

A learned shortcut is a deterministic single-action recipe, which is a subset of an Automation's
Action. "Promote" turns it into an `Automation` (manual trigger, action = replay) so it can get a
schedule, an output and a notify. Reuse `AutomationToolPolicy`: only unattended-safe tools may be
promoted; anything that prompts stays manual-only.

## Files

| File | Purpose |
|------|---------|
| `LearnedShortcuts/LearnedShortcut.swift` | Pure model: phrase template, slots, steps, stats, Codable. |
| `LearnedShortcuts/ShortcutReplayability.swift` | Pure: allow-list, ephemeral-argument and content-authorship checks, slot detection. |
| `LearnedShortcuts/LearnedShortcutMatcher.swift` | Pure: normalisation, template match, slot validation, ambiguity. |
| `LearnedShortcuts/LearnedShortcutStore.swift` | `@MainActor` store, 0600 JSON, disable-after-failures policy. |
| `LearnedShortcuts/LearnedShortcutRunner.swift` | Runs steps through `AgentToolRegistry.invoke`; failure/fallback rules. |
| `LearnedShortcuts/ShortcutRecorder.swift` | Turns a finished turn's `executedToolCalls` into a save offer. |
| `WispWindow/LearnedShortcutsCard.swift`, `SaveAsShortcutCard.swift` | Settings card and the save card. |
| edits: `AgentTurnRunner.swift`, `CompanionManager.swift`, `HistoryTab.swift`, `AgentTab.swift` | Outcome field, route after the fast routers, offer button, settings card. |

## Tests (`Tests/LearnedShortcuts/run.sh`, plain swiftc, no TCC)

- Replayability: rejects ephemeral ids, model-authored bodies, dependent reads, denied tools, errors;
  accepts window layout / music / reminder.
- Slots: verbatim detection, longest-first, empty slot rejected, constant toggle.
- Matcher: exact match, courtesy words, near-miss ("move safari to left" vs template) must NOT match,
  two shortcuts -> nil, slot validators.
- Runner with a fake registry: order, stop on failure, fallback only when no side effect, declined step.
- Store: round trip, 0600, two failures disables, no content outside the declared fields.
- Safety invariant test: a shortcut whose step is `send_imessage` still reaches
  `requestApprovalAllowingEdits` (the registry path), i.e. replay can't bypass the card.

## Phases

1. **Pure core + tests** (model, replayability, matcher, store). No UI, no hook.
2. **Record + save card** (`executedToolCalls`, offer button, store write). Still nothing replays.
3. **Replay hook + runner + History/task records**, behind a Settings switch (default off at first).
4. **Settings management + disable-on-drift.**
5. **Promote to automation.**

## Open questions

1. Offer after every qualifying turn, or only when the same request was solved twice? (Atticus learns
   once. Offering once keeps it explicit, but may nag; suggest: offer once per distinct phrase, with
   "don't ask again for this".)
2. Cloud-model turns: their tool arguments may derive from private sources the model read. If
   rule 5 passes this is fine, but should cloud-solved shortcuts be allowed at all in v1? Suggest yes.
3. Voice vs typed phrasing: ASR variants ("eight" vs "8") make exact matching brittle. Add a small
   normaliser (numbers, "the", courtesy words) or let the user save 2–3 phrasings per shortcut?
4. Should a shortcut be allowed to contain several tool calls in v1, or one only? Multi-step is the
   interesting case ("set up my study screen"), but the dependency check gets harder.
5. Does the default on `AgentModeEnabled=false` matter? Replay doesn't need agent mode, but only
   agent-mode turns can produce recordings.
6. Name: "Shortcuts" collides with Apple Shortcuts (`run_shortcut`). Suggest "Quick actions" or "Learned
   actions" in the UI.
