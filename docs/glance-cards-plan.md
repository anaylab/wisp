# Plan: VoiceOS-style visual cards in the notch

> **Kickoff prompt (hand this to the agent):**
> Read this file and `CLAUDE.md`, then implement **Phase 1 only**. Stop after the
> parser + tests build clean and show me the diff before continuing. Do the phases
> one at a time, checkpointing with me between each.

## Context for the agent

You are working in **Wisp** (`/Users/m3pro/Downloads/clicky`), a local-first macOS
menu-bar voice companion. Read `CLAUDE.md` first and obey it — especially:

- **Do not run `xcodebuild` from the terminal** (it invalidates TCC). Build via
  `osascript -e 'tell application "Xcode" to build (first workspace document)'`.
- Clarity-first naming: long, explicit names, no abbreviations.
- Do not add features beyond what's asked; do not touch the known non-blocking
  warnings (Swift 6 concurrency, deprecated `onChange`).
- Keep the local path local-first — no new network calls, no cloud dependency.

**Goal:** give the assistant a *visual* answer surface in the notch, modeled on
VoiceOS's card system. Two card kinds:

1. **Glance cards** — read-only, informational, rendered from the model's reply
   (e.g. a weather readout, a list, key/value facts).
2. **Rich confirmation cards** — the review-before-acting card (e.g. a Gmail
   compose with a Send button), upgrading today's plain argument-summary
   confirmation.

The proven mechanism in this codebase is **structured text tags** parsed out of the
model reply — the same shape as `[POINT:...]`, `[BOX:...]`, `[TOOL:...]`. Reuse that
pattern exactly; do **not** attempt native tool_calls (the local model can't do
them — see `StructuredTextToolProtocol.swift`).

## Design constraints (borrowed from VoiceOS, and required here)

Small models break rich UIs unless the schema is tightly constrained. Enforce:

