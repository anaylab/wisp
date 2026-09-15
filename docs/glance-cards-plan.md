# Plan: Visual-first notch, optional voice, and glance cards

> **Kickoff prompt (hand this to the agent):**
> Read this file and `CLAUDE.md`, then implement **Phase 1 only**. Stop after it
> builds clean and show me the diff before continuing. Do the phases one at a time,
> checkpointing with me between each.

## Context for the agent

You are working in **Wisp** (`/Users/m3pro/Downloads/clicky`), a local-first macOS
menu-bar voice companion. Read `CLAUDE.md` first and obey it — especially:

- **Do not run `xcodebuild` from the terminal** (it invalidates TCC). Build via
  `osascript -e 'tell application "Xcode" to build (first workspace document)'`.
- Clarity-first naming: long, explicit names, no abbreviations.
- Do not add features beyond what's asked; do not touch the known non-blocking
  warnings (Swift 6 concurrency, deprecated `onChange`).
- Keep the local path local-first — no new network calls, no cloud dependency.

## The interaction model we are moving toward

Today Wisp answers by **speaking** the reply (TTS, sentence-by-sentence) with a small
bubble near the cursor. We are inverting that: the **notch becomes the primary reply
surface** (clean, visually appealing, "dynamic-island" style, inspired by VoiceOS),
and **speech becomes optional**. Concretely:

- **Voice mode OFF** — fully silent. The user still push-to-talks to *speak to* Wisp,
  but no reply is ever spoken. Every reply renders as **text + an optional glance
  card in the notch**. (This is why the notch reply surface in Phase 1 is
  load-bearing: with speech off, the notch is the *only* place the answer appears.)
- **Voice mode ON** — the **model decides per reply** whether to speak and what to
  say, via a short spoken-line tag (Phase 2). Visual-only answers stay quiet; only
  conversational replies talk. The full reply still renders visually either way.

**Default:** ship with voice mode **ON + model-decides** (calmer than today's
speak-everything, but not mute). The default is a one-line change if we later decide
silent-by-default is better.

## Where speech happens today (the single gate)

TTS runs through `ttsProvider` in `CompanionManager.swift`:
- incremental sentence playback around lines ~1030–1040 (`speakIncremental`),
- the whole-reply fallback around line ~1224 (`speakText(spokenText)`),
- plus fixed spoken strings (confirmations, failure fallbacks) elsewhere.

Gate reply speech at these call sites. Leave the **confirmation** speech
(`ToolConfirmationCoordinator`) alone unless a phase says otherwise — being asked for
permission out loud is still useful. The response bubble today lives in
`CompanionResponseOverlay.swift`; the new primary surface is the notch
(`NotchHUDView.swift` / `NotchViewModel` in `NotchWindowController.swift`).

## Card architecture — app-matched templates (revised direction)

> **Owner decision, mid-build:** each card should look like the **native app the
> answer comes from** (a weather answer like Apple Weather, a calendar answer like
> Calendar), rendered by a **per-kind template**; data-rich kinds are filled by a
> **per-kind live data source**, not by the model. The generic card below is kept
> as the `.generic` fallback for anything without a dedicated template.

Small models cannot draw a rich, app-specific UI reliably. So the reliability
trick is kept and pushed further: **the model emits a tiny structured payload with
a `kind`; Wisp owns the look and, where needed, the data.**

Two shapes of card:

1. **Data-sourced** (e.g. `weather`): the model emits only an *intent* — the kind
   plus a key or two (`{"kind":"weather","location":"San Francisco"}`). Wisp
   fetches the live data through a per-kind **data provider** and renders it in
   that app's layout. The model never sends temperatures or forecasts.
2. **Model-supplied** (the existing `generic` kind): the model emits typed
   `blocks` directly and Wisp renders them.

Constraints that still hold:

- The model **never draws a UI** — it names a `kind` and supplies keys/fields.
- Reuse the **structured-text-tag** mechanism (`[POINT:]`, `[BOX:]`, `[TOOL:]`,
  `[CARD:]`); do **not** attempt native tool_calls (see
  `StructuredTextToolProtocol.swift`).
- The **generic** kind keeps its tight schema: 1–3 blocks (`prefix(3)`), fixed
  vocabulary (`header`/`list`/`keyValue`/`stats`), semantic tone
  (`good`/`bad`/`neutral`) resolved to `DS.Colors` (model never sends hex), and a
  fixed SF Symbol icon allowlist with a default fallback.
- Templates use `DS.*` tokens where they apply; an app-styled card (weather)
  carries its own palette (a sky gradient) but stays theme-correct.

### Local-first posture (this feature intentionally adds network)

The generic path makes **no** network calls, ever. Data-sourced kinds do — that is
the point of this direction — so: each data-sourced card is **labelled** (a small
"Live · source" chip), a single setting gates all card data providers (default
on) so the feature can return to fully-local, and providers fetch only what the
card needs (a place name → a forecast) — **never** a screenshot or transcript.

---

## Phase 1 — Voice-mode toggle + TTS suppression + notch reply surface

Make silent mode real and usable. This is the foundation for everything else.

- Create **`VoiceOutputPreference.swift`** — a `UserDefaults`-backed source of truth
  for whether reply speech is enabled, modeled on `BuddyChatProviderSelection.swift` /
  `ShortcutBindingStore.swift` (`@Published`, defaults to enabled, persists).
- In `CompanionManager.swift`, gate every **reply** speech call (`speakIncremental`,
  `speakText(spokenText)`) on the preference. When OFF, skip TTS entirely — do not
  synthesize and discard; do not touch the warm-keep heartbeat logic.
- Add a **reply region to the notch** (`NotchHUDView.swift`): the current reply text
  (streamed as it arrives) plus a slot for a glance card (Phase 4 fills the card;
  here it is just the text). Add `currentReplyText: String` to `NotchViewModel`; have
  `CompanionManager` publish the streamed reply to it. Respect the **fixed-size
  window** rule — render inside existing expanded bounds, never resize the panel.
- Add a **voice toggle control** in the notch header (there is already a dock-cursor
  toggle there — match its style, pointer cursor on hover) and a mirror toggle in the
  dashboard (a small addition to `ShortcutsTab.swift` or a settings surface —
  pick the smaller change and note which).
- Reply text auto-clears on the next turn / `.wispDismissPanel`, like annotations do.

Deliverable: toggling voice off silences replies and shows them as text in the notch;
toggling on restores speech; builds clean.

## Phase 2 — Per-reply speak decision (`[SAY:...]` tag)

When voice is ON, let the model choose whether/what to speak.

- Teach the model one tag, e.g. `[SAY: short spoken line]`, in the system prompt —
  terse, in the style of `ScreenAnnotationParser.promptInstructions`. Rule: include it
  only when speaking aloud adds value; the full answer is always shown visually.
- Parse and strip it (same back-to-front removal as the other parsers). When voice ON:
  speak the `[SAY:...]` line if present, else stay silent. When voice OFF: ignore it
  entirely. If no tag and voice ON, default to silent (visual-first) rather than
  speaking the whole reply — confirm this default in the phase's checkpoint.
- Unit tests: tag present/absent, stripped from displayed text, honored only when
  voice on.

> The card work below is split into small phases (3A–3E), checkpointing between
> each. **3 (generic model + parser) and 4 (generic renderer) are already built**
> — `GlanceCard.swift`, `GlanceCardView.swift`, `GlanceCardParserTests.swift`, and
> the notch view-model slot — and become the `.generic` kind. What remains is the
> intent layer, the first data-sourced kind (weather), and the pipeline wiring.

## Phase 3A — Intent model + parser + tests  *(current)*

Add the app-matched intent layer on top of the existing generic card, in
`GlanceCard.swift`:

- `struct WeatherCardRequest: Equatable { locationName: String }`.
- `enum GlanceCardRequest: Equatable` — `.weather(WeatherCardRequest)`,
  `.generic(GlanceCard)`; future `.calendar` / `.music` / `.mail`.
- `GlanceCardParser.parse(_ responseText:) -> (spokenText: String, request:
  GlanceCardRequest?)` — decode the `[CARD:{…}]` body, read `kind`:
  `weather` → a weather request (needs a non-empty `location`, else drop);
  absent/`generic`/has `blocks` → the existing validated generic card; unknown →
  drop. Malformed JSON drops the card, never crashes; tag stripped from spoken text.
- `promptInstructions` teaches both shapes with one worked example each and the
  "never copy the example's values" warning; keep it as terse as the annotation
  instructions (shares the window with a screenshot).