- **1–3 blocks per card**, drop anything off-schema silently (mirror
  `ScreenAnnotationParser`'s `prefix(3)`).
- **Fixed block vocabulary** for v1: `header`, `list`, `keyValue`, `stats`. No
  charts in v1.
- **Semantic tone only** (`good` / `bad` / `neutral`) — the renderer picks colors
  from `DS.Colors`, the model never sends hex.
- **Icon allowlist** — a fixed set of SF Symbol names the model may reference;
  unknown names fall back to a default glyph.
- All rendering uses `DS.*` tokens from `DesignSystem.swift`; theme-correct, no
  hard-coded colors.
- Card is stripped from spoken text before TTS, exactly like annotation tags today.

## Phase 1 — Glance card model + parser (no UI yet)

Create **`GlanceCard.swift`** modeled structurally on `ScreenAnnotation.swift`:

- `struct GlanceCard: Identifiable, Equatable` holding `blocks: [GlanceBlock]`.
- `enum GlanceBlock: Equatable` with cases `.header(title:icon:trailing:)`,
  `.list(rows:)`, `.keyValue(pairs:)`, `.stats(items:)`. Define small value types
  (`GlanceListRow`, `GlanceStat`, etc.) with explicit, unabbreviated field names.
- `enum GlanceTone { case good, bad, neutral }`.
- `enum GlanceCardParser` with:
  - `static let promptInstructions: String` — terse, mirroring the voice/style of
    `ScreenAnnotationParser.promptInstructions` and
    `StructuredTextToolProtocol.promptInstructions`. Teach one tag:
    `[CARD:{...json...}]` placed at the very end of the reply, with one worked
    example (models copy a demonstrated shape). Explicitly warn "never copy the
    example's values."
  - `static func parse(_ responseText:) -> (spokenText: String, card: GlanceCard?)`
    — regex-extract the `[CARD:...]` tag, JSON-decode the body, validate against the
    block vocabulary, strip the tag from spoken text (back-to-front removal like the
    existing parsers). Tolerate malformed JSON by dropping the card, never crashing.
- **Unit tests** in the test target: valid card, too many blocks (clamped), unknown
  block type (dropped), malformed JSON (card nil, text preserved), tag stripped from
  spoken text.

Deliverable: parser + tests green. No UI wiring yet.

## Phase 2 — Glance card rendering in the notch

- Create **`GlanceCardView.swift`** — a SwiftUI view rendering `[GlanceBlock]` with
  `DS.*` tokens. One private subview per block type. Match the notch's dark-glass
  aesthetic (see `NotchHUDView.swift` / `DesignSystem.swift`). Include hover
  affordances per CLAUDE.md (pointer cursor on any interactive element; these cards
  are mostly non-interactive in v1, so no click targets).
- Add a `GlanceCard?` to `NotchViewModel` (owned by `NotchWindowController.swift`)
  and render it in the expanded panel region of `NotchHUDView`. Respect the
  fixed-size-window rule — the card lives inside the existing expanded bounds; **do
  not** resize the window (CLAUDE.md documents why resizing feeds back on itself).
- Card auto-dismisses on the next turn / on `.wispDismissPanel`.

## Phase 3 — Wire glance parsing into the turn pipeline

- In `CompanionManager.swift`, where the model reply is currently post-processed
  (the same place `ScreenAnnotationParser.parse` and `StructuredTextToolProtocol.parse`
  are called), also run `GlanceCardParser.parse`. Order matters: strip tool tags and
  annotation tags and card tags, then speak what remains. Publish the parsed
  `GlanceCard` to the notch view model.
- Append `GlanceCardParser.promptInstructions` to the system prompt alongside the
  existing annotation/tool instructions. **Token budget:** this shares the window
  with a screenshot — keep it as short as the annotation instructions.

## Phase 4 — Rich confirmation cards (upgrade, don't replace)

Today `ToolConfirmationView.swift` shows a spoken question + raw `toolName` +
`argumentSummary` text. Upgrade it to render a declarative card while preserving the
existing `ToolConfirmationCoordinator` flow (spoken yes/no, 45s timeout,
deny-by-default — all untouched).

- Add an optional `confirmationCard: GlanceCard?` (or a small dedicated
  `ConfirmationCard` type if editable fields are needed) to `PendingConfirmation`.
  When present, `ToolConfirmationView` renders blocks (e.g. a `header` "New Message",
  `keyValue` To/Subject, body text) above the existing **Don't / Allow** buttons;
  when absent, fall back to today's plain summary (zero regression).
- v1 is **display-only** confirmation cards (no inline editing) — this keeps the
  change small and matches the existing "approve or deny" model. Note in a code
  comment that inline-editable fields (VoiceOS `{{param}}` bindings) are a deliberate
  future extension, not built now.
- Keep the "or just say yes" affordance and the countdown.

## Explicit non-goals for this task

- No charts, no sandboxed HTML widgets, no Widget Kit equivalent.
- No inline-editable confirmation fields / param bindings.
- No cloud dependency, no new network calls, no changes to provider selection —
  this is pure local rendering of existing model output.
- Do not modify the push-to-talk, dictation, or MCP paths.

## Verification

- `osascript -e 'tell application "Xcode" to build (first workspace document)'`
  builds clean (ignore the documented Swift 6 / `onChange` warnings).
- New unit tests pass.
- If you run the app, launch with `open -a <path>/Wisp.app` (never the raw binary —
  TCC will SIGABRT), and read logs via `log stream --predicate 'process == "Wisp"'`.
- Manually confirm: a reply with a `[CARD:...]` tag shows a card in the notch and the
  tag is not spoken; a reply without one behaves exactly as before.

## Housekeeping

- Branch: `feature/notch-glance-cards`.
- Update `CLAUDE.md`'s Key Files table with `GlanceCard.swift`, `GlanceCardView.swift`
  (per its self-update instructions).
- Commit messages: imperative, explain the "why." End with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