- Unit tests: weather intent parsed; weather without a location dropped; generic
  still parsed + clamped + unknown-block-dropped; unknown kind dropped; malformed
  dropped with text preserved; tag stripped. **Deliverable: builds clean.**

## Phase 3B — Weather data provider

- `GlanceCardDataProvider` async protocol + `WeatherDataProvider` over **Open-Meteo**
  (geocoding + current + hourly + daily; free, HTTPS, **no API key**) → a
  `WeatherSnapshot` value (place, current temp/condition/high/low, an hourly slice,
  a multi-day slice). Async, briefly cached, cancel-on-replace, runs off the
  interactive path. Gated by the card-data setting; labelled at the card.
- Tests over JSON→`WeatherSnapshot` mapping from a checked-in fixture (no live
  network in tests).

## Phase 3C — Weather template (SwiftUI)

- `WeatherCardView` in Apple Weather's layout: city + big current temp + condition
  + H/L, an hourly strip (time · glyph · temp), and a multi-day list with
  low—range-bar—high. Loading and failed states so the card can appear immediately
  and fill in. Its own sky palette; SF Symbol weather glyphs.

## Phase 3D — Resolved card + notch rendering

- `enum ResolvedGlanceCard: Equatable` — `.generic(GlanceCard)`,
  `.weather(WeatherSnapshotState)`. `NotchViewModel` holds `ResolvedGlanceCard?`;
  `NotchHUDView` switches to the matching template in the fixed expanded bounds
  (never resize). Auto-dismiss on next turn / `.wispDismissPanel` (already wired).

## Phase 3E — Wire card parsing + resolution into the turn pipeline

- In `CompanionManager.swift`, alongside `ScreenAnnotationParser.parse` and
  `StructuredTextToolProtocol.parse`, run `GlanceCardParser.parse`. Order: strip
  tool tags, annotation tags, `[SAY:]`, and `[CARD:]`; the remainder is the
  displayed reply text. Resolve the request (fetch weather via the provider),
  publish the resolved card to the notch view model, auto-dismiss on next turn.
- Append `GlanceCardParser.promptInstructions` to the system prompt (token budget:
  keep it as short as the annotation instructions).
- End-to-end check: a `[CARD:{"kind":"weather",…}]` reply shows a live weather card
  and the tag is not spoken.

## Phase 6 — Rich confirmation cards (upgrade, don't replace)

Upgrade `ToolConfirmationView.swift` to render a declarative card while preserving the
`ToolConfirmationCoordinator` flow (spoken yes/no, 45s timeout, deny-by-default).

- Add an optional `confirmationCard: GlanceCard?` to `PendingConfirmation`. When
  present, render blocks (e.g. `header` "New Message", `keyValue` To/Subject, body)
  above the existing **Don't / Allow** buttons; when absent, fall back to today's plain
  summary (zero regression).
- v1 is **display-only** (no inline editing). Comment that inline-editable fields
  (VoiceOS `{{param}}` bindings) are a deliberate future extension.

## Explicit non-goals

- No charts, sandboxed HTML widgets, or Widget Kit equivalent.
- No inline-editable confirmation fields / param bindings.
- The **generic** path adds no network calls; **data-sourced** kinds (weather, …)
  intentionally do, gated + labelled (see "Local-first posture"). No changes to
  model **provider** selection, and no screenshots/transcripts sent to any card
  data provider.
- Do not modify push-to-talk input, dictation, or MCP paths.

## Verification

- `osascript -e 'tell application "Xcode" to build (first workspace document)'` builds
  clean (ignore the documented Swift 6 / `onChange` warnings).
- New unit tests pass.
- If you run the app: `open -a <path>/Wisp.app` (never the raw binary — TCC SIGABRT),
  logs via `log stream --predicate 'process == "Wisp"'`.
- Manual checks: voice off → reply is silent and readable in the notch; voice on with
  no `[SAY:]` → silent + visual; voice on with `[SAY:]` → speaks only that line; a
  `[CARD:]` reply shows a card and the tag is not shown/spoken; a plain reply behaves
  as before.

## Housekeeping

- Branch: `feature/visual-first-notch`.
- Update `CLAUDE.md` Key Files table with new files (`VoiceOutputPreference.swift`,
  `GlanceCard.swift`, `GlanceCardView.swift`) and note the interaction-model change in
  the Architecture section (per its self-update instructions).
- Commit messages: imperative, explain the "why." End with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
