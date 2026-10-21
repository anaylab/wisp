# Wisp - Agent Instructions

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar
(no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel
with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input,
transcribes it on-device (Parakeet via FluidAudio), and sends the transcript + a screenshot
to a local model. The
model responds with text, shown in the notch; speech is optional (voice/silent mode, and in
voice mode only the short line the model tags with `[SAY: …]` is spoken, by the on-device
Kokoro voice via FluidAudio by default). A transparent screen
overlay can mark UI elements the model references on any connected monitor with a pulsing
marker, and can draw boxes, arrows and highlights on screen.

**Local-first and private by default.** Out of the box everything runs on this machine: the
local Ollama model, on-device speech recognition (FluidAudio's Parakeet on the Neural Engine,
Apple Speech as fallback), and on-device speech synthesis (FluidAudio's Kokoro, the macOS
voices as fallback), with the model traffic being HTTP to `localhost` (Ollama on 11434;
Chatterbox TTS on 8004 only if opted into) — no Cloudflare Worker and no analytics. The
Parakeet/Kokoro model files are downloaded from HuggingFace once, on first launch; audio and
text never leave the Mac. The only other default
network use is live glance-card data (weather, places, configured sources), gated by
`GlanceCardDataPreference`, which sends a place name or search query (plus, for places, the
location to Apple Maps), never a screenshot. The model backend is now *selectable*: a user
can opt in, in Settings → Model, to a bring-your-own-key cloud provider (`ModelProviderFactory` /
`BuddyChatProviderSelection`, key in the Keychain via `ProviderKeychainStore`), which sends
screenshots and the transcript off this machine and is labelled as such. Local remains the
default and the private path — do not make a cloud provider the default, and do not add a
cloud dependency to the local path, without asking.

**Jobs (Canvas calendar + daily checklist)** add one more opt-in network use: a user-pasted Canvas
calendar feed (.ics) URL, fetched on launch and at most hourly by `CanvasFeedStore` (https GET, no
cookies, 5 MB cap, no off-https redirects). It is off until a URL is saved, has its own switch
(`JobsEngine.isCanvasJobEnabled`, not `GlanceCardDataPreference`), and the URL is a secret: Keychain only
(`CanvasFeedKeychainStore`, service `com.wisp.canvas-feed`), never in UserDefaults, logs, errors or History.
Sync is deterministic code with no model call. Writes go only to a calendar named "Wisp" and a Reminders list
named "Wisp Today"; study blocks are written only after one approval card (`wisp_jobs_apply_study_blocks`, on
`ToolCallSafety.alwaysAskBareToolNames`, so session auto-approve cannot skip it).

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon. The Wisp window raises the
  activation policy to `.regular` while open, and drops back to `.accessory` on close.
- **Surfaces (notch-first layout)**: the **notch** is where Wisp is *used* (answers, cards, quick
  panel, quick chat); the **Wisp window** is where it's *managed*; the **menu bar item** is a plain
  native `NSMenu` (`MenuBarMenuController`: status, Ask Wisp…, Ask About a Part…, Save Worked Solution… (enabled only while the drawings hold a note or circle), Open Wisp, Chat, Buddies, Pause
  Listening / Speak Replies / Sound Cues checkmarks, Settings…, Quit — rebuilt in `menuNeedsUpdate`).
  **Pause listening** (`CompanionManager.isListeningPaused` / `setListeningPaused`) drops every talk
  gesture and routine digit at the shortcut sinks (cancelling a hold in progress); typed questions
  still work. It isn't persisted, dims the menu bar icon (`appearsDisabled`), and shows a Resume
  banner on Today and "Listening paused" in the notch chat's talk pill. The window
  (`WispWindow/`) replaced the old dashboard, the pop-out conversation window, the notch's own
  settings pages and the big menu bar panel, so every setting has exactly one home. It has no sidebar:
  a slim top bar (`WispWindowView`) holds the `WispSection`s as icons — **four by default** (Today, Chat, Buddies, Settings), eight with
  Settings → General → **Advanced features** on (`WispAdvancedFeaturesPreference`, off by default, adds Brain, Routines, History,
  Connections; with it off Routines, History and Connections open as Settings pages). Buddies are first-class and never hidden — Advanced
  hides only buddy delegation (`ask_buddy`), per-buddy models and sharing/importing, plus those four sections; automations and the Canvas
  page live inside Buddies (pages Buddies / Automations / Canvas). Hiding only gates visibility and launch-time work: no
  code or stored buddy/brain data is removed, and the brain is never switched off (`MemoryStore` needs `me.md`) — the open one expands to its name and the pill slides between tabs
  (`matchedGeometryEffect`) — with a status pill (mark + state + model) at the end, and a section with several
  pages (`WispPage`) gets a segmented strip beneath. The `NSWindow` is full-size-content with a transparent title
  bar and hidden title; the bar sits in it, doubles as the drag handle (`WindowDragArea`), and
  `WispWindowController.positionTrafficLights` grows the title bar container and centres the traffic lights on it
  (re-run on resize/key, since AppKit resets it). Nothing from SwiftUI is bridged into the title or toolbar
  (`sceneBridgingOptions = []`). Anything opens it at a page with
  `WispWindowNavigator.open(_:)` (closes the notch workspace + quick panel first). On launch with a
  permission missing, the window opens on Today, which leads with the `PermissionsChecklist`.
  Look: calm and tactile — `WispColor` surface tokens, hairlines, and **one button treatment**: the lit-edge pill
  (`Components/WispPill.swift`: `WispBevel` + `WispPillButtonStyle`, prominent = tinted with the accent plus a glossy sheen, springy squish on press via `WispMotion.bouncy`, otherwise
  neutral; lift on hover, dip on press, sizes follow `controlSize`). Use it instead of `.bordered` /
  `.borderedProminent` / the notch's glass button style in window pages (the glass style is white-on-dark and
  nearly invisible in light mode). Wisp colours are accents only (`.tint(WispColor.accentText)`).
  ⌥⌘1–8 switch sections (plain ⌘1–9 are the buddy rail's). Settings → General → Appearance
  (`WispAppearancePreference`: System / Light / Dark) sets the window's `NSAppearance` only; the notch, overlay and menu bar
  stay dark glass.
  Copy is kept to what earns its place: no explanatory paragraphs under controls whose label already says it.
- **Framework**: SwiftUI (macOS native) with AppKit bridging for the notch, cursor overlay, menu
  bar item and the Wisp window
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Claude** (when selected): Opus 5.5 by default, model/effort/web access chosen in Settings →
  Model (`AnthropicModelSettings`). Claude always thinks on 5.5-era models and signs each thinking
  block against the conversation before it, so its private blocks (`BuddyContentBlock.providerReplay`)
  are resent verbatim inside a tool loop, and the agent loop keeps the turn **append-only** for
  providers with `ModelCapabilities.requiresAppendOnlyHistoryWithinTurn` (the screenshot is resent on
  later passes — a cache read — instead of dropped). Replay blocks are stripped from the stored
  transcript (`withoutProviderReplayBlocks`) and never persisted. Web search/fetch run on Anthropic's
  side and are added only to requests that already carry tools (agent mode).
- **Chat / Vision**: a pluggable `ModelProvider`, chosen at runtime via
  `BuddyChatProviderSelection` and built by `ModelProviderFactory`. Default is local Ollama
  `qwen2.5vl:3b` at `http://localhost:11434` (NDJSON streaming); the cloud providers
  (`AnthropicProvider`, `OpenAIProvider`, `GeminiProvider`) are bring-your-own-key, picked in
  Settings → Model. A fourth cloud option, **Claude (your subscription)** (`ClaudeSubscriptionProvider`,
  `.claudeSubscription`, no API key), runs the user's own signed-in `claude` CLI once per turn instead of
  calling the API: `-p --input-format stream-json` with the system prompt replaced by Wisp's, **every CLI tool,
  MCP server, slash command and settings source switched off** (`--tools ""`, `--strict-mcp-config`,
  `--setting-sources ""`, `--no-session-persistence`; never `--bare`, which ignores the subscription login),
  the screenshot inline as a base64 image block on stdin, history flattened into the text, and tools via the
  same `[TOOL:]` text-tag convention as the local model, so the registry/confirmation boundary is unchanged.
  `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` are stripped from the child env so it can't bill a key. Wisp never
  reads or forwards the CLI's credentials (extracting a subscription login for a separate app isn't allowed);
  Settings → Model shows install/sign-in state via `claude auth status` (`ClaudeSubscriptionStatus`). ~4s per
  reply of CLI start-up; counts against subscription limits; labelled off-machine. The Info.plist `ChatProvider` key is now only a
  shipped-default hint — the live selection lives in `BuddyChatProviderSelection`.
- **On-device speech models (FluidAudio)**: the FluidAudio SwiftPM package (Apache-2.0,
  pinned 0.15.6 in `Package.resolved`) runs Parakeet and Kokoro as CoreML on the Apple
  Neural Engine, in-process. `FluidAudioSpeechModels` is their one owner: started from
  `applicationDidFinishLaunching` (`preloadConfiguredModelsInBackground`), it downloads the
  model files from HuggingFace on first use only (Parakeet to
  `~/Library/Application Support/FluidAudio/Models/`, Kokoro to `~/.cache/fluidaudio/Models/`),
  loads each **once**, warms it (the ANE compile is paid at launch, not on the first
  push-to-talk/reply), and publishes `speechRecognitionLoadState`/`speechSynthesisLoadState`
  (downloading % / ready / failed) for Settings → General → What's running
  (`ActiveStackReadout`, which names the Apple engine actually working until a model is ready).
  Parakeet loads first, then Kokoro, so first-run downloads/compiles don't compete. Launch never
  waits: until an engine is ready, if it failed, or (STT) for a language Parakeet lacks, the
  provider falls back to Apple's engine automatically and logs why. The engines are actors with
  a serial decode/synthesis chain, because FluidAudio's managers suspend inside a call and two
  overlapping calls could interleave. Memory, measured with `footprint` on an M3 Pro with
  Parakeet + the boosting model + Kokoro loaded: ~170 MB dirty in-process plus ~650 MB of
  Neural Engine model memory (listed as "neural, nofootprint", so Activity Monitor's figure
  understates it) and ~190 MB of clean mapped model files. The swiftc test suites stub the
  package (`Tests/AgentRuntimeIntegration/FluidAudioStub.swift`).
- **Speech-to-Text**: `ParakeetTranscriptionProvider` (Info.plist `VoiceTranscriptionProvider`
  = `fluidaudio`, the default; `apple` = Apple Speech only). Parakeet TDT 0.6B **v3** (25
  European languages, int8 encoder) is a batch model, so while the hotkey is held the session
  re-decodes everything captured so far every ~0.45s (backing off to 3× the last decode time on
  long holds) and feeds `onTranscriptUpdate` — that is what drives the live partials — and on
  release decodes the whole clip once more for the final transcript (measured ~120–300 ms
  release→final for 4–7 s of speech on an M3 Pro). Recording itself is unchanged: the mic starts
  on key press and the tap hands buffers to the session, which keeps them (lock-guarded, native
  rate, downmixed) and resamples to 16 kHz at decode time. The fallback is
  `AppleSpeechTranscriptionProvider` (Speech framework, on-device), so speech-recognition
  permission is still requested. Recognition **language** and a **custom dictionary** are
  user-configurable via `DictationSettingsStore` (Dictation tab): the language becomes
  Parakeet's language hint (or Apple's locale on the fallback). When the dictionary is
  non-empty, its words plus the built-in keyterms become FluidAudio **vocabulary boosting** on
  the final transcript (CTC keyword spotting + rescoring; a second ~100 MB model,
  `parakeet-ctc-110m`, loaded in the background the first time — a transcript never waits for
  it, it goes out unboosted until the model is ready), with FluidAudio's conservative
  short-vocabulary rescorer settings because the defaults rewrote ordinary words. On the Apple
  fallback the same terms are passed as `SFSpeechAudioBufferRecognitionRequest.contextualStrings`.
  Both are read on the main actor by `BuddyDictationManager` and threaded into
  `startStreamingSession`.
- **Text-to-Speech**: chosen once at launch by `BuddyTTSProviderFactory` from the Info.plist
  `VoiceTTSProvider` key, which ships as `fluid`: `KokoroSpeechSynthesisClient` — Kokoro 82M
  (FluidAudio's ANE 7-stage chain), voice `af_heart`, on-device and in-process (no server). The
  reply is split into sentences (`KokoroSpeechTextChunker`, ≤260 chars per piece since the model
  takes ≤510 phonemes); the first is synthesised and played through an `AVAudioPlayerNode`
  while the next is synthesised, so speech starts after one short synthesis (~70 ms for
  "Done.", ~300 ms to first audio for a typical sentence; ~22× real time). `stopPlayback()` (push-to-talk,
  a new reply, task cancellation) stops the node at once. It falls back to
  `AppleSpeechSynthesisClient` while Kokoro is loading, if it failed, or for the rest of a
  reply whose synthesis failed. `apple` selects that client outright (`AVSpeechSynthesizer`,
  the built-in macOS voices — no model memory at all). Setting it to `chatterbox` opts into
  `LocalChatterboxTTSClient`, a
  self-hosted Chatterbox server at `ChatterboxTTSServerURL` (default `http://localhost:8004`),
  which is also the only case where the keep-warm heartbeat and the Today page's health check
  ping it. There is no runtime TTS switch. Reply speech is now
  **opt-in per reply and gated by a voice/silent mode** (`VoiceOutputPreference`, default on).
  The notch is the primary answer surface: every reply renders there as text
  (`CompanionManager.currentReplyText`) plus an optional glance card. In **silent mode** no
  reply is spoken. In **voice mode** the model chooses whether/what to speak via a `[SAY: …]`
  tag (`SpokenLineParser`) — only that short line is synthesised, at the end of the turn; a
  reply with no tag stays silent. The old incremental sentence-streaming of the whole reply
  is retired. Confirmation/failure speech is unaffected.
- **Deployment target**: macOS 26 (raised from 14.2) so the notch HUD can use real SwiftUI
  **Liquid Glass** (`.glassEffect` / `GlassEffectContainer`), dark-tinted for legibility
  (`WispColor.OnGlass.tint`, `View.wispNotchGlassSurface(in:)`).
- **Design system**: the Wisp visual identity ("quiet intelligence × organic × native macOS")
  lives in `DesignSystem/` — `WispColor` (sage/ink/cloud palette; a **sage** brand accent, a
  **lavender** AI-activity accent, muted-terracotta errors), `WispFont`, `WispSpacing`,
  `WispRadius`, `WispShadow`, `WispGradient` (the single signature sage→mist→lavender gradient,
  used sparingly) and `WispMotion` (named curves + reduce-motion). Colours come in three layers:
  raw brand (fixed), **adaptive** semantic tokens (`WispColor.background` etc., resolve light/dark
  live via a dynamic `NSColor`), and a fixed **on-glass** set (`WispColor.OnGlass.*`) for the
  always-dark surfaces, plus a fixed **island** set (`WispColor.Island.*`: true black, white/grey
  text, flat white-alpha control fills, a white prominent capsule) for the notch. The legacy `DS.*` API is a thin facade that **forwards to these tokens**,
  so `DS.Colors.background` etc. are now adaptive and the whole app reskins from one place.
  Reusable components live in `Components/` (`WispGlassPanel`/`WispGlassButtonStyle`/`WispGlassIcon`,
  `WispMark`, `WispIcon`). **Do not reintroduce hardcoded hex** — reference the
  tokens.
- **Themes + glass** (`DesignSystem/WispTheme*.swift`): six `WispTheme`s (Sage default, Candy, Sunset, Mint, Berry Night, Mono; pure
  value types, hex only in their definitions) chosen in Settings → General → Appearance (`AppearanceSettingsCard`, `WispThemePicker`).
  `WispThemeStore` (UserDefaults, with a lock-guarded cache so the dynamic `NSColor` providers can read it off the main actor) is the one
  source of truth; `WispColor` accent/lavender/gradient tokens resolve through the current theme, so call sites reskin without edits and
  the window root rebuilds on `.wispThemeDidChange`. The window gets a soft blurred-gradient backdrop (`WispThemeBackdrop`, drifts only
  while the window is active and Reduce Motion is off); cards, the top bar and pills sit on `.glassEffect` in `GlassEffectContainer`.
  `WispThemeContrast` (pure) checks text contrast for every theme in light and dark (`Tests/WispTheme`). **The notch island stays solid
  black unless "Tint the island with my theme" (`WispThemeStore.tintsIsland`, off by default) is on**; then the island surface/rim (and the
  opt-in Liquid Glass island) take the theme. **Playful** (`isPlayful`, default on, always yields to Reduce Motion via
  `allowsPlayfulMotion`) gates the backdrop drift, pill squish (`WispMotion.bouncy`), buddy bounce and checklist burst.
- **Light/dark**: the **Wisp window follows the system appearance** (its `WispColor` tokens resolve
  light or dark). The **notch HUD, on-screen overlay, and menu-bar panel stay a dark glass
  material in every appearance** — they pin `.environment(\.colorScheme, .dark)` so their adaptive
  tokens resolve dark, keeping near-white text legible over any wallpaper. `wispGlassSurface` /
  `wispGlassCard` use an **adaptive** glass tint (`WispColor.glassTint` / `glassCardTint`);
  `wispNotchGlassSurface` stays fixed dark. **The notch island is solid black by default**, like
  Apple's Dynamic Island, so on a notched Mac it is indistinguishable from the camera cutout:
  `wispNotchIslandSurface(in:style:)` draws `WispColor.Island.surface`, text and chips in
  `NotchHUDView`/`NotchWorkspaceView` use `WispColor.Island.*` (no sage tint, no hairlines), and
  buttons use `WispIslandButtonStyle`. Colour on the island comes from content and from the mark +
  lavender rim state light only. Liquid Glass is opt-in via `NotchIslandStylePreference` (notch
  settings → General → Island), which also brings back the border and the rim's specular highlight
  (`wispLiquidRim(showsSpecularHighlight:)`).
- **The Wisp mark**: a flowing liquid-ribbon logo (`Components/WispMark.swift`), filled with the
  signature gradient, with subtle per-state motion (idle/listening/thinking/acting/success/error),
  a static mode, and a paused `TimelineView` clock while at rest. It replaced the old rotated
  `Triangle` glyph in the notch. The app icon (`Assets.xcassets/AppIcon.appiconset`) is the same ribbon on a
  dark squircle, and the menu bar status icon (a template image drawn from `WispRibbonShape`), the
  text composer and sidebar status use the mark too; the README banner, icon and
  screenshots live in `docs/assets/`. Icons are the single-stroke **Liquid Icon System**
  (`Components/WispIcon.swift`): bespoke glyphs for the high-value actions (message, search, mic,
  send, voice, files, calendar, gear-free settings) with an SF-Symbol fallback for the long tail.
- **Dynamic Island state**: `DynamicIsland/WispIslandState.swift` is a 9-state vocabulary
  (idle/listening/thinking/processing/preview/confirmation/executing/responding/success/error)
  **derived**, not a replacement, from existing signals. `CompanionManager.islandState` projects
  it from `voiceState` + `pendingToolConfirmation` + whether an answer is lingering, plus a
  transient `islandFlash` (`flashIsland(_:)`) for success/error moments. It drives the notch
  mark's motion, the state dot, and the label. The tool-confirmation card
  (`ToolConfirmationView`) is an island-surface card (solid black, or Liquid Glass when chosen
  for the island) hung by its top edge just below the notch (`OverlayContentView.confirmationCardTopInset`
  — it used to be centred at a fixed y and grew up behind the notch), still presented via the
  existing overlay plumbing (so the prompt is seen even when the cursor is hidden). Its countdown is
  derived from the expiry in a `TimelineView`, never a `Timer`/`@State` in the view (overlay re-renders
  rebuilt those and the number jumped); it animates in and out (`WispMotion.island`, keyed on the
  confirmation id); and for VoiceOver it is a modal group, the overlay window is titled "Wisp needs your
  OK" while a card is up, and its appearance is announced (`announceConfirmationForVoiceOver`). On a
  **notched Mac the island wraps the physical notch** rather than sitting behind it: at idle
  nothing shows (`NotchHUDView.islandIsVisible` is false — the notch is untouched); when Wisp is
  active a small status surface with **flush top / rounded bottom** corners
  (`notchSurfaceShape`) hugs the cutout, its content flanking the notch left and right with the
  notch's own width reserved between them (`notchWrapContent`) so nothing is occluded by the
  camera — the mark's motion plus the indicator (waveform listening / pulsing dots thinking)
  carry the state. A reply **auto-presents as a compact message card** that drops below the notch
  (`messageContent`, content inset by `notchContentTopInset`; `viewModel.isFullPanel == false`),
  and a deliberate **hover upgrades it to the full panel** (header with the state label, live activity,
  Chat/Manage footer — no waveform card, no skills/routines chips; `isFullPanel == true`) — the surface morphs and the whole thing collapses back to the bare
  notch when done. An answer left folded away and untouched for 20s is cleared
  (`NotchWindowController.expireLingeringAnswerIfStale`; a running timer card is kept), so an old
  reply doesn't linger in the island or reappear on a later hover — History and the chat keep it. Live speech is captured in `CompanionManager.liveTranscript` (fed from the
  dictation partial-transcript callbacks that used to be discarded, throttled to ~11 Hz); it
  drives the non-notch fallback pill's one-line preview and is available for the wrap. The
  non-notch fallback keeps the old centred floating pill (`floatingPillContent`). The key moments
  also play short **sound cues** (`WispSoundPlayer` / `WispSoundPreference`, built-in system
  sounds, default on, muted from the notch header's bell toggle): listening onset, thinking (turn
  start), reply landed, and success/error (from `flashIsland`). The notch glass is
  **non-interactive** (`wispNotchGlassSurface`) so the surface animates cheaply.
- **Chat in the notch** (HeyClicky-style workspace): the quick panel's footer **Chat** button
  opens `NotchWorkspaceView` (760×480) hanging from the notch (the header gear and the footer's
  **Open Wisp** open the Wisp window instead) —
  `NotchViewModel.workspacePage` + `requestWorkspacePage`. Opening it is a click, not a hover, so
  `NotchWindowController.setWorkspacePage` may resize the window (grow before the morph, shrink
  0.4s after the collapse) without the old resize-on-hover feedback loop; the SwiftUI root fills
  `viewModel.windowSize`. While open, the `NotchPanel` may become key (`allowsBecomingKey`) —
  non-activating, so typing works while the user's app stays active — and closing orders the
  panel out/in to hand key focus back. It stays open while the pointer is over it, a text field is
  being edited, a turn is listening, or a button is held; otherwise closes after 0.6s outside, on
  Esc (`NotchPanel.cancelOperation`), the ✕, or `.wispCloseNotchWorkspace`. `.wispDismissPanel`
  (push-to-talk start) does not close it, and reply/card/morning-banner auto-present is skipped while
  it's open (the chat shows the answer). The workspace has no settings pages any more — its
  Settings button opens the window's Settings. The quick panel's middle sections scroll within the fixed window so its
  footer stays reachable. `nativeTooltip`'s overlay view returns nil from `hitTest` — before, it
  swallowed clicks on the button beneath it.
- **Buddies page = messenger** (`WispWindow/BuddiesPage.swift` + `WispWindow/Buddies/`): a rail of living
  characters (`BuddyRailView`: mood word, unread dot, pin, context menu, + New), the selected buddy's own chat in
  its colour (`BuddyChatView`: plain header, mission row, the user's bubble in the buddy's colour, typing dots, handoff
  rows for `.delegated` exchanges, hover actions under an answer — copy, run again, hand off to another buddy via
  `BuddyStore.startDelegatedRun` — and a composer with a paperclip + drag-and-drop files),
  and a toggleable inspector (`BuddyInspectorView`, icon tabs Automation / Files / Memory / Tools / About — reuses
  `BuddyScheduleEditor`/`BuddyToolAccessEditor`/`BuddyModelEditor`). Summoning is `BuddyCreationView`: a grid of
  `BuddySpecialty` cards, then name/colour/mission/schedule. ⌘1–9 jump to a buddy, ⌘N summons one. The notch chat still uses `BuddyDetailView` and
  `NewBuddyForm`. **Characters** (`Buddies/BuddyCharacter.swift`): one `Canvas` drawn from a clock — breathing,
  blink (staggered per colour), eyes that follow the pointer (`looksAtPointer`, via the character's screen frame and
  `NSEvent.mouseLocation`), squish on `bounceTrigger`/hover, and a `BuddyMood` (idle/working/happy/sleepy/oops/waiting,
  derived by the pure `BuddyMoodPolicy` from the latest run) that changes eyes and mouth, plus a thin turning
  ring while working and an amber badge when it needs the user's ok. The look is deliberately restrained: one hue
  with a small tonal range, a faint highlight, a ground shadow — no glow, sparkle or confetti. `Liveliness` is the cost dial (`.still` = one frame, `.working`, `.full`); Reduce Motion
  freezes it. `BuddyAvatar` is the compact form (still unless working). The buddy palette (`BuddyAppearance`) is
  eight calm, slightly warm hues; a buddy's colour is an accent used once per surface (the user's bubble, a
  selected state, an icon), never a fill gradient.
  **Buttons** share one treatment (`BuddyBevel` + `BuddyPillButtonStyle` in `WispWindow/Buddies/BuddyHubComponents.swift`):
  a soft fill with faint light from above, a thin lit top edge and a hairline outline; prominent = tinted with the
  buddy's colour, otherwise neutral; a touch of lift on hover and a dip on press, nothing more. Tabs and segments
  use the same bevel when selected, and the Composio app list (`ComposioAppsView`) uses the same pills. **Specialties** (`Buddies/BuddySpecialty.swift`, `WispBuddy.specialty`, optional): colour, tool
  groups, persona line (`BuddyThreadPolicy.systemPromptAddendum(specialtyLine:)`), starter jobs. **Files**
  (`Buddies/BuddyFiles.swift`): attachments are copied to `~/Library/Application Support/Wisp/buddy-files/<id>/`
  (`BuddyFileLibrary`), documents are read with `BrainTextExtractor` and fenced as data in the message
  (`BuddyAttachmentPolicy`), pictures are downscaled and sent as images (`BackgroundTaskLauncher.start(images:)`),
  the thread shows only the user's words plus file chips (`BuddyThreadExchange.attachmentNames`), and a buddy with a
  library gets the run-only `read_my_file` tool. `BuddyStore.sendMessage(_:attachmentFileURLs:toBuddyWithID:)` is the
  async entry point. Tested by `Tests/AgentRuntimeIntegration/BuddyRedesignTests.swift`.
- **Buddy personalities, starter buddies, playful touches** (`Buddies/`): `BuddyPersonality` presets (Coach, Chill, Hype, Deadpan,
  Teacher) set the persona line, reply length/tone (`BuddyReplyStyle`, folded into the system-prompt addendum) and a voice profile
  (Kokoro voice id + rate; not yet audible, the engine loads one voice). Chosen when summoning (`BuddyPersonalityPicker`), editable later.
  `StarterBuddies` creates a Planner (Canvas + checklist), a Briefer (morning brief, meeting prep) and a Focus buddy (study blocks) once, from
  first-run setup (`BuddyStore.ensureStarterBuddies`); fixed ids so templates and migration can name them, and deleting one sticks.
  `BuddyGreetingPolicy` picks the day's buddy (stable per day, Briefer favoured) for Today's greeting; `ChecklistStreak` remembers only day
  keys of fully finished checklists; `PlayfulCelebration` is the squish/burst, shown only when Playful is on. The working buddy's character
  sits in the notch's left flank and its face marks each NEW result.
- **Automations** (`Automations/`, `WispWindow/Automations/`, `docs/fun-glass-buddies-automations-plan.md`, `docs/fun-glass-contracts.md`):
  one model replaces Routines, buddy jobs and the Jobs page. `Automation` = **Trigger → Source → Action → Output → Notify**, owned by a buddy.
  Triggers: `schedule` (once/daily/weekdays/weekly/monthly, `AutomationSchedule`: next run, DST, a missed slot runs once), `event` (new Canvas
  item, meeting starting in N minutes, screen text appears via the watchers, file dropped in a folder) or `manual` (button, notch chip, routine
  digit). Sources: nothing, today's calendar, Canvas deadlines, Reminders, clipboard, screen text, folder files. Actions: ask the buddy,
  sync Canvas, build the daily checklist, propose study blocks (the last three are views onto `JobsEngine`, which keeps its own timers; the
  engine never schedules them twice). Outputs: notch card, Reminders checklist, Calendar block, notification, buddy-thread message, spoken line.
  **Three setup paths, one editable draft card** (`AutomationDraftCardView`, chips for trigger/source/output/buddy/notify, Test run, Save):
  (1) **Say it** — `AutomationDraftParser` is deterministic first (the 3B model is weak at this); only when unsure may a model fill the card,
  and it never runs anything; (2) **Template gallery** (`AutomationTemplates`: Morning brief, Canvas deadlines, Daily checklist, Weekly review,
  Meeting prep, Focus block, Study plan, Screen watch); (3) **Save as automation** on a History answer. `AutomationStore` keeps
  `automations.json` and `automation-runs.json` (run records: status, capped result text, failure reason, 30 days; 0600) under
  `~/Library/Application Support/Wisp/`; failures surface in Today's "Needs you", next runs in a Today tile. `AutomationEngine` (30s clock,
  one run per automation at a time, injected `AutomationEngineDependencies`; real adapters in `AutomationLiveWiring`, run entry
  `CompanionManager.startAutomationRun`). **Safety**: a scheduled/event/test run is unattended and gets only tools that never prompt
  (`AutomationToolPolicy`; outward-facing tools are absent, not gated) and never auto-approves; `calendarBlock` always asks; source data is
  fenced as DATA; a cloud-model buddy gets private sources only after the card showed "this leaves your Mac"
  (`acknowledgedSourceLeavesMac`); a Test run reads but writes nothing. **Migration** (`AutomationMigration` pure + `AutomationMigrationRunner`)
  reads Routines, buddy jobs and the Jobs Canvas/checklist once into automations by `legacyOrigin` (incremental, old stores untouched, a
  deleted automation does not return); a migrated routine's digit still fires through `RoutineStore`.
- **Quick add and first run**: `AutomationQuickAddRouter` / `AutomationQuickAddPlanner` (`QuickAdd/`) are asked first by
  `sendTranscriptToClaudeWithScreenshot` (voice, composer and Today's ask bar alike): "remind me…", "every…", "when…" open the draft card
  (`WispWindowRouter.presentAutomationDraft`) instead of a model turn; biased toward not matching, "remind me in 10 minutes"/timers stay with
  `FastCommandRouter`. `FirstRunSetupFlow` (`FirstRun/`, once, flag in `WispFirstRunState`, "Run setup again" in Settings → General) is four
  skippable steps over Today: theme, Planner personality, Canvas link (optional), up to three templates; nothing is on until tapped. The menu
  bar gains New Automation…; nothing else.
- **Buddies** (HeyClicky's "Clickys"): named, coloured agents that each own one job, listed under
  BUDDIES in the notch chat's sidebar (+ to summon). `BuddyStore` (`~/Library/Application
  Support/Wisp/buddies.json`) holds identity (name from `BuddyNameGenerator` — subject + role word,
  no model call; colour from `BuddyAppearance`, least-used first), the job, a `BuddySchedule`
  (once / daily / weekly; `inferred(fromInstruction:)` pre-fills the form from "every morning…"),
  and the ids of its runs. Each buddy also has **one continuous thread** (`BuddyThreadStore`,
  `~/Library/Application Support/Wisp/buddy-threads.json`, text only): every run — its job, or a
  message the user typed in the buddy's thread (`BuddyStore.sendMessage`) — is an exchange
  (question + answer). The last 6 answered exchanges (`BuddyThreadPolicy`, answers clipped to 1500
  chars, machine tags stripped) go in front of the model as `conversationHistory`, and the system
  prompt gets a persona addendum, so a run says what changed since last time and a reply stays in
  context; 100 exchanges are kept. **Per-buddy memory** (`BuddyMemoryStore`, `~/Library/Application Support/Wisp/buddy-memory/<id>.md`, same
  bullet format as memory.md): short notes the buddy saves with its own `remember_for_this_buddy` /
  `forget_for_this_buddy` tools (`BuddyRunToolkitBuilder`, bound to that buddy, no confirmation — they only
  touch its own file), rendered into its system prompt (≤800 chars, newest first, framed as data not
  instructions since a model that read a web page wrote them), listed with a Forget button on its page.
  Kept out of the Brain on purpose (works with the brain off, never enters the main assistant's retrieval).
**Per-buddy tool allow-list** (`WispBuddy.toolAccess: BuddyToolAccess?`, nil = every tool, so existing
  buddies are unchanged): limited to *groups* — `BuddyToolGroup` (Browser, Screen, Messages & Contacts, Reminders,
  Shortcuts, Coding agent, Brain, Your memory) plus one `mcp:<server>` group per connected server — because the tool
  list isn't fixed and a stored list of tool names would go stale or let a newly installed tool through. Anything
  not in an allowed group is refused to a limited buddy, including tools in no group; `get_current_time` and
  `load_skill` are always kept; `do_in_background` is never available to a buddy (it would start a task outside the
  buddy's thread, model and limits). `BuddyToolAccessPolicy.isPermitted` is the one rule; it is enforced by
  `AgentRunToolkit.permitsRegistryTool` *before* tool ranking (`AgentToolRegistry.definitions(forRequest:isToolPermitted:)`,
  so a limited buddy still gets a full set of relevant tools) and again by name at call time (so a tool that
  registers after the run began is held to it too). Edited with `BuddyToolAccessEditor` ("Tools · Browser, Screen"
  on the page and in the new-buddy form); Brain/Your memory show as unavailable for a cloud-model buddy.
    **Per-buddy app access** (`BuddyToolAccess.allowedAppSlugs`, nil = every connected app): which connected Composio
  apps (toolkit slugs) a limited buddy may use. Enforced at call time, not just hidden: `AgentRunToolkit.refusalForCall`
  (checked in `AgentTurnRunner.runToolWithTimeout` after the name check) runs `BuddyToolAccessPolicy.appRefusalReason`,
  which unwraps Composio's execute gateway into the apps its tools belong to and refuses any not in the list, refuses a
  call it can't read, and refuses Composio's shell/workbench tools (they could reach any app). `settingApp` drops the
  limit again when every connected app is allowed, so an app connected later is allowed too. UI: `BuddyToolsView`
  (Everything / Choose; app rows with real logos and switches; Wisp's own abilities; **Add app** sheet that asks for the
  Composio key if needed and embeds `ComposioAppsView`), used by the inspector's Tools tab and the summon flow; the
  notch still uses `BuddyToolAccessEditor`. Specialties start with sensible apps (`BuddySpecialty.suggestedAppSlugs`:
  Coder → GitHub/Linear, Inbox → Gmail/Outlook/Slack, Planner → Calendar/Todoist/Asana, Writer → Docs/Notion/Gmail).
  **Per-buddy model** (`WispBuddy.modelChoice: BuddyModelChoice?`, nil = follow Wisp): local, a Claude model,
  GPT or Gemini, built by `ModelProviderFactory.make(_ choice:)`; picked with `BuddyModelEditor` (page + new
  form), which says what leaves the Mac. A buddy whose model is off this machine (`deployment.sendsDataOffThisMachine`)
  gets `BuddyRunToolPolicy.privateKnowledgeToolNames` removed — the brain tools plus `remember`/`forget` — both
  from the tool list and refused by name (`AgentRunToolkit`), and bypasses `ModelAccessGate` (no resident model to
  protect), so cloud buddies run in parallel with each other and with a live local turn. Capacity is
  `BackgroundTaskCapacityPolicy`: 2 local, 4 cloud, counted separately in `BackgroundTaskLauncher`.
  **Delegation** (`ask_buddy`, `Buddies/BuddyDelegation.swift`): a buddy can ask a peer for help; the peer answers in
  *its own* thread (origin `.delegated`, `BuddyThreadExchange.requesterName`, shown with a "From <buddy>" label and
  fed to the model as "<name> asked you: …"; the run's prompt says it's a peer's request, not the user's) and the
  answer returns to the caller as the tool result. `BuddyDelegationService` (injectable, so the flow is tested without
  the app) resolves the peer by name (ambiguous → asks which, never guesses; can't ask itself), starts the run via
  `BuddyStore.startDelegatedRun`, and polls the task until it ends (5-minute cap, then stops the peer). A busy peer or a
  full queue is reported back at once instead of waited on, so two buddies can't deadlock the queue. **Crossing a
  model boundary asks first** — different `providerKind` between caller and target (local↔cloud either way, or two
  different cloud providers): `BuddyDelegationPolicy.requiresApproval`, the card (`ToolConfirmationCardBuilder.askBuddyCard`)
  names both buddies and models, the message and where it goes, and `ask_buddy` is on `ToolCallSafety`'s always-ask
  list so session auto-approve doesn't skip it. Same-model delegation doesn't ask. **No chains**: a run started by a
  delegation isn't given the tool. It is a run-only tool (`AgentRunTool`, so no registry entry) in the `.delegation`
  tool group ("Other buddies"), and only offered when there is at least one peer and the buddy's allow-list permits it.
  **List experience** (modeled on Rakazo's bot list): buddies are ordered pinned first, then by latest
  activity; one that finishes a run while you aren't looking is **unread** (dot in both lists, counted in the
  Buddies sidebar badge with working buddies) until its thread is opened. Right-click (window) or ⋯ (page):
  Run now/Stop, Pin, Mark read/unread, **Notify when finished** (per buddy; the notification names the buddy,
  and runs another buddy asked for never notify), Duplicate (setup only — no thread or notes), Clear
  conversation (thread restarts, notes and History stay), Delete. The job is editable in place.
  A buddy has no loop of its own: each run is an ordinary background task
  via `CompanionManager.startBuddyRun` → `BackgroundTaskLauncher.start(title: "Buddy · <name>")`,
  so it queues behind the model like any background work and its record lives in
  `AgentTaskRegistry`/History. The schedule is checked every minute while Wisp runs
  (`runDueBuddies`); a missed slot runs once on the next check, and a run that can't start (the
  2-task limit) keeps its due date and retries. The thread (`BuddyDetailView`) shows the job card,
  then each run with a monospaced status chip, "5m 10s · 10:39 PM", collapsible progress
  messages and the answer; `BuddyAvatar` is a cloud with "^ ^" eyes that bobs (eyes open) while
  working. Stored answers are shown through `AnswerDisplayText.cleaned`, which strips Wisp's
  machine tags (`[POINT:…]`, `[SAY:…]`, trailing `[CARD:…]`) that history keeps raw.
- **Morning notch & quiet mode** (modeled on HeyClicky): once a day, the first time the user is
  at the Mac (5am–5pm, input within 2 min), `MorningBriefingController` builds suggestions with
  **no model call** (`MorningSuggestionBuilder`: today's remaining meetings / due reminders — only
  if access was already granted, never prompts — then pinned and recently-run routines, cap 7) and
  the notch drops a compact banner ("I can do 5 things for you today", Dismiss / Show me). Show me
  switches to the full panel, whose **TODAY** section runs each suggestion in one click; ignored,
  the banner tucks into a ✦ count in the right flank. **Quiet mode** (`QuietModeMonitor`, 4s poll
  with hysteresis): another process capturing the mic (CoreAudio per-process
  `kAudioProcessPropertyIsRunningInput`, own PID and always-listening system services like
  `com.apple.CoreSpeech` excluded) or any camera running → no morning banner, and finished
  background tasks post **no** notification. Focus/DND is deliberately not detected (needs Full
  Disk Access or a provisioned entitlement). Finished background tasks go to `FinishedWorkInbox`
  → an "N new" flank badge and a **NEW** section in the full panel, marked seen when the panel
  closes. Both switches live in the Agent tab's Announcements card (`AnnouncementPreferences`),
  which also has a "Show now" preview.
- **Jobs** (`Jobs/`, `docs/jobs-revamp-plan.md`; now the engine behind the Canvas page and the Canvas/checklist automations; a job is Source -> Rule -> Output -> Cadence, quiet unless something changed):
  **Job 1, Canvas calendar manager**: the user pastes their Canvas calendar feed (`.ics`) URL once on the Canvas page (inside Buddies). The URL is a
  secret: it lives only in the Keychain (`CanvasFeedKeychainStore`, service `com.wisp.canvas-feed`), is validated on save (https only,
  `webcal://` rewritten, no userinfo), is never put in UserDefaults, logs, History, errors or notifications, and the UI shows only a
  masked host. `JobsEngine` (`@MainActor` singleton, `start()` beside `MorningBriefingController.shared.start()`) fetches it on launch
  and hourly with a plain cookie-less GET (a new **opt-in network use**: off until a URL is saved, with its own switch, not
  `GlanceCardDataPreference`), `CanvasFeedParser` -> `CanvasItem`s, `CanvasSyncPlanner.diff` against the 0600 snapshot
  `~/Library/Application Support/Wisp/jobs-canvas-snapshot.json` (no feed URL in it), then `WispCalendarWriter` upserts events into a
  dedicated **"Wisp"** EventKit calendar keyed by Canvas UID, so re-running changes nothing. Writes never touch another calendar.
  `StudyBlockPlanner` proposes study blocks in free gaps (busy time from every other calendar); they are **never auto-written** — one
  confirmation card for the batch (`ToolConfirmationCardBuilder`), and `JobsToolNames.applyStudyBlocks` is on
  `ToolCallSafety.alwaysAskBareToolNames`, so session auto-approve can't skip it. **Job 2, daily checklist**: `DayChecklistBuilder`
  (pure) builds the day from Canvas due dates + calendar events + approved study blocks, rolling unfinished items over;
  `WispTodayReminders` mirrors it into the Reminders list **"Wisp Today"** and reads completion back. The notch shows
  `DailyChecklistView` (tickable) in place of the generic morning-suggestions banner when `JobsEngine.shared.hasChecklist`
  (`MorningBriefing` defers), and `CanvasDiffCardView` summarises a non-empty diff. Notifications fire only when the diff is non-empty;
  quiet mode suppresses notifications only, sync still runs. **No model call anywhere on the sync path.** Tested by
  `Tests/CanvasSync`, `Tests/DayChecklist`, `Tests/JobsEngine`.
- **Glance cards**: a visual answer surface in the notch's expanded panel, parsed from one
  `[CARD:{...json...}]` tag at the end of the reply (same structured-text mechanism as
  `[POINT:]`/`[BOX:]`/`[TOOL:]` — the local model can't do native structured output; the tag is
  stripped from spoken text). The model emits a small payload naming a card *kind*, and Wisp
  owns the look and data (`GlanceCardParser` → `GlanceCardRequest` → `ResolvedGlanceCard`,
  drawn by a per-kind template). Kinds: `generic` (model-supplied `header`/`list`/`keyValue`/
  `stats` blocks, tone `good`/`bad`/`neutral` → `DS.Colors`, 3-block cap, SF Symbol allowlist,
  network-free), `weather` (the model sends only a place name → Open-Meteo, no API key, Apple
  Weather layout), `calendar` (EventKit, on-device), `music`/now-playing (AppleScript to
  Music/Spotify, on-device, best-effort), `places` (the model sends only a query like
  "coffee" → CoreLocation for the user's position + MapKit `MKLocalSearch`, no API key, a
  Maps-style tappable results list that opens a place in Apple Maps), `reminders` (EventKit
  `EKReminder`, on-device; optional `list` + `filter` today/overdue/all → incomplete reminders
  with list-colour dots, overdue in the bad tone, rows open Reminders.app; requests full
  Reminders access on first use), `timer` (`seconds` + optional `label` → a live countdown
  whose `TimelineView` clock ticks per second and pauses off-screen, with Cancel; the timer
  itself lives in `WispTimerStore` so it survives the card being replaced/dismissed — its
  `UNUserNotification` is scheduled at start and it calls `flashIsland(.success)`, which plays
  the success cue, on finish; "set a timer for N minutes" also skips the model via
  `FastCommandRouter`/`TimerCommandParser`, returning a card request resolved on the same
  path), and `source`
  (user-configured HTTPS endpoints in `~/.wisp/sources.json`, mapped to generic blocks).
  Network kinds are gated by
  `GlanceCardDataPreference` (default on) and labelled "Live · source"; on-device kinds are
  gated only by their macOS permission (`places` is both — network-gated *and* it requests
  Location permission on first use). Managed in the Wisp window's **Connections → Sources** page. Adding an
  app = one data provider + one template.
- **Screen Capture**: ScreenCaptureKit, multi-monitor, downscaled to 896px
- **Element Pointing**: the model embeds `[POINT:x,y:label:screenN]` tags; `CompanionManager`
  parses them and turns each into a `.marker` `ScreenAnnotation` (a point in the screenshot's
  pixel space) applied to the correct monitor. There is no flying cursor — the marker is a
  pulsing target ring drawn by the same annotation layer as boxes and arrows, alongside them.
  **Accessibility-tree pointing** (native apps): on a screen-referring turn, concurrently with
  the capture, `AccessibilityElementSnapshotter` walks the frontmost app's menu bar + focused
  window AX tree (skips Wisp itself and Chrome/Safari, which the DOM path handles; bounded to
  ~150 elements / 30 levels / ~300ms, 0.1s per-call AX timeout, detached off the main actor;
  never reads secure-field values) and assigns ids `a1, a2…`. `AccessibilityElementSnapshot.promptText()`
  (one short line per element + the id-tag instruction) rides as an extra text block on the
  **user message**, not the system prompt, so the prefix cache is unaffected; it is stripped
  from the stored transcript because ids are per-turn. The model can then write
  `[POINT:a12:label]` (and `[BOX|HIGHLIGHT|ARROW:a12:label]`); `CompanionManager.resolveAccessibilityElementRegion`
  converts the element's AX frame (top-left global) → AppKit → the right display's
  screenshot-pixel space via `AccessibilityElementGeometry`, so it shares `applyAnnotations`'
  per-display scale with coordinate tags. Unknown ids draw nothing; coordinate tags still work.
  Note: annotation regexes must write the separator class as `[\s:]`, never `[:\s]` — ICU reads
  `[:`…`:]` as a POSIX class and the pattern silently fails to compile.
  **On-device OCR pointing** (any pixels — terminals, images, canvases, remote desktops): every
  capture in `CompanionScreenCaptureUtility` immediately starts Vision text recognition on the
  uncompressed 896px frame (`ScreenTextRecognizer`, Swift `RecognizeTextRequest`, `.accurate`
  with a 5px minimum text height, detached off the main actor), cached per display keyed on the
  exact bytes sent — the same identity `ScreenshotReuseCache` preserves, so an unchanged screen is
  never re-recognised. The push-to-talk capture runs during speech, so recognition (~170ms warm on
  an M3 Pro, ~300ms+ cold) usually finishes before the transcript; a screen-referring turn waits at
  most `turnWaitBudgetSeconds` (0.4s) and otherwise leaves it running into the cache.
  `ScreenTextSnapshot` (pure) confidence-filters (≥0.35), orders lines into reading order, caps them
  (60 lines / 2500 chars, 120 per line) and assigns ids `t1, t2…`; its `promptText()`
  (`t3 412,88,520,104 "Save changes"` + one id-tag line) is **joined into the same screen-context
  block as the Accessibility list** (`ScreenTextSnapshot.screenContextPromptText`), so it rides the
  user message and is stripped from history exactly like `a` ids. `[POINT:t7:label]` and
  `[BOX|HIGHLIGHT|ARROW:t7:label]` use the same id regexes (`[aAtT]\d+`) and one resolver,
  `CompanionManager.resolveScreenElementRegion` (in `ScreenTextRecognizer.swift`), which routes `t`
  ids to the OCR line box (already in screenshot pixels) and `a` ids to the AX path. The read-only
  `read_screen_text` agent tool (`.reading(.localMachine)`, general scope) returns the plain OCR text
  of the current screen (150 lines / 4000 chars).
- **Ask about a part** (menu bar → **Ask About a Part…**): `ScreenRegionPickerController` (`ScreenRegionPicker.swift`) shows a dimmed
  drag-to-select panel on the pointer's screen (Esc cancels; the one Wisp overlay that takes the mouse, and only while up). The chosen
  `FocusedScreenRegion` (`ScreenRegionFocus.swift`, pure — clamped to the display, ≥24pt a side, AppKit bottom-left → screenshot
  top-left pixels) is highlighted on screen, the text composer opens, and `CompanionManager.focusedScreenRegion` rides on every question
  until a fresh composer opens (`openTextComposer(keepingFocusedScreenRegion:)` — only a new selection and the notch's Follow up keep it),
  so follow-ups ("why?", "next step") stay about that part. A turn with a region always attaches the screenshot, adds a native-resolution
  close-up (`CompanionScreenCaptureUtility.captureCloseUpAsJPEG`, ≤1400px) as the last image, and joins `FocusedScreenRegion.promptText`
  to the per-turn context block (stripped from history like the `a`/`t` ids). **⌃⌥A** (Talk chord held, then A — layered on the hold like a
  routine digit; `askAboutPartShortcutPublisher`) opens the same picker. **Click what Wisp drew**: `AnnotationClickRouter` watches pointer
  movement (global mouse-moved monitor while the overlay is click-through, local once it isn't) and flips the overlay to accept the mouse
  only while the pointer is over a clickable note, circle or box (`AnnotationClickTarget`, pure — a note's size is estimated from its text,
  mirroring `ScreenAnnotationLayer.noteView`); the click is consumed by a local monitor, the clicked rect (padded 14pt) becomes the focused
  region, the rest of the explanation stays on screen, and the composer opens. It stands aside while a confirmation card owns the overlay.
  Handwritten notes dwell 120s (other annotations ~4s) so there is time to read and click them. A note's clickable box is its *measured* text
  size (`AnnotationClickTarget.measuredNoteSize`, same font/padding constants as the layer). Annotations are pinned to screen positions, so a
  scroll in another app (global `scrollWheel` monitor) drops them and the selected part (not during a guided walkthrough). A tap of the Talk
  chord is a press shorter than `BuddyPushToTalkShortcut.tapMaxDuration` (0.30s — at 0.22 a tap measured at 0.224s was heard as a hold with
  nothing said, so the composer silently didn't open). Because any fixed cutoff can still be missed by a slow first press, **a hold under 1s that recognises no speech is also read as a tap** (`BuddyDictationManager.onKeyboardShortcutHoldEndedWithoutSpeech` → `openComposerAfterEmptyShortHold`), so a tap is never silently lost. The window's status pill, History's "Asking …" step and the Settings → General stack
  The composer shows an **"About: selected part ✕"** chip while a selection is active (✕ drops just the selection and its highlight,
  `clearFocusedScreenRegionKeepingDrawings`). The **A in ⌃⌥A is rebindable** (`ShortcutBindingStore.askAboutPartKey`, Settings → Shortcuts → Ask
  about a part, any letter; pushed to `GlobalPushToTalkShortcutMonitor.askAboutPartKeyCode`). **Esc clears Wisp's drawings and the selection**
  (seen by the same CGEvent tap — `escapeKeyPublisher`, never consumed; ignored while the composer or region picker is up, where Esc dismisses
  them; an `NSEvent` global key monitor never saw it). Notes the model stacked on each other or on a circle/box are nudged apart when applied
  (`AnnotationNoteLayout`, pure; later notes move down, never off-screen).
  card follow the *selected* provider (`ActiveStackReadout.chatModelName`/`isChatModelLocal`; the "runs entirely on this Mac" line is false while
  a cloud provider is selected). Tested by `Tests/ScreenRegionFocus`.
- **Save a worked solution** (menu bar → **Save Worked Solution…**, or Talk chord + **S**, `saveWorkedSolutionShortcutPublisher`;
  the letter is rebindable in Settings → Shortcuts like Ask About a Part's, `ShortcutBindingStore.saveWorkedSolutionKey`, and yields to
  Ask About a Part if both are bound to one letter): saves the explanation Wisp drew (needs ≥1 note or circle,
  `WorkedSolutionExport.hasSomethingToSave`) on the display with the most notes. `CompanionManager.saveWorkedSolution`
  (`CompanionManager+WorkedSolutionExport.swift`) snapshots the drawings, takes a **fresh native-resolution capture of that one display with
  Wisp's own windows excluded** (`CompanionScreenCaptureUtility.captureDisplayAtNativeResolution` — the 896px model copy is never used),
  composites `ScreenAnnotationLayer(isForExport: true)` over it with SwiftUI `ImageRenderer` (every note regardless of `visibleNoteLimit`,
  no Next pill, no pulse — one drawing path, no duplicate), then an `NSSavePanel` (default `~/Pictures/Wisp Solutions/`, created on demand;
  "Worked solution <date time>.png") and writes the PNG plus a same-named `.md` (date, the last question from the transcript, the notes as a
  numbered list). Local only; the clipboard is untouched; confirmation is the notch reply + `flashIsland(.success)`. Pure rules (worth saving,
  which display, file names, Markdown) are in `WorkedSolutionExport.swift`, tested by `Tests/WorkedSolutionExport`; capture, render and the panel
  are untestable headless glue.
- **Voice selection of a part** ("ask about the third answer", "explain option C", "what does the second line mean", "tell me about step 2", `explain the line "x = 6"`): the spoken twin of Ask About a Part. `PartSelectionRequestParser` (pure, in `sendTranscriptToClaudeWithScreenshot` right after fast pointing; skipped for dictation, titled routine/skill turns and `skipsPartSelection`) needs an ordinal or label *beside* a list-item noun (answer/option/choice/line/step/bullet/item/row) or quoted / "the part that says …" text, and rejects anything that runs on into the wider world ("third quarter", "step 2 of the recipe", "option a question"); the rest of the sentence becomes the residual question (default "explain this part"). `CompanionManager.runPartSelectionTurn` captures, waits for the uncapped OCR lines (as fast pointing does) and asks `PartSelectionResolver` (pure) for one region: list markers (`A)`/`(b)`/bare `A`, `2.`, `Step 3`, bullets) that line up in a column or row and run in order form a list, ordinals count over its markers, a labelled item is found by its label, the item's region joins the text beside the marker and wrapped lines under it, and quoted text uses exact → contained → fast pointing's word matcher. Two lists / a label twice / text twice → `.ambiguous`, nothing found → `.notFound`: either way the user's original words go on as an ordinary turn. On success `FocusedScreenRegion(regionInScreenshotPixels:…)` (the inverse of `regionInScreenshotPixels`, padded 6pt and grown to the 24pt minimum) is set as `focusedScreenRegion`, highlighted, and the residual question is sent as a normal turn, so the close-up and prompt text above apply. "Line"/"row" ordinals only work over a detected list (no list → falls through). Tested by `Tests/PartSelection`.
- **Guided walkthrough** (`GuidedWalkthrough.swift` pure, `GuidedWalkthroughController.swift`): a reply whose annotation tags
  are ≥2 numbered, labelled steps (the existing step-by-step tags) is walked through one step at a time instead of drawn all at
  once (`CompanionManager.beginGuidedWalkthrough`, called where the reply's annotations are applied). Only step 1 uses the model's
  coordinates — the screen changes after it — so each later step is **found again on the live screen** from its words
  (`GuidedWalkthroughTargetText.pointingRequest`: filler verbs and "in the sidebar" clauses dropped) with fast pointing's
  deterministic AX + OCR matcher, retried every ~0.9s for up to 40s (a capture + OCR per try; "can't see it" shown after 5) and
  drawn as a numbered box. A step completes on a global `leftMouseDown` landing on the marked target
  (`GuidedWalkthroughClickMatcher`, AppKit-points → screenshot-pixels, no extra permission), or on the checklist's Next; Stop
  ends it. **Do it for me** (`performCurrentGuidedStepForUser`) has Wisp click the marked target itself (a synthesised
  `CGEvent` click at the box centre, `GuidedWalkthroughAutoClickPoint`) and moves on; it refuses a control whose label or
  instruction names an irreversible action (`ToolCallSafety.namesIrreversibleAction`: Send, Delete, Pay…) and says so under
  the step. Steps come from `[STEP:label]` tags (no coordinates — the model can't place a control that isn't on screen yet)
  or numbered BOX/ARROW tags. No model call per step. The notch shows `GuidedWalkthroughChecklistView` in place of the reply text
  (`answerSurfaceWithReplyActions`); the overlay isn't faded and the lingering-answer expiry is held while one runs, and a new
  question (`clearScreenAnnotations`) ends it. Tested by `Tests/GuidedWalkthrough`.
- **Fast pointing** ("where is X" / "point at X" / "where do I click to X"): recognised by
  `PointingRequestParser` in `sendTranscriptToClaudeWithScreenshot` after the browser router, and
  answered by `CompanionManager.runFastPointingTurn` **without the vision model**. The target is
  matched (`PointingTargetMatcher`, deterministic) against this turn's Accessibility elements and
  *uncapped* OCR lines, each already with an exact box; a label on screen more than once gets a
  marker in each place (≤3; an icon beside its label is one place). Only when that isn't sure does
  the local model pick an id **as text**, from a ≤15-item shortlist sharing a content word with the
  target (`PointingModelFallback`, lenient id parsing). A miss on a readable screen (≥12 items)
  replies "I can't see X on screen" at once; a miss on a near-empty screen (canvas, image) goes on
  as an ordinary turn with the captures handed back. Why: measured on an M3 Pro, a new screenshot
  costs ~4s of vision encoding even warm (~9s cold), and the 3B model's pixel guess was wrong 4 of 5
  times; the fast path lands in ~0.1s (≤0.9s with the model pick, ~0.7s when OCR starts cold for a
  typed question — it waits up to 1.5s, `FastPointingTiming`). Typed questions make Wisp frontmost,
  so `AccessibilityElementSnapshotter` reads `FrontmostAppTracker`'s last external app instead.
- **Screen watchers** ("tell me when the build finishes", "let me know when it says Succeeded",
  "watch for \"Done\"", "stop watching"): recognised by `ScreenWatchRequestParser` in
  `sendTranscriptToClaudeWithScreenshot` right after `FastCommandRouter` (not behind agent mode;
  conservative — "tell me when you're done"/"the meeting is over"/"an error appears" fall through to
  the model, which has `watch_screen`/`stop_screen_watch`, read-only, no confirmation, in the
  buddy `.screen` group). Conditions (`ScreenWatchCondition`): `textAppears` (whole-word,
  case/accent/punctuation-insensitive; fires when *more* lines match than the fewest seen, so the
  last build's "Succeeded" already on screen doesn't fire it but a new one does), `textDisappears`
  (seen, then absent 2 polls), `screenTextSettles` (OCR text changed, then unchanged 4 polls ≈12s —
  a screen that never changes never fires). `ScreenWatcherStore` polls the display the pointer was
  on every 3s with **its own capture** (cursor hidden, Wisp's windows excluded, 896px) and calls
  `ScreenTextRecognizer.recognizeText` directly — *not* the turn's path, because
  `ScreenshotReuseCache` would hand back the previous frame for exactly the small change being
  watched for (up to 45s), and the shared one-entry-per-display OCR cache could be evicted under a
  live turn. OCR is skipped when the frame's pixels are byte-identical to the last poll; menu-bar
  lines are dropped (the clock). Max 3 watches, 2-hour timeout (says so), 5 failed captures → stops.
  On success: a `UNUserNotification` (silent in quiet mode), `flashIsland(.success)` (the cue), and —
  only if Wisp is idle — the line in the notch, spoken in voice mode
  (`CompanionManager.presentScreenWatchEnding`). While watching, the island stays visible with an eye
  in the right flank, and the full panel's live section lists each watch with Stop. No model call.
- **Screen Annotation**: `[BOX:left,top,right,bottom:label]`, `[HIGHLIGHT:...]` and
  `[ARROW:x,y:label]` tags render through a `Canvas` layer in the overlay, as does the `.marker`
  from a `[POINT:]`.
  **Teaching on the page**: `[CIRCLE:l,t,r,b]` (or `[CIRCLE:t7]`) rings a chart bar, equation term or answer
  choice with a hand-drawn ellipse, and `[NOTE:x,y:text]` / `[NOTE:t7:text]` writes handwritten working
  (Bradley Hand over a faint highlighter band, `ScreenAnnotationLayer.noteView`) at a point, or just right of an
  element's frame for an id. Note text runs to the closing bracket, so it may hold colons and `=`. Notes and
  circles are never numbered walkthrough steps (so they don't trigger `GuidedWalkthroughPlan`) and are capped
  apart from shapes (12 notes, 8 shapes). The prompt tells the model to work a visual/math problem line by line
  beside its subject, circle the answer and say the idea via `[SAY:]`; it needs a capable model, so it is aimed
  at Claude (subscription or key), not the 3B local model.
  **Stepping through working**: a reply with ≥3 notes (`AnnotationNoteReveal.minimumNotesToStepThrough`) shows only the first
  (`CompanionManager.visibleNoteLimit`, nil = all) with a **Next › 1/6** pill beside the latest note (`ScreenAnnotationLayer.nextStepPill`;
  shapes always show). Clicking the pill (a second target kind in `AnnotationClickRouter`) or **⌃⌥→ / ⌃⌥←** (`noteStepShortcutPublisher`,
  layered on the Talk chord like ⌃⌥A; arrow auto-repeat allowed) reveals/removes one; the last reveal shows all and drops the pill. Because the
  chord's press clears the previous drawings, that clear is deferred 450ms while there are notes to step through
  (`clearScreenAnnotationsForNewUtterance`) and the step key cancels it. Not yet synced to the spoken line (no per-sentence timing exists).
  Tested in `Tests/GuidedWalkthrough` (parser) and `Tests/ScreenRegionFocus` (reveal logic). Note the corner format — the model emits corners, not origin+size. When
  several tags appear in one reply they are kept in document order and **auto-numbered** into a
  step-by-step walkthrough (badges drawn per step, cap 8). All annotations draw in the
  user-chosen colour from `CursorAppearanceStore` (Settings → General → Notch → Marker colour: blue/red/yellow/green; the old Cursor page and its always-visible overlay are gone).
- **Agent loop**: gated by `AgentModeEnabled` in Info.plist, which ships `true` (set it to
  `false` and rebuild to get plain answers with no tool calls; the Agent and Tools & Servers
  pages say so). With the local model, tools are called via structured `[TOOL:name:{json}]`
  tags rather than native tool_calls, since the local model is unreliable at the latter; the
  cloud providers use their native tool calling (`ModelCapabilities.supportsNativeToolCalls`). Surfaced in Settings → Agent: the
  **working folder** (`AgentSettingsStore`, read by the tool registry; defaults to
  `CodeProjectDirectory`), a **session auto-approve** toggle (`ToolConfirmationCoordinator.autoApproveThisSession`
  — short-circuits the confirmation prompt, reset every launch), and **permission** rows with
  deep-links to System Settings. Session auto-approve has a **destructive-action floor**
  (`ToolCallSafety`, modeled on `BrowserActionSafety`): calls classified as irreversible or
  outward-facing — send/post/reply/forward, delete/remove/trash, pay/purchase/transfer/refund,
  share/invite/publish/merge/deploy, arbitrary command execution, calendar events with guests
  (they email invitations), file writes whose path lands outside the agent working folder, and
  Composio `COMPOSIO_MULTI_EXECUTE_TOOL` calls whose unwrapped tool slugs are any of those (or
  can't be read; remote bash/workbench always), and every **cua-driver** tool that isn't a known
  read (`CuaDriverToolNames.mustAlwaysAsk`: click/type_text/press_key/hotkey/set_value/invoke_menu/
  drag/kill_app/… — none of those verbs is in the word floor; scoped to the `cua-driver__` namespace,
  so another server's `click` is judged as before) — still go to the confirmation card with
  auto-approve on. Reads and benign writes stay auto-approved. Deterministic word matching on the
  tool name + argument shapes, no model; errs toward asking. The registry now asks via
  `ToolPermissionBroker.requestApproval(toolName:toolInput:)` (structured args; a default
  extension forwards to the old summary-string method so stubs keep working).
- **Rich confirmation cards** ("Phase 6" of `docs/glance-cards-plan.md`): the pending
  confirmation carries an optional `confirmationCard: GlanceCard?`, built deterministically from
  the call by `ToolConfirmationCardBuilder` (never the model) and drawn by `GlanceCardView` above
  Cancel/Allow in `ToolConfirmationView` — "New Email" (To/Cc/Subject + truncated body), "New
  Message"/"New Post", "New Event" (title/start/end/where/guests), file writes/moves (file,
  folder, content preview, flagged "Outside agent folder"), deletions and other irreversible
  actions (identifying args + "can't be taken back"), Composio batches (one row per unwrapped
  tool), and cua-driver actions ("Click “Send” button · Mail", "Type into “Subject:” text field" +
  the text, "Press cmd+s", "Choose File › Save As…"): the `element_token` is resolved against
  `CuaDriverElementCache` (token → role/label/app from the last 4 cua-driver element lists Wisp
  passed to the model, session-only), a resolved label or menu item with an irreversible word (the
  `ToolCallSafety` vocabulary) gets "can't be taken back", and an unknown token shows the raw
  arguments plus "Wisp hasn't seen this element". Reading tools and unrecognised shapes get no card, so the panel falls back to the plain
  summary (zero regression). The spoken yes/no and deny-by-default flow are unchanged. Argument/name
  parsing shared by both lives in `ToolCallInspection` (lenient key lookup, Composio unwrapping,
  path containment, and `matchingFieldKey` — the exact key a lenient lookup lands on).
  **Inline-editable fields**: the card's plain human-text fields can be edited before Allow —
  email subject/body, message/post text and post title, event title/location (by the card
  builder's own shape classification, `ConfirmationCardShape`), `send_imessage`'s message (the
  Siri-style bubble), `create_reminder`'s title and `run_shortcut`'s input. Never recipients,
  handles, paths, URLs, commands, guests or times (changing who/where would bypass what the
  consent and `ToolCallSafety` judged), never a non-string or nested value, and never anything
  in a Composio call. `EditableConfirmationFields` (pure, `Tests/EditableConfirmation`) is the
  one rule: `editableFields(forToolNamed:toolInput:)` lists them (exact top-level keys) and
  `applyingEdits` re-derives that set from the asked-about input and drops any edit to another
  key (and blank/unchanged edits). Data flow: `ToolPermissionBroker.requestApprovalAllowingEdits`
  returns a `ToolApprovalOutcome` (decision + `editedTextsByArgumentKey`; a default extension
  wraps the old decision so stubs compile); `AgentToolRegistry.invoke` re-applies the edits via
  `approvedToolInput(forAskedToolInput:toolName:)` to the (prepared) input it asked about, runs
  that, appends `toolResultNote` ("the user edited this … subject: \"…\"") to the result so the
  model doesn't claim its own wording, and returns `Outcome.executedToolInput`, which the runner
  records as the History step detail. The direct "text mom …" route applies them the same way.
  The coordinator holds the edits (`editedTextsByArgumentKey`), so a spoken "yes" approves the
  current text; only `requestApprovalAllowingEdits` callers get editable fields (the old
  `requestApproval(toolName:toolInput:)` shows none, since its caller runs the original). Each
  edit/focus pushes `pendingConfirmationExpiryDate` to 45s from now, capped at 5 min after the
  request (`maximumConfirmationWindowWhileEditingSeconds`); `AgentTurnRunner`'s per-tool timeout
  waits out a prompt being edited, then grants its usual work time. While such a card is up the
  overlay panel may become key (`OverlayWindowManager.setAllowsKeyboardFocus`, non-activating,
  like `NotchPanel.allowsBecomingKey`; turning it off orders the key panel out/in to hand focus
  back). Fields (`EditableConfirmationFieldView`) read as card text until hovered (fill, pencil,
  I-beam), multi-line `TextEditor` for bodies, an "edited" mark when changed; plain Return never
  approves, Cmd-Return = Allow/Send, Esc just leaves the field; the raw call chip shows the
  edited call.
- **Browser control**: the user's real Chrome/Safari, driven through the DOM (AppleScript +
  injected JS in `AppleScriptBrowserController`), not the vision model — a snapshot assigns
  every interactive element a stable id (`e7`) and actions refer to ids, so pointing costs a
  few hundred ms against a screenshot's several seconds. Three tiers, cheapest first
  (`BrowserAgent.run`): **tier 0** a deterministic planner (`BrowserTaskPlanner`, ~964ms, no
  model), **tier 1** one planning call producing a whole mechanical plan executed end to end
  (`BrowserTaskRunner`), and **tier 2** a bounded per-step observe→act loop (`BrowserStepLoop`,
  cap 5, screenshot-free) that engages **only** when a tier-1 plan fails on a real page. A
  login wall stops any tier dead rather than becoming something to loop against. **When the
  selected provider is a cloud model**, anything tier 0 doesn't recognise goes instead to
  `BrowserAgentLoop` — a Cowork-style long-horizon observe→act loop (up to 30 decisions, several
  form actions per reply, stable element ids across steps, `look` for an on-demand screenshot,
  `done`/`ask`/`fail` to finish) driven by the user's `ModelProvider`; the local model keeps the
  tiers. Irreversible clicks (buy/send/post/delete…, classified by `BrowserActionSafety`) always
  go to the confirmation card via `requestIrreversibleBrowserActionApproval`, **even with session
  auto-approve on**; password/payment fields are refused in the injected JS itself. The snapshot
  JS walks shadow roots + same-origin iframes and lists an open dialog's elements, then in-view
  ones, first; actions fire real pointer events and React-safe value setters. `browser_task` gets
  a 10-minute tool timeout (`AgentTurnRunner.longRunningToolTimeoutSeconds`) and talking cancels
  it. **Browser control needs the `com.apple.security.automation.apple-events` entitlement**
  (in `leanring-buddy.entitlements`): the app runs with the hardened runtime, and without it macOS
  silently rejects every Apple Event to Chrome/Safari with -1743 and never prompts — which is how
  "open a new tab" did nothing. `NSAppleEventsUsageDescription` names the browser use. **Plain
  browser commands bypass the model's tool choice** (`BrowserCommandRouter`, checked in
  `sendTranscriptToClaudeWithScreenshot` right after `FastCommandRouter`): the local 3B model was
  measured emitting *no* tool call for "open a new tab" / "open youtube" / "go to github.com", so
  tab commands (new tab, close tab, back, forward, reload, new window) run directly via
  `AppleScriptBrowserController.performTabCommand` (plain AppleScript, no JS permission needed,
  frontmost browser), and clear web tasks (named site, address, "search for …") go straight to
  `BrowserAgent.run` (`runDirectBrowserRoute`; web tasks only when agent mode is on). The user's
  words are the consent, so the generic browser_task prompt is skipped; irreversible actions are
  still gated. A named site/domain also routes the model's tool scope to `.browser`
  (`AgentToolScope.forRequest`). **Every browser task runs in Wisp's own tab**, never the user's:
  `BrowserAgent.run` calls `beginDedicatedTabSession()` (opens a tab at the end of the front
  window — or reuses the last task's tab — and launches the browser if needed) and
  `endDedicatedTabSession()` after; in between every controller op targets that tab
  (`AppleScriptBrowserController.runInTargetTab`). Chrome addresses it by tab id (ids come back
  as *text* — compare as strings) and re-finds it across windows; Safari has no tab ids, so it
  uses window id + position, guarded by the window's tab count and re-found by last URL. If the
  tab is closed mid-task that is treated as "stop" (`BrowserControllerError.dedicatedTabClosed`)
  — ops never fall back to the user's tab. The user's page at ask-time is passed to the loop so
  "this page" tasks can open it. Outside a task (`read_page`, `click_element`) the user's front
  tab is still the target. Live step text is `CompanionManager.browserActivityText`, drawn as
  `BrowserActivityIndicator` under the notch. During tier 2
  each element is marked with a pulsing ring just before the loop clicks/types it, via
  `BrowserCursorGuide` (implemented by `CompanionManager`, which converts the element's global
  screen point into a `.marker` `ScreenAnnotation` on that display). Element
  screen coordinates come from `BrowserController.screenPoint(ofElementID:)`.
- **Messages & Contacts** (Siri-style texting): "text mom i'm running late" is recognised by
  `MessageCommandParser` (checked in `sendTranscriptToClaudeWithScreenshot` right after
  `FastCommandRouter`, before the browser router, **not** behind agent mode). Where the name ends
  is often unsaid, so the parser offers splits longest-first and `MessageRecipientResolver` keeps
  the one that is someone in Contacts — a guessed split must match exactly, and if none does the
  turn goes to the model as normal ("text size bigger"). `ContactsDirectory` reads Contacts
  on-device (`ContactMatcher` is the pure part: full name/nickname > first name > last
  name/company > word prefixes, duplicate cards collapse, two different people → ask which, and
  "mom"/"dad"/"wife" resolve through the Me card's relations). The recipient is resolved
  **before** consent, so the "New Message" card shows the real person and number; a send
  **always** asks, even under session auto-approve ("send" is on `ToolCallSafety`'s floor).
  `MessagesAppSender` drives Messages with AppleScript, passing handle and text as handler
  parameters (never spliced into source), iMessage first then SMS. The agent gets `send_imessage`
  (uses the registry's `ToolInputPreparer` hook: resolve → ask with the prepared input → run it)
  and read-only `find_contact`, in the `.messaging` `AgentToolScope`. Needs
  `NSContactsUsageDescription` + the `com.apple.security.personal-information.addressbook`
  entitlement (hardened runtime) and Automation → Messages.
- **Window management** (`WindowManagement/`): "put Safari on the left and Xcode on the right",
  "maximize this", "make this window full screen", "move Chrome to the right half", "center this
  window", "move this to my other screen", "tile Notes and Mail" are recognised by
  `WindowLayoutCommandParser` (checked in `sendTranscriptToClaudeWithScreenshot` right after
  `FastCommandRouter`; not behind agent mode, no confirmation — the user's words are the consent and a
  window can be put back) and carried out by `WindowLayoutExecutor` over Accessibility with **no model
  call**. Placements: halves, quarters, thirds, maximize, center, next display. Biased toward not
  matching: a window verb must lead, every clause must parse, app names must resolve to exactly one
  *running* regular app (`WindowLayoutApplicationNameMatcher`: exact, or a leading/trailing word run
  like "chrome" → "Google Chrome"; ambiguous or not running → ordinary model turn), an article-led
  target needs "window"/"app" ("the code" is not VS Code), and a bare "this"/"it" only counts with a
  placement that can only mean a window ("left half", "of the screen", corners, thirds, other screen —
  not bare "left", and "center this" is left alone). "this" is the frontmost app, or
  `FrontmostAppTracker`'s last external app when a typed question made Wisp frontmost. Frames come from
  the pure `WindowFrameCalculator` (display = the one holding the window's centre; `visibleFrame`s in
  AppKit space flipped to AX top-left space by the **primary** display's height, edges rounded so
  tiled halves share an edge). The executor reads the app and `NSScreen`s on the main actor, then runs
  AX detached with a 0.5s messaging timeout: focused → main → first standard window, unminimize, refuse
  a native full-screen Space, position → size → position (apps clamp), `AXRaise` + activate. Reply in
  the notch: "done — Safari left, Xcode right." + `flashIsland`. The agent gets `arrange_windows`
  (app + placement; `.writing(.localMachine)`, so it asks once and session auto-approve covers it; in
  the buddy **Screen** tool group).
- **Chrome tab organizing** (the **Wisp Tabs** extension, `chrome-extension/` at the repo root,
  loaded unpacked): AppleScript can't reach `chrome.tabGroups`, so a thin MV3 extension exposes tab
  primitives (`getTabs`/`groupTabs`/`ungroupTabs`/`closeTabs`) and Wisp does all the deciding.
  `ChromeExtensionBridge` listens on a WebSocket bound to **127.0.0.1:47823** (Network.framework;
  `requiredInterfaceType = .loopback` still bound `*`, so it uses `requiredLocalEndpoint`) and
  **rejects any handshake whose `Origin` isn't `chrome-extension://kpblnefdnmlodeagdnfodnbbdbkacnce`**.
  That ID is pinned by the `key` in the manifest, and a web page can't forge `Origin`. The extension
  dials in (a service worker can't listen), pings every 20s to stay alive, and an alarm retries every
  30s. `ChromeTabOrganizer` plans per window and only touches **loose, unpinned tabs** (a tab joins an
  existing group only when it has the exact same name, so re-running is incremental). It groups by site
  (`ChromeSiteNamer`, deterministic) or by topic (one text-only model call listing tabs as 1…N, since
  page titles are untrusted and the parsed reply can only name listed numbers; falls back to site). It
  also closes duplicates (`ChromeDuplicateTabFinder`: keeps the showing tab, never closes pinned or
  audible tabs). Plain commands ("organize my tabs", "group my tabs by site", "close duplicate tabs",
  "ungroup my tabs") are recognised by `ChromeTabCommandRouter` inside `BrowserCommandRouter`
  (`.chromeTabs`) and run without the model's tool choice, like tab commands and without agent mode. The
  agent gets `chrome_list_tabs`/`chrome_organize_tabs`/`chrome_close_duplicate_tabs`/`chrome_close_tabs`/
  `chrome_ungroup_tabs`/`chrome_focus_tab`/`chrome_pin_tabs`/`chrome_mute_tabs`/`chrome_move_tabs_to_new_window` (browser scope); plain commands also cover collapse/expand groups and mute/unmute tabs. The extension needs no new permissions for these (reload it to pick them up). Status and install help live in the Agent tab's Chrome Tabs card.
- **MCP**: hand-rolled JSON-RPC 2.0. Config at `~/.wisp/mcp.json` in Claude Desktop's
  format. The byte transport is abstracted behind `MCPTransport`
  (`MCPTransport.swift`): `MCPServerConnection` owns only JSON-RPC framing + the handshake,
  while `StdioMCPTransport` (`MCPStdioTransport.swift`) carries the child-process/stdin/stdout
  path. **Stdio pipes are read with `readabilityHandler` + `NewlineDelimitedLineBuffer`, never
  `FileHandle.bytes.lines`**: reading stdout and stderr concurrently through `bytes.lines` stalls,
  so replies sat unread in the pipe and every stdio server failed with "didn't answer tools/list
  in time". Startup: `initialize` for a package runner (`npx`/`uvx`/`bunx`/`pnpx`/`pipx`/`uv`) gets
  180s, since the first run downloads the server (`MCPStartupTimeoutPolicy`), and every other request
  gets 25s. `MCPManager` connects servers **concurrently**. After 3s still connecting, a package-runner
  server shows **Installing…**. A failure message carries the server's last stderr line
  (`MCPConnectionFailureMessage`), and a connect that finishes after a newer reload discards itself
  (`connectionGeneration`). This split is the foundation for the in-flight **MCP marketplace** (remote Streamable
  HTTP transport + Composio managed-OAuth toolkits + a curated registry) — see
  `docs/mcp-marketplace-architecture.md`. Remote servers now work: a `~/.wisp/mcp.json` entry
  with a `url` (and optional `headers` for auth) connects over `MCPStreamableHTTPTransport`
  (`MCPStreamableHTTPTransport.swift`); an entry with a `command` is stdio as before. The
  **Connections → Marketplace** page (`MarketplaceTab.swift`) browses a bundled curated registry
  (`curated-mcp-registry.json`) and installs/removes/enables servers via `InstalledMCPServerStore`,
  which owns `~/.wisp/mcp.json` (preserving unknown keys) and reloads the manager live. Installing
  is separate from exposing: `MCPManager` registers **all** allowed tools (the per-server
  allow-list is applied at registration; the connection no longer filters), and the **per-turn
  tool router** (`AgentToolRouter.swift`) shows the model only the most relevant to the request —
  6 for the local model (`AgentToolScope.maximumExposedTools`), 16 for a cloud model
  (`maximumExposedToolsForCloudModels`, chosen in `AgentTurnRunner` from
  `deployment.sendsDataOffThisMachine`) — ranked by lexical relevance with a bonus for built-in
  scope membership. So a large installed library costs nothing until a request is about it. The
  tab shows how many tools are available + per-tool toggles (the allow-list). A **Composio** section
  (opt-in, off-machine, labelled) lets a user paste a Composio API key (`ComposioKeychainStore`),
  browse toolkits (`ComposioClient`/`ComposioAccountStore`), and install one as a managed remote
  MCP server; the key is injected into the transport from the Keychain at connect time, never
  written to `mcp.json`. Composio here is the **connect universal server**
  (`https://connect.composio.dev/mcp`, auth `x-consumer-api-key`): connecting installs one
  remote server whose meta-tools (`COMPOSIO_SEARCH_TOOLS`/`MULTI_EXECUTE_TOOL`/
  `MANAGE_CONNECTIONS`, …) reach 500+ apps and count against the same tool budget.
  **Structured results**: an MCP result's `structuredContent` (2025-06-18 spec) is no longer
  dropped. `MCPServerConnection.callToolReturningContent` returns it beside the flattened text
  blocks, and `MCPToolResultRendering.modelText` (used by `MCPManager` for every MCP tool) renders
  it first: a list of UI elements (objects with a token/id + role) as one line each
  (`s1a2b3c4d:3 Button "Send" = "value" (disabled)`, under a header of the result's short scalar
  fields), anything else as sorted compact JSON — capped at 4000 chars, with the text blocks after
  it within 5000 total (500 beside an element list, whose text is usually the same tree as
  markdown; a text block that is just the structured content's JSON is dropped). A result with no
  `structuredContent` is returned exactly as before, and plain `callTool` (Composio's connection
  list parses its text) still returns only the text. Image blocks are still named "(image
  content)": tool results are `String` from handler to provider, so passing images through would
  mean a new content type in every provider.
  **cua-driver** (github.com/trycua/cua, `docs/cua-spike.md` on `spike/cua`) is supported: install
  it pinned (`uv tool install cua-driver==0.34.1`) and add a `cua-driver` entry (`command`:
  `~/.local/bin/cua-driver`, `args` `["mcp", "--direct"]` — direct mode runs under Wisp's own
  Accessibility/Screen Recording grants — and `env` `DO_NOT_TRACK=1`,
  `CUA_DRIVER_RS_TELEMETRY_ENABLED=false`, `CUA_DRIVER_RS_UPDATE_CHECK=false`, since its telemetry
  is on by default). Start with the reads in `allowedTools` (`list_apps`, `list_windows`,
  `get_window_state`, `verify_state`); to let Wisp act in native apps, add `click`, `type_text`,
  `press_key`, `hotkey`, `scroll`, `set_value` and `invoke_menu`. Every action asks (see the
  destructive-action floor) with a card naming the element; the looking-only tools
  (`CuaDriverToolNames.runsWithoutConfirmationBareToolNames`: list_apps/list_windows/
  get_window_state/verify_state…, not scroll or clipboard_read) run without a card, like Wisp's own
  `read_screen_text`, so a click costs one card instead of three. `MCPManager` appends to each cua
  tool's description where element tokens and pids come from (`modelFacingDescription`), and a
  call addressed with one of Wisp's own `a`/`t` ids or pid ≤ 0 is refused before the card by an
  input preparer (`refusalForMisaddressedCall`) — measured live, the model sent
  `click {"pid": 0, "element_token": "a13"}`. **Checked after acting:** after any cua action that reports success
  (not reads, `clipboard_write` or `replay_trajectory`), `MCPManager.cuaDriverResultCheckedAfterAction`
  waits 0.5s, re-reads the app — `list_windows` for its pid (catches a window opened or closed) and
  `get_window_state` for the acted-on window (≤60 elements, no screenshot; skipped after `kill_app`) —
  and appends both to the action's result with an instruction to compare before claiming success
  (`CuaDriverPostActionCheck`). Done inside the same tool call so it costs no extra agent-loop
  iteration and can't be skipped; measured live, the driver answers menu picks with
  `"effect": "unverifiable"` and the model otherwise said "I can't confirm it from here". **Routing:** "click" is a browser-scope
  word, so before `CuaDriverToolRouting` a request like "click the New Note button in Notes" got the
  browser tools and no cua tool. Now a request that names cua, or names a running non-browser app
  together with a UI word (click/type/button/menu/field/window…), boosts every registered cua-driver
  tool and drops the browser scope's bonus (`AgentToolRouter.select(scopeOverride:)`); a request that
  names a browser or website is left to the browser tools. Keep `kill_app`, `clipboard_*`,
  `browser_*`, `install_*` and `replay_trajectory` off. Ask `get_window_state` for `max_elements`
  — one window can be 300+ elements.
- **Apple Shortcuts as agent tools** (local, no server): `list_shortcuts` (read-only) and
  `run_shortcut` (name + optional text input) drive the system `/usr/bin/shortcuts` CLI via
  `ShortcutsBridge` — `Process` with an **argument array** (name last, after `--`, so spaces,
  quotes or a leading dash stay one name; runs by the listing's UUID when known), off the main
  actor on a dispatch queue, a 120s run timeout (`ShortcutsBridge.runTimeoutSeconds`; the process
  is terminated on timeout *or* task cancellation), input/output through per-run temp files,
  output capped at 2000 chars. The list (`shortcuts list --show-identifiers`) is cached 5 min and
  refreshed on demand (Settings → Agent button, or a name miss). `run_shortcut` resolves only an exact
  name (case/punctuation-insensitive, unique) — never fuzzy, because the user approved that name.
  It is declared with worst-case metadata (write + destructive + external) **and** listed in
  `ToolCallSafety.alwaysAskBareToolNames`, so it asks **even under session auto-approve** (what a
  shortcut does is opaque); the card is "Run Shortcut" with the shortcut and its input.
  `AgentTurnRunner` gives it confirmation window + run timeout + slack. **Routing**: rather than
  listing every shortcut in the tool description (tokens every turn, growing with the library),
  `AgentToolRegistry.definitions(forRequest:)` matches the request against the *cached* names
  (`ShortcutNameMatcher` — all meaningful name words present, one-word names need a "run"-like
  cue, grammar/question words ignored) and, only on a match, boosts `run_shortcut` via the
  router's `boostedToolNames` and appends at most 3 matching names to its description for that
  turn (`ShortcutsToolRouting`); a request saying "shortcut(s)" (not "keyboard shortcut") boosts
  both tools and relies on `list_shortcuts`. The Agent tab shows availability + count + Refresh.
- **Routine blanks & sharing**: a routine's instruction can hold `{person}` / `{topic|default}` blanks
  (`RoutineParameters`, pure; max 6, names start with a letter, JSON/code braces are left alone). `CompanionManager.runRoutine`
  asks for them first in a native alert (`RoutineParameterPrompt`, prefilled from `WispRoutine.lastParameterValues` or the
  default; Cancel sends nothing) — an alert because routines also run from the notch, which can't host a sheet.
  `{clipboard}` (fenced between `<<<`/`>>>` and labelled as data), `{date}` and `{time}` are filled by Wisp, never asked.
  **Sharing** (`WispShareBundle.swift` pure, `WispShareImporter.swift` panels + adding): routines and buddies export as a
  `.wisp` JSON file holding setup only (routine: name/instruction/icon/apps; buddy: job, colour, specialty, model, tool limits,
  its schedule as words) — never threads, notes, files, shortcuts, ids or keys. A file from someone else is untrusted: 1 MB and
  50-per-kind caps, text trimmed and capped, unknown icons replaced, and a review dialog (`WispShareReview`) says what each
  item could do (cloud model, "every tool", clipboard use) before anything is added. Imports are inert: routines arrive with
  no shortcut or pin, buddies with their schedule off (made with a placeholder repeating schedule then set to `.once`, since
  `createBuddy` runs a one-off buddy immediately) and nothing runs. Entry points: Routines → Import / Share, buddy About →
  Share this buddy, the new-buddy screen → Import from file.
- **Skills**: markdown files with a `name`/`description` frontmatter header, dropped in
  `~/.wisp/skills/`. Only the name+description index (a few tokens each) is always in the
  prompt; the full body is loaded on demand via the read-only `load_skill` tool —
  progressive disclosure, so an arbitrarily large skill library costs nothing until used.
- **Memory** (local-only, private): two layers. **Recent conversation history** —
  `ConversationHistoryStore` mirrors the live `ConversationTranscript` (via a `didSet` on
  `CompanionManager.conversationTranscript`, merged by turn id, debounced ~1s, flushed on quit) to
  `~/Library/Application Support/Wisp/conversation.json`, keeping the last 20 turns (the live
  transcript keeps 10). Text, tool-use and tool-result blocks only — **images are never persisted**
  (dropped by `ConversationHistoryCodec`; tool results capped at 2000 chars on disk). The stored
  record stays the source and requests stay projections (`messagesForFollowUpRequest`). On launch
  only turns from the last **6 hours** are resumed into the live transcript
  (`ConversationHistoryCodec.turnsToResume`); older ones stay on disk for reference but are not fed
  back, because a stale "this page"/"that error" refers to a screen the user no longer sees and
  every resumed turn costs prompt tokens. **User memory** — `~/.wisp/memory.md`, human-editable
  markdown, one fact per bullet, owned by `MemoryStore` (re-reads on file change, writes only
  touch bullet lines). A compact index (`MemoryIndex`, ≤800 chars, newest facts preferred) is
  appended to the companion system prompt on both turn paths via
  `MemoryStore.shared.promptInstructions()`, so it applies with or without agent mode. In agent
  mode the model can call `remember` (`.writing`) and `forget` (destructive; refuses a vague
  query matching >3 facts) — both confirm, since the file shapes every later prompt; the
  `.memory` `AgentToolScope` routes "remember that…"/"forget…" to them. **While the brain is on
  (default) this layer lives in the brain's `wiki/me.md` instead**: `BrainMemoryMigration` moves
  memory.md's facts there once, `MemoryStore` keeps its API but reads/writes the me page
  (`BrainAboutMe` builds the ≤800-char system-prompt block), and memory.md is only read with the
  brain off. Brain → Settings clears conversation history (which also empties the live transcript
  via `onConversationHistoryCleared`); the old History → Memory page is gone.
- **Brain** (Karpathy's "LLM wiki"; local, `Brain/` + `WispWindow/Brain/`): `~/.wisp/brain/` is a
  folder of markdown pages Wisp maintains — a valid Obsidian vault. `SCHEMA.md` (user-editable
  conventions, put in every writer's prompt), generated `index.md`, human `log.md`, `wiki/` pages
  (`me.md`, `people/`, `projects/`, `topics/`, `sources/`, …; frontmatter title/kind/summary/
  aliases/tags/sources/locked, `## Section` bodies, `[[links]]`), `raw/` sources Wisp never edits
  (inbox/ingested/notes/conversations/activity), `.brain/` machine state. **No writer touches a page
  file**: ingest, digests, lint and agent tools produce `BrainEditProposal`s (lenient JSON from the
  model) and `BrainEditPlanner` validates each batch — caps, section-only edits, bullet dedupe, and
  `BrainEditProvenance.trust`: `.external` (web/files/window titles) may only append/create and
  never touch `me`, `.derivedFromUser` (conversations/notes) may not replace, `.userAuthored` may do
  anything; locked pages are never changed. `BrainStore.apply` versions every overwritten page under
  `.brain/versions/<change>/` and records a `BrainChangeRecord`, so every batch is one Undo in
  Brain → Log (conflict-checked by content hash; `deletingSlugs:` makes a merge one record).
  **Reading**: `BrainSearch` is BM25 with field weights (no embedding model — residency); each turn
  the ≤4 relevant page summaries (`BrainPromptContext`, score bar, ~700 chars) join the per-turn
  screen-context block on the **user message** and are stripped from history like `a`/`t` ids.
  Agent tools (`.brain` scope): `search_brain`, `read_brain_page` (read-only), `add_to_brain`,
  `ingest_into_brain` (ask). `BrainCommandRouter` sends "add this page/file to my brain" straight to
  the queue (front browser tab or Finder selection), no model. **Feeds**: `BrainIngestQueue`
  (serial, persisted, resumable; `BrainTextExtractor` md/txt/PDF/HTML/RTF/DOCX + user-requested URL
  fetch, `BrainTextChunker` ~2500-char chunks, `BrainKnowledgeExtractor` one call per chunk + a
  `source` page per material, `BrainInboxWatcher` polls `raw/inbox/`); `BrainConversationDigester`
  (ended sessions ≥30 min idle, user words + answers only, substantive-only heuristic, ≤3 per
  pass); `BrainNotesImporter` (folder/Obsidian, hash-deduped, 500 per run; Apple Notes via
  AppleScript); `BrainActivityRecorder` (**opt-in, off by default**: app/window title/URL-without-
  query once a minute while present and not on a call, built-in + user exclusions, Chrome incognito
  skipped, reuses existing OCR text only, never screenshots, 30-day retention, daily digest of a
  compact summary **always on the local model**). `BrainMaintenance` lints (broken links → stub
  pages, likely duplicates → merge + relink, oversized → split, missing summaries). All model work
  is background priority through `ModelAccessGate`; switches live in `BrainPreferences`. UI: sidebar
  **Brain** with Pages (reader/editor, backlinks), Graph (force layout), Inbox (drop zone, jobs,
  notes import), Health, Log (undo), Settings.
- **Reliability guards** (modeled on HeyClicky's support-mail fixes):
  - **One copy only**: `SingleInstanceGuard` runs first in `applicationDidFinishLaunching`. A second copy (another path, e.g. a
    DerivedData build beside an installed one) would install a second Talk event tap and answer everything twice. Instead it posts a
    distributed notification (the running copy opens its window), quits, and skips `applicationWillTerminate`'s saves.
  - **Muted speaker**: before speaking the main reply's `[SAY:]` line, `SystemAudioOutput.isDefaultOutputSilent()` (CoreAudio mute +
    virtual main volume on the default output; a device with neither control counts as audible) is checked. If the output is silent,
    the whole reply goes to the clipboard instead, and the notch shows "Your Mac is muted, so it's on the clipboard" with **Turn sound on**
    (`CompanionManager.mutedReplyNoticeText`, matched against `currentReplyText` so a newer answer drops it). Short fixed replies
    (window layout, timers) aren't covered.
  - **Microphone fallback** (`MicrophoneInputDevices.swift`, used by `BuddyDictationManager`): each session records from the system default
    unless it would hear nothing, using `MicrophoneInputChoicePolicy`. That means the built-in mic with the lid closed (`AppleClamshellState`
    from IOPMrootDomain), or a mic that went silent in the last 10 minutes. Virtual/aggregate loopback devices (Teams Audio, BlackHole) are
    never picked. A device switch replaces the `AVAudioEngine` (a reconfigured engine keeps the old format and the tap won't install) and pins
    it with `kAudioOutputUnitProperty_CurrentDevice`. Two seconds into a hold, `MicrophoneSignalMeter` (written on the audio thread) checks for
    no buffers or exact digital zeros. If so, Wisp switches once per hold and restarts the transcription session (callbacks from the replaced
    session are ignored via `transcriptionSessionGeneration`). An engine that fails to start also tries another device once. The user sees
    `CompanionManager.microphoneNotice` as a `MicrophoneNoticeIndicator` capsule under the notch.
  - **Unattended work waits for a ready Mac** (`SystemReadinessMonitor`: NSWorkspace sleep/wake + `NWPathMonitor`, started at launch).
    Scheduled and event automation runs, and `BuddyStore.runDueBuddies`, hold until 45s after wake. Runs that need the internet
    (`AutomationNetworkPolicy`: a cloud-model buddy or the Canvas sync; the local model doesn't) also hold while offline. A held run leaves no
    record and stays due; the automation row says "Waiting for the internet" (`AutomationEngine.automationIDsWaitingForInternet`). Run now is
    never held.
  - **Three failures pause an automation** (`AutomationFailurePausePolicy`): three unattended failures in a row pause it and set
    `Automation.pausedReason` ("Paused after 3 failed runs in a row. Last time: …"). That reason shows on its row, in Needs you and in the
    notification, and resuming clears it. Failures excused by `AutomationRunRecord.failureDoesNotCountTowardPause` don't count: the
    connection dropped mid-run, or Wisp quit mid-run. Run now failures and skips neither count nor reset the streak. A declined approval
    resets it. Tested by `Tests/AutomationEngine` and `Tests/AudioDevices`.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: none. `WispAnalytics.swift` is gated off and sends nothing.
- **Usage log** (local, private; `UsageLogStore`): a record per finished model turn — timestamp, provider kind,
  model API name, input/output/cached-input tokens, an estimated API-equivalent cost, duration, whether a screenshot was
  attached, and whether it was a background/buddy run — in `~/Library/Application Support/Wisp/usage-log.json` (0600,
  30-day retention, debounced save like the task history, flushed on quit). **Nothing leaves the Mac and no content is
  stored**: `UsageLogRecord` has no field for prompt text, answers, screenshots or anything typed, and `Tests/UsageLog`
  asserts the persisted keys. Providers surface usage through optional fields on `BuddyChatTurn` (`promptTokens`,
  `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`, `reportedCostUSD` — nil = not reported, never zero): Anthropic
  from `message_start`/`message_delta`, the Claude subscription CLI from the `result` event (`usage` + `total_cost_usd`),
  OpenAI/Gemini from the final usage chunk, Ollama from `prompt_eval_count`/`eval_count`. `AgentTurnRunner.Outcome.usage`
  sums them over the turn's model calls; `CompanionManager` (live turns) and `BackgroundTaskLauncher` (buddy/background
  runs) call `UsageLogStore.recordTurn(providerIdentifier:…)` once on success, parsing kind + model out of
  `ModelProvider.identifier`. `ModelPricing` is a hand-maintained **estimate** table (Claude Opus/Sonnet 5.5, Haiku 4.5,
  gpt-4o, gemini-2.5-flash; local = $0; `pricesSetOn` dates it) — a provider-reported cost wins, an unpriced model stays
  "cost unknown". Subscription turns read "included in subscription (≈ API cost $X)". Shown in Settings → Model → Usage
  (today / 7 days / 30 days, per-provider, Clear). Turns that fail or are cancelled are not logged.

### Key Architecture Decisions

**Menu Bar Menu**: The menu bar item is an `NSStatusItem` with a native `NSMenu`
(`MenuBarMenuController`). It used to open a large custom `NSPanel` that duplicated the
dashboard's settings; with the notch as the primary surface, the menu bar only needs status,
a way to ask, two switches and the way into the Wisp window.

**Screen Overlay**: A full-screen transparent `NSPanel` (one per screen) hosts the
assistant's on-screen surfaces — the tool-confirmation card and the drawn markers, boxes,
arrows and highlights (`OverlayContentView`). It draws nothing while idle and tracks no
cursor. It's non-activating, joins all Spaces, and never steals focus. Because it covers the
whole screen at `.screenSaver` level, it must keep `ignoresMouseEvents = true` except while a
tool confirmation card is up — otherwise the desktop becomes unclickable. It may become key
(`allowsBecomingKey`) only while a confirmation card with editable fields is up, and the manager
remembers both states so an overlay rebuilt mid-prompt keeps them.

**Notch HUD**: The resident primary surface (Phase 1 of the HeyClicky-style build).
A borderless `.nonactivatingPanel` (`NotchWindowController` / `NotchPanel`) sits one level
above the cursor overlay so it is never occluded. The window is a **fixed size** (the expanded
panel's bounds) and never moves or resizes — an earlier resize-on-hover version fed back on
itself (resizing moved the tracking area that detected the hover, so it oscillated at the
edges) and reflowed content mid-animation. Instead: expand/collapse is decided by polling
`NSEvent.mouseLocation` on a light timer against two fixed hot-zones (a small one around the
pill, a larger one around the panel, with hysteresis), and the pill→panel morph is animated
entirely inside SwiftUI on the GPU. Click-through is preserved by toggling `ignoresMouseEvents`
— the transparent window is click-through while collapsed and only intercepts events while the
panel is open. Geometry (`NotchGeometry`) comes from `safeAreaInsets` +
`auxiliaryTopLeftArea/auxiliaryTopRightArea`, falling back to a floating pill under the menu
bar on non-notch Macs. The menu bar `NSStatusItem` remains, now as the settings entry point.

**Global Push-To-Talk Shortcut**: Uses a listen-only `CGEvent` tap rather than an AppKit
global monitor, so modifier-based shortcuts like ctrl+option are detected reliably in the
background. Bindings are data-driven via `ShortcutBindingStore` (the source of truth for the
notch cheat-sheet and Settings → Shortcuts), which pushes live values into the plain
statics the tap reads on the main thread (`BuddyPushToTalkShortcut.currentShortcutOption` /
`.handsFreeDoubleTapModifier`). The tap recognises three gestures: **hold** the chord
(Talk; Dictate = hold + Shift; action on release), **tap** the chord (a release shorter than
`tapMaxDuration` → open the text composer), and **double-tap** a bare modifier (default:
double-tap Control → hands-free dictation). Recording still starts instantly on press for the
hold case; a tap simply `cancelCurrentDictation`s the just-started session and opens the
composer instead, so hold-to-talk latency is untouched. While the Talk chord is held, a **number key 1–9 runs that routine** (`routineShortcutPublisher`; the hold's recording is cancelled and its release swallowed, like the tap path). The double-tap detector is independent
of the hold path — the hold chord always needs a second modifier, so a bare-modifier tap can
never be confused with it. The text composer (`TextComposerWindowController`) is a keyable
panel that activates the app for typing and routes the typed question through the same
screenshot turn as voice (spoken answer + on-screen pointing). Because the four modes look
identical while they happen — one extra modifier decides whether your words are answered or
typed into a field — the fired gesture is named by a brief overlay badge
(`CompanionManager.activeCommandMode` → `PushToTalkCommandMode`, drawn by `CommandModeIndicator`
under the notch): Talk / Dictate → app / Type / Hands-free, set when the gesture fires and
cleared when it ends. This restored the mode feedback the old cursor waveform's dictation label
used to carry. Alongside the badge, an ambient **listening glow** (`ScreenListeningGlow`) frames
every screen's edges in a saturated lavender (the AI-activity accent) while `voiceState ==
.listening`, so "is it hearing me?" is answered wherever the user is looking, not just at the
badge.

**Model residency is the binding constraint.** On 18GB, a resident local vision model
(the 3B default, or a 7B) leaves little spare — which is also why the default TTS is Kokoro
(in-process on the Neural Engine, with a footprint that doesn't grow with use) rather than the Chatterbox server, whose
resident memory grew to several gigabytes with use, and why the speech models are loaded once
and shared. A second concurrently-resident LLM is not feasible at
that size. `ModelAccessGate` serialises all model calls so background work never evicts
the prefix cache an interactive turn is depending on, and the keep-warm heartbeat is
suspended during agent loops for the same reason.

**Vision encoding dominates latency.** At 1280px a screenshot costs ~4049 tokens; at 896px
it costs ~1095. Screenshots are therefore capped at 896px, and are skipped entirely when
the prompt does not appear to refer to the screen.

**The conversation is stored as ordered content blocks, not strings.** `BuddyChatTurn`
holds a `content: [BuddyContentBlock]` — each run of prose and each tool call in the
position the model produced it — and `text` / `toolUses` are views onto it. A joined
string plus a separate call list cannot say which sentence came before a call, so
replaying it invents a turn that never happened. `CompanionManager` owns the full record
in a `ConversationTranscript`; what any one request carries is a *projection* of that
record, never an edit to it. That is why the screenshot is dropped in
`AgentTurnRunner` on the way to the provider rather than stripped out of the stored
history: a request is allowed to carry less than the conversation holds.

## Key Files

Grouped by what they do. Line counts are approximate.

### Core pipeline
| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~105 | Menu bar app entry point. `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate`, which creates `MenuBarPanelManager` and starts `CompanionManager`. |
| `CompanionManager.swift` | ~3150 | Central state machine and integration hub. Owns dictation, shortcut monitoring, screen capture, the chat client, TTS, overlays, annotations, agent mode and tool confirmations. `runSkill(named:)` is the notch's one-click launcher. Also exposes the Dynamic Island projection: the computed `islandState` (`WispIslandState`, derived from `voiceState` + `pendingToolConfirmation` + reply/card presence) and `flashIsland(_:)` / `islandFlash` for transient success/error moments. |
| `BuddyDictationManager.swift` | ~940 | Push-to-talk voice pipeline: mic capture via `AVAudioEngine`, permission checks, transcript finalisation, live audio levels for the waveform. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~270 | System-wide shortcuts via a listen-only `CGEvent` tap: the hold chord plus an additive bare-modifier double-tap recogniser (hands-free dictation). |
| `ShortcutBindingStore.swift` | ~210 | Data-driven source of truth for shortcuts: hold chord, hands-free enable + modifier, and the letters for Ask About a Part (`AskAboutPartKey`) and Save Worked Solution. Persists to UserDefaults, resets to defaults, and pushes live values to the tap's statics. |
| `TextComposerWindowController.swift` | ~230 | The tap-to-type text composer: a keyable floating panel (activates the app for typing, Return to send, Esc to dismiss) whose typed question runs through the normal screenshot turn. |
| `DictationSettingsStore.swift` | ~110 | Source of truth for dictation language + custom dictionary. Persists to UserDefaults; read by `BuddyDictationManager` when starting a session. |
| `DictationTab.swift` | ~200 | Settings → Dictation: language picker (Automatic + on-device locales) and a removable-chip custom dictionary editor. |
| `CursorAppearanceStore.swift` | ~90 | Source of truth for the cursor/annotation colour (blue/red/yellow/green). Observed by the overlay, annotation layer, and brand glyphs so a change applies live. |
| `AgentSettingsStore.swift` | ~80 | Source of truth for the agent working folder. Persists to UserDefaults; the resolved path is readable off the main actor for the tool registry. |
| `AgentTab.swift` | ~395 | Settings → Agent: agent folder (folder picker + reset), session auto-approve toggle (its subtitle names what still asks — the `ToolCallSafety` floor), announcements, an Apple Shortcuts card (availability, shortcut count, Refresh via `ShortcutsBridge`) and the Chrome Tabs card. Permissions moved to Settings → General. |
| `BuddyChatTypes.swift` | ~685 | Shared value types: `JSONValue`, `BuddyContentBlock`, `BuddyChatMessage`/`BuddyChatTurn`, `BuddyToolDefinition`, `ConversationTranscript`, and the `AgentTaskRecord`/`AgentStepRecord` history records. |
| `AppBundleConfiguration.swift` | ~30 | Reads Info.plist string keys (`VoiceTranscriptionProvider`, `VoiceTTSProvider`, `AgentModeEnabled`, `OllamaModel`, …) from the built bundle. |
| `DictatedTextInserter.swift` | ~135 | Dictate mode's text insertion into the focused field: Accessibility selected-text for native fields, clipboard + synthesised ⌘V for web content and apps where AX does nothing. |
| `ScreenshotReuseCache.swift` | ~125 | Resends the previous screenshot's exact bytes when the screen hasn't perceptibly changed, so Ollama's image cache hits instead of re-encoding. |
| `CompanionScreenCaptureUtility.swift` | ~150 | Multi-monitor capture via ScreenCaptureKit, downscaled to 896px. Starts OCR (`ScreenTextRecognizer`) on each captured frame. |

### Local model stack
| File | Lines | Purpose |
|------|-------|---------|
| `LocalOllamaAPI.swift` | ~350 | Ollama client: NDJSON streaming, `keep_alive`, per-mode context and token limits, and the heuristic that decides whether a prompt needs a screenshot at all. |
| `ModelProvider.swift` | ~260 | Provider-agnostic runtime: the `ModelProvider` protocol (`streamTurn`), plus `ModelRequest`, `ModelCapabilities`, and `ModelDeployment` (`sendsDataOffThisMachine`, which drives the local-only-machinery gates). |
| `OllamaProvider.swift` | ~294 | Presents `LocalOllamaAPI` as a `ModelProvider`; owns the `[TOOL:...]` text convention that fakes tool calls for the local model. |
| `AnthropicProvider.swift` | ~680 | Claude as a bring-your-own-key `ModelProvider` over the raw Messages API: SSE streaming, native `tool_use`, adaptive thinking + `effort` (Opus/Sonnet 5.5), signed thinking and web blocks kept as `.providerReplay` and resent verbatim within a tool loop (`drop_block` for stale ones), prompt caching (system breakpoint + automatic), server-side `web_search`/`web_fetch` on tool-bearing turns (resumes `pause_turn`), `fallbacks: "default"` for refusals, no sampling params on models that reject them. |
| `AnthropicModelSettings.swift` | ~140 | Claude's settings (UserDefaults): `AnthropicModelChoice` (Opus 5.5 default / Sonnet 5.5 / Haiku 4.5, with each model's API differences as data), `AnthropicEffortLevel` (low default), and the web-access switch. Edited in Settings → Model, read by `ModelProviderFactory`. |
| `ClaudeSubscriptionProvider.swift` | ~430 | Claude over the user's own `claude` CLI (subscription, no key): per-turn stream-json process with all CLI tools off, inline screenshot, `[TOOL:]` text tags, failure-text → `BuddyChatError`, plus `ClaudeSubscriptionStatus` (`claude auth status`). Tested by `Tests/AgentRuntimeIntegration` (live round trip with `WISP_LIVE_CLAUDE=1`). |
| `OpenAIProvider.swift` | ~435 | GPT as a bring-your-own-key `ModelProvider` over Chat Completions: tool results become separate `role:"tool"` messages. |
| `GeminiProvider.swift` | ~415 | Google Gemini as a `ModelProvider`: SSE streaming, native function calls, API key in a request header. |
| `ModelProviderFactory.swift` | ~75 | Builds the `ModelProvider` for the current `BuddyChatProviderSelection`, reading a cloud provider's key from `ProviderKeychainStore`. Used by CompanionManager's turn path. |
| `BuddyChatProviderKind.swift` | ~65 | The provider enum (local Ollama / Anthropic / OpenAI / Gemini) with `displayName`, `sendsScreenshotsOffThisMachine`, `requiresAPIKey`. |
| `BuddyChatProviderSelection.swift` | ~50 | The `UserDefaults`-backed live provider selection. Source of truth, defaulting to local. |
| `ProviderKeychainStore.swift` | ~90 | Per-provider API keys in the login Keychain — never in UserDefaults, Info.plist, or logs. |
| `BuddyVisionChatClient.swift` | ~47 | Legacy chat-client protocol + factory. Superseded by `ModelProvider` on the main path; still used by `BrowserAgent` for its own local vision. |
| `LocalChatterboxTTSClient.swift` | ~231 | Opt-in TTS (`VoiceTTSProvider = chatterbox`) against a self-hosted Chatterbox server: synthesises sentence N+1 while N is playing. |
| `BuddyTTSProvider.swift` | ~90 | TTS protocol and factory, keyed off `VoiceTTSProvider`: Kokoro for `fluid` (the shipped default; `kokoro`/`fluidaudio` accepted), Chatterbox for `chatterbox`, otherwise the Apple synthesizer. `isKokoroConfigured`. |
| `FluidAudioSpeechModels.swift` | ~475 | The one owner of the FluidAudio models: background download (first use) + load + warm-up of Parakeet then Kokoro, published load states for the readout, `ParakeetTranscriptionEngine` (actor; serial decodes, 16 kHz resampling, language hint, background-prepared CTC vocabulary boosting with conservative rescorer settings), `KokoroSynthesisEngine` (actor; voice `af_heart`), and `ProcessMemoryFootprint`. All FluidAudio API use is here (keep the test stub in step). |
| `ParakeetTranscriptionProvider.swift` | ~305 | Default STT provider: per session, Parakeet if loaded and the language is one of v3's 25, else the Apple provider (logged). The Parakeet session buffers mic audio lock-guarded from the tap thread, re-decodes it periodically for live partials, and decodes once more on release (release→final latency logged). |
| `KokoroSpeechSynthesisClient.swift` | ~330 | Default TTS client: Kokoro sentence-by-sentence through `AVAudioPlayerNode` (next sentence synthesised while the current plays), immediate `stopPlayback`, Apple-voice fallback while loading / on failure. Also `KokoroSpeechTextChunker`. |
| `AppleSpeechSynthesisClient.swift` | ~205 | TTS with `AVSpeechSynthesizer` and the built-in macOS voices — on-device, no server, no model memory. Kokoro's fallback, and the client when `VoiceTTSProvider = apple`. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | On-device STT via the Speech framework. Parakeet's fallback, and the provider when `VoiceTranscriptionProvider = apple`. |
| `MicrophoneInputDevices.swift` | ~210 | Microphone fallback: pure `MicrophoneInputChoicePolicy` (lid closed, recently silent, never virtual devices) and `MicrophoneSignalPolicy`, the thread-safe `MicrophoneSignalMeter`, and the CoreAudio/IOKit reads (default + live input devices, clamshell state). |
| `SystemAudioOutput.swift` | ~105 | Whether the default output is muted or at zero (`SystemAudioOutputPolicy`), and `turnSoundOnForDefaultOutput` for the notch's Turn sound on. |
| `SystemReadinessMonitor.swift` | ~90 | Sleep/wake + network reachability for unattended work (`isSettledAfterWake`, `isNetworkReachable`; pure `SystemReadinessPolicy`). |
| `SingleInstanceGuard.swift` | ~50 | Detects another running Wisp, tells it to open its window (distributed notification), so the second copy can quit. |
| `BuddyTranscriptionProvider.swift` | ~60 | STT protocol (`BuddyTranscriptionProvider` / `BuddyStreamingTranscriptionSession`) and the factory: Parakeet (with Apple fallback) unless `VoiceTranscriptionProvider = apple`. `isParakeetConfigured`. |
| `SpokenSentenceStreamer.swift` | ~120 | Token stream → speakable sentences (tags held back). Left over from the retired whole-reply streaming: `CompanionManager` still holds an optional instance but never creates one. |
| `ModelAccessGate.swift` | ~104 | Actor serialising all model calls, with interactive priority, so background work never evicts the prefix cache a live turn depends on. |

### Overlay and annotation
| File | Lines | Purpose |
|------|-------|---------|
| `OverlayWindow.swift` | ~315 | Full-screen transparent overlay (one per screen, a non-activating `NSPanel`): hosts the tool-confirmation card, the command-mode badge, and the annotation layer (markers, boxes, arrows, highlights) via `OverlayContentView`. Draws nothing while idle. Also owns `ignoresMouseEvents` toggling, key focus only for an editable confirmation card (`setAllowsKeyboardFocus`), and the shared `Triangle` glyph. |
| `CommandModeIndicator.swift` | ~135 | The push-to-talk gesture badge: `PushToTalkCommandMode` (Talk / Dictate / Type / Hands-free, with label, icon, destination) and `CommandModeIndicator`, the glass capsule the overlay shows under the notch to name the fired gesture. |
| `ScreenListeningGlow.swift` | ~100 | Ambient "Wisp is listening" cue: a breathing lavender (AI-activity accent) glow around every screen's edges, drawn by the overlay only while `voiceState == .listening`. Honours Reduce Motion (steady glow). |
| `ScreenAnnotation.swift` | ~315 | Parses `[BOX:...]` / `[HIGHLIGHT:...]` / arrow tags. Corner format, lenient about separators. Also the id form (`[BOX:a12:label]`…) via an optional Accessibility-region resolver. |
| `AccessibilityElementSnapshot.swift` | ~305 | Pure, testable side of AX pointing: the snapshot/entry model, compact prompt rendering, role-name mapping, and `AccessibilityElementGeometry` (AX frame → screenshot-pixel region + screen number). |
| `AccessibilityElementSnapshotter.swift` | ~380 | The bounded AX tree walk of the frontmost app (menu bar + focused window, breadth-first, pruned, time/count/depth-capped, off the main actor). |
| `ScreenTextSnapshot.swift` | ~360 | Pure, testable side of OCR pointing: recognised-line model, confidence filter, reading order, prompt caps, compact `t`-id rendering + plain text, line-id → region lookup, Vision→screenshot coordinate flip, and `ScreenTextRecognitionCache` (per-display, keyed on screenshot bytes). |
| `ScreenTextRecognizer.swift` | ~265 | Runs Vision `RecognizeTextRequest` off the main actor for each capture, caches the tasks, and builds a turn's `ScreenTextSnapshot` within a wait budget. Also `CompanionManager.resolveScreenElementRegion` (the shared `a`/`t` id resolver). |
| `ScreenTextReadingTool.swift` | ~60 | The read-only `read_screen_text` agent tool: captures the screen and returns its OCR text. |
| `ScreenWatcher.swift` | ~480 | Pure side of screen watchers: `ScreenWatchCondition`, `ScreenWatchTextMatching` (whole-word normalised matching), `ScreenWatchEvaluator` (successive OCR readings → met / waiting) and `ScreenWatchRequestParser` ("tell me when …", "watch for …", "stop watching"). Tested by `Tests/ScreenWatcher`. |
| `ScreenWatcherStore.swift` | ~350 | Runs the watches: 3s polls of the watched display (own capture + direct OCR, skipped on identical pixels, menu bar dropped), 3-watch cap, 2h timeout, notification, `onWatcherEnded` → `CompanionManager`, and the ending wording. |
| `ScreenWatchAgentTools.swift` | ~95 | `watch_screen` (condition + text) and `stop_screen_watch`, read-only, registered via `registerScreenWatchTools()`. |
| `FastPointing.swift` | ~540 | Pure side of fast pointing: `PointingRequestParser` (spoken "where is X" → target + role hint, conservative), `PointingTargetMatcher` (exact/tolerant word scoring, same-place merging, tie → every place, shortlist for the model, connector-word guard) and `PointingModelFallback` (text-only prompt + lenient reply → id). Tested by `Tests/FastPointing`. |
| `ScreenAnnotationLayer.swift` | ~227 | `Canvas` rendering for markers, boxes, arrows and highlights. |
| `WorkedSolutionExport.swift` | ~140 | Pure: whether the drawings are worth saving (a note or circle), which display's to save, the default PNG name (date + time, no colons), the matching `.md` name and the Markdown text (date, question, numbered notes). Tested by `Tests/WorkedSolutionExport`. |
| `CompanionManager+WorkedSolutionExport.swift` | ~150 | Glue for Save Worked Solution: native-resolution capture of one display, `ImageRenderer` composite of `ScreenAnnotationLayer(isForExport:)`, `NSSavePanel`, PNG + Markdown write, notch confirmation. No test suite (needs screen capture and UI). |
| `ScreenRegionFocus.swift` | ~90 | Pure: `FocusedScreenRegion` (the part of the screen the user chose — clamped, ≥24pt a side, AppKit bottom-left → screenshot top-left pixels, ScreenCaptureKit source rect) and its per-turn prompt text. Tested by `Tests/ScreenRegionFocus`. |
| `PartSelectionRequest.swift` | ~230 | Pure: `PartSelectionRequestParser` (spoken "ask about the third answer" / "explain option C" / "what does the second line mean" / quoted text → `PartSelectionTarget` + residual question; conservative, rejects "third quarter" and "step 2 of …"), `PartSelectionTarget`/`PartSelectionNoun`/`PartSelectionPosition`. Tested by `Tests/PartSelection`. |
| `PartSelectionResolver.swift` | ~380 | Pure: `PartSelectionResolver.resolve(target, in: ocrEntries)` → one screenshot-pixel region or `.notFound`/`.ambiguous`: list-marker detection, column/row list building, ordinals/labels, item region (marker + same-row text + wrapped lines), on-screen text matching. |
| `ScreenRegionPicker.swift` | ~155 | The drag-to-select overlay behind "Ask About a Part…": a dimmed key panel on the pointer's screen, Esc/stray click cancels. |
| `AnnotationClickTarget.swift` | ~210 | Pure: which annotations are clickable, a note's measured size (cached), hit-testing, pointer → overlay coordinates, clicked rect → focused region, and `AnnotationNoteLayout` (nudges overlapping notes apart). |
| `AnnotationClickRouter.swift` | ~140 | Mouse-moved/scroll monitors (running only while something is drawn or selected) that flip the overlay to take the mouse over a clickable note, consume the click, and drop annotations when other content scrolls. |

### Agent, tools and MCP
| File | Lines | Purpose |
|------|-------|---------|
| `AgentTurnRunner.swift` | ~425 | The agent loop: max 4 iterations for the local model, 10 for a cloud model (`maximumIterationsForCloudModels` — acting in an app takes find/read/act/check), screenshot on iteration 0 only, per-tool timeouts. |
| `BrowserCommandRouter.swift` | ~200 | Deterministic recognition of spoken browser commands: tab commands (`BrowserTabCommand`) and clear web tasks, so they run without the model choosing a tool. Conservative — misses fall through to a normal turn. |
| `ChromeExtensionBridge.swift` | ~330 | Loopback-only WebSocket server (127.0.0.1:47823) for the Wisp Tabs extension: Origin-pinned handshake, one live connection, JSON request/response with 10s timeouts, `connectionState` for the Agent tab. |
| `ChromeTabOrganizer.swift` | ~600 | Tab organizing: `ChromeTab`/`ChromeTabsSnapshot`, `ChromeSiteNamer`, `ChromeTabGroupingPlanner` (per-window plans, loose tabs only, stable colours), `ChromeDuplicateTabFinder`, `ChromeTabTopicPrompt` (numbered prompt + strict reply parsing), `ChromeTabCommand`, and `ChromeTabOrganizer` (runs a plan through the bridge). |
| `MessageCommandParser.swift` | ~210 | Pure parsing of spoken message commands ("text X saying Y", "send X a text …", "tell X that Y", unseparated "text X Y" → longest-first splits). Conservative; declines pronouns and noun uses ("text size"). |
| `ContactsDirectory.swift` | ~440 | `ContactRecord`/`ContactHandle` (preferred handle: mobile → phone → email), the pure `ContactMatcher` (ranked tiers, ambiguity, relation words via the Me card), `DirectMessagingHandleParser`, and `ContactsDirectory` (CNContactStore access + off-main fetch). |
| `MessagesSender.swift` | ~175 | `MessageRecipientResolver` (candidates → one person + handle, or a reason, or "not a message command") and `MessagesAppSender` (AppleScript handler call to Messages with Apple Event parameters; iMessage then SMS; -1743 → Automation hint). |
| `WindowManagement/WindowLayoutCommand.swift` | ~700 | Pure side of window management: `WindowPlacement`, `WindowLayoutTarget`/`Assignment`/`Command`, `WindowLayoutApplicationNameMatcher` (unique running-app match), `WindowLayoutCommandParser` (spoken commands + tool-argument placements, conservative), `WindowLayoutReplyText`, and `WindowFrameCalculator` (placement + display visibleFrames → AX frame, primary-height flip, next-display relative move). Tested by `Tests/WindowManagement`. |
| `WindowManagement/WindowLayoutExecutor.swift` | ~300 | Places windows over Accessibility: running-app resolution (regular apps, not Wisp; "this" via `FrontmostAppTracker`), detached AX with a 0.5s timeout, unminimize, position/size/position, raise + activate, `PlacementFailure` reasons. |
| `WindowManagement/WindowManagementAgentTools.swift` | ~85 | The `arrange_windows` agent tool (`registerWindowManagementTools()`). |
| `MediaPlayback.swift` | ~210 | Music control: `MediaPlayback.perform` (play/pause/next/previous in Apple Music or Spotify over AppleScript; a query searches the Music library, Spotify only opens its search), `MediaPlaybackPhraseParser` (whole-utterance phrases routed by `FastCommandRouter`, no model) and the `control_music` agent tool (`.writing(.localMachine)`). |
| `MessageSendConfirmationView.swift` | ~305 | The Siri-style confirmation panel `ToolConfirmationView` shows for `send_imessage` (recipient, an editable message bubble, Cancel / Send); same consent flow underneath. |
| `MessagingAgentTools.swift` | ~150 | `send_imessage` (input prepared before consent) and read-only `find_contact`. |
| `ChromeTabAgentTools.swift` | ~260 | `ChromeTabCommandRouter` (plain spoken commands, questions left to the model) and the five `chrome_*` agent tools. |
| `BrowserController.swift` | ~285 | The DOM-first browser contract: `BrowserElement`/`BrowserPageSnapshot`, element ids instead of coordinates, `BrowserControllerError`, and the `BrowserController` protocol. |
| `AppleScriptBrowserController.swift` | ~1105 | The `BrowserController` for Chrome/Safari: injected JS via AppleScript (one round trip per op, `data-wisp-id` stamping), tab commands, and the dedicated-tab session (`runInTargetTab`). |
| `BrowserAgent.swift` | ~375 | `BrowserAgent.run`: the tiered entry point (deterministic planner → one model-written plan → tier-2 step loop, or `BrowserAgentLoop` for cloud providers), dedicated tab begin/end, login walls as a dead end. |
| `BrowserTask.swift` | ~395 | `BrowserStep`/`BrowserTaskPlan`/`BrowserTaskResult`, `BrowserTaskRunner` (executes a plan end to end) and `BrowserTaskPlanner` (tier 0, no model). |
| `BrowserSiteRegistry.swift` | ~110 | The sites the deterministic planner knows, as data rows. |
| `BrowserPlanValidator.swift` | ~340 | The browser agent's security boundary: model-written JSON → a `BrowserTaskPlan` of fixed actions with validated arguments, or a refusal. |
| `BrowserPlanCache.swift` | ~180 | Caches plans by intent (`wikipedia.search` + query), keeping deterministic and model-written plans apart. |
| `BrowserAgentLoop.swift` | ~720 | Long-horizon browser agent for cloud providers: observe→act loop (cap 30), line-grammar actions incl. batched form fills, stuck detection, untrusted-page prompt rules. Also `BrowserActionSafety` (which clicks/sends need the always-ask confirmation). |
| `BrowserStepLoop.swift` | ~430 | Tier-2 browser control: a bounded per-step observe→act loop (cap 5, DOM-only, one action per model call) that runs only after a tier-1 plan fails. Defines `BrowserCursorGuide`, which marks each element with a pulsing ring before it acts. |
| `AgentToolRegistry.swift` | ~710 | Built-in tools (read-only, plus the confirmation-gated `remember`/`forget` memory tools and `create_reminder` write) + `register`/`unregister`. `requiresConfirmation` defaults to true for unknown names. `definitions(forRequest:)` delegates to `AgentToolRouter`. `register(_:preparingInputWith:)` takes an optional `ToolInputPreparer` that turns the model's arguments into the concrete ones *before* the approval (the card then describes what will really run) or ends the call with a reason. |
| `AgentToolScope.swift` | ~130 | Deterministic built-in scope vocabulary (browser/filesystem/coding/memory/messaging/general) + `alwaysAvailableToolNames` + the per-turn budgets (`maximumExposedTools` = 6 local, `maximumExposedToolsForCloudModels` = 16). Used by the router as a relevance bonus. |
| `AgentToolRouter.swift` | ~150 | Per-turn tool selection: ranks every registered tool by lexical relevance to the request (name words weighted over description), scope membership (or a caller's `boostedToolNames`, e.g. `run_shortcut` when the request names a shortcut) adds a bonus, returns the top few within budget. Deterministic, model-free. |
| `StructuredTextToolProtocol.swift` | ~330 | `[TOOL:name:{json}]` prompt generation and lenient parsing, with an anti-echo guard. |
| `MCPClient.swift` | ~445 | `MCPServerConnection`: transport-agnostic JSON-RPC 2.0 framing, timeouts, and the MCP handshake. Picks a transport via `makeTransport(for:)`. `MCPStartupTimeoutPolicy` gives a package runner's `initialize` a long first-run budget. `callToolReturningContent` keeps a result's text blocks and `structuredContent` apart; `callTool` returns the text only. |
| `MCPToolResultRendering.swift` | ~290 | Pure: an MCP result → the model's text. Element lists (token + role) as one line each under a scalar-field header, other structured content as sorted compact JSON, 4000/5000-char caps, duplicate-JSON text dropped; no `structuredContent` → unchanged. Tested by `Tests/MCPStructuredContent`. |
| `CuaDriverSupport.swift` | ~215 | cua-driver specifics: `CuaDriverToolNames` (server-namespace match, read-only allow-list, `mustAlwaysAsk`, which tools skip the card, model-facing descriptions, misaddressed-call refusal), `CuaDriverToolRouting` (when a request is about operating a native app, so its tools are offered) and `CuaDriverElementCache` (token → role/label/app from the last 4 element lists, fed by `MCPManager`, read by the confirmation card). |
| `MCPTransport.swift` | ~55 | The `MCPTransport` protocol: start/send/incomingMessages/recentDiagnostics/close. Isolates byte transport + framing from JSON-RPC. |
| `MCPStdioTransport.swift` | ~300 | Stdio transport: child process over stdin/stdout as NDJSON (pipes read via `readabilityHandler`, framed by the pure `NewlineDelimitedLineBuffer`), login-shell PATH resolution (`LoginShellEnvironment`), stderr ring buffer. |
| `MCPStreamableHTTPTransport.swift` | ~230 | Remote transport: JSON-RPC over MCP Streamable HTTP (one POST per message; parses JSON + SSE replies; `Mcp-Session-Id`, auth headers). |
| `MCPCatalog.swift` | ~90 | Marketplace catalog model: `MCPCatalogEntry` (stdio/remote install template) + `ConfigField` (user-supplied env/header, secret flag) + the bundled-registry file shape. |
| `MCPCatalogProvider.swift` | ~55 | `MCPCatalogProvider` protocol + `CuratedRegistryCatalogProvider` (loads the bundled `curated-mcp-registry.json`). Composio's provider will conform here in Phase 3. |
| `curated-mcp-registry.json` | ~180 | Bundled curated MCP registry (resource): 8 official stdio servers + the hosted GitHub remote server. |
| `InstalledMCPServerStore.swift` | ~270 | Source of truth over `~/.wisp/mcp.json` (preserves unknown keys). Install/uninstall/enable/allow-list + `installRemoteServer` (Composio); reloads MCPManager on every change. |
| `ComposioKeychainStore.swift` | ~75 | The Composio connect key in the login Keychain (sent as `x-consumer-api-key` at connect time) (mirrors `ProviderKeychainStore`). Never in the config file or logs. |
| `ComposioClient.swift` | ~110 | Validates the Composio **connect** key by an MCP `initialize` against `https://connect.composio.dev/mcp` (auth header `x-consumer-api-key`). No provisioning — the connect server is a fixed universal endpoint. |
| `ComposioConnectionsStore.swift` | ~280 | Per-app Composio state for the Marketplace list: calls the connect server's `COMPOSIO_MANAGE_CONNECTIONS` (`list`/`add`/`remove`) over its own `MCPServerConnection` with the saved key; Connect opens the sign-in link in the browser and polls until the account is active (also re-checks when Wisp becomes active); Reconnect clears the stale account. Curated 20 apps (`ComposioApp.curated`) + any typed name. |
| `ComposioAppsView.swift` | ~290 | The app list UI: logos from `logos.composio.dev/api/<slug>` (SVG via `NSImage`, cached, initial fallback), Connected/Available sections, search, per-row Connect/Reconnect/Disconnect. |
| `ComposioAccountStore.swift` | ~110 | Composio marketplace state: `connect(apiKey:)` validates the key then installs one remote server (`composio-connect`) over the Phase 1 transport; `disconnect()` removes it. Off-machine/opt-in. |
| `MCPManager.swift` | ~400 | Reads `~/.wisp/mcp.json`, connects servers concurrently (Connecting… → Installing… for slow package runners; stale connects from an overlapping reload discard themselves), namespaces tools `server__tool`, registers all allowed tools (no registration cap — the per-turn router selects), injects the Composio Keychain key at connect time, `reload()`. `MCPConnectionFailureMessage` appends the server's last stderr line to a failure. |
| `ClaudeCodeWorker.swift` | ~215 | Runs the `claude` CLI as a background worker for the `delegate_coding_task` tool (parses its event stream into progress + result). Off-machine, only when that tool is called. |
| `SkillManager.swift` | ~120 | Reads `~/.wisp/skills/*.md`, parses `name`/`description` frontmatter, serves full bodies on demand via `load_skill`. |
| `RoutineStore.swift` | ~270 | Routines: user-fired saved instructions (`WispRoutine`: name, instruction, symbol, optional chord+digit shortcut, suggested app bundle ids, pinned-in-notch). Persists to `~/Library/Application Support/Wisp/routines.json`; seeds 4 starters when the file is absent. `notchSuggestions(forAppBundleIdentifier:)` powers the notch's app-aware section. Distinct from skills (model-loaded reference). |
| `FrontmostAppTracker.swift` | ~55 | Last frontmost app that isn't Wisp (NSWorkspace activation notifications), so suggestions survive opening the Wisp window/composer. |
| `RoutineParameters.swift` | ~140 | Pure routine blanks: `{name}`/`{name|default}` parsing, prefill values, filling in (clipboard fenced as data, date, time). Tested by `Tests/RoutineParameters`. |
| `RoutineParameterPrompt.swift` | ~65 | The native dialog that asks for a routine's blanks before it runs. |
| `WispShareBundle.swift` | ~190 | Pure share format: `SharedRoutine`/`SharedBuddy`/`WispShareBundle`, export of setup only, validating + cleaning an imported file, `WispShareReview` text. |
| `WispShareImporter.swift` | ~170 | Save/open panels, the import review dialog, and adding imported items inert. |
| `RoutinesTab.swift` | ~450 | Routines page: list + auto-saving editor (name, instruction, icon, shortcut digit with "used by" warnings, suggested apps from running apps or /Applications, pin toggle, Run now — closes the Wisp window first so the screenshot sees the user's work). |
| `SkillIndex.swift` | ~35 | Terse per-line skill index appended to the system prompt alongside tool instructions. |
| `ShortcutsBridge.swift` | ~455 | Apple Shortcuts via `/usr/bin/shortcuts`: `ShortcutsListParser` (`list --show-identifiers` → name + UUID), `ShortcutsCommandLine` (argument arrays; name after `--`), `ShortcutsProcessRunner` (off-main `Process`, both pipes drained, timeout + cancellation terminate), `ShortcutRunResultFormatter` (capped text for the model), and the `ShortcutsBridge` ObservableObject (5-min cached list, availability, `runShortcut(named:textInput:)` with exact-name resolution and temp-file I/O). |
| `ShortcutsAgentTools.swift` | ~280 | `ShortcutNameMatcher` (request → matching shortcut names; exact-name resolution), `ShortcutsToolRouting` (boost hints + per-turn `run_shortcut` description naming ≤3 matches; the `list_shortcuts`/`run_shortcut` definitions), and `AgentToolRegistry.registerShortcutsTools()`. |
| `ConversationHistoryStore.swift` | ~420 | Persists the last 20 transcript turns to `~/Library/Application Support/Wisp/conversation.json` (Codable `Persisted*` shapes, images dropped, debounced + flushed on quit) and hands back the ≤6h-old ones to resume on launch. `ConversationHistoryCodec` holds the pure encode/decode/merge/resume policy. |
| `MemoryStore.swift` | ~330 | `~/.wisp/memory.md` user memory: `MemoryFileFormat` (pure bullet parse/append/remove), `MemoryIndex` (the ≤800-char system-prompt block, newest facts first), and the `MemoryStore` ObservableObject behind the `remember`/`forget` tools and the Memory tab. |
| `ToolConfirmationCoordinator.swift` | ~530 | Permission requests with a 45s timeout and spoken-affirmative parsing. `requestApproval(toolName:toolInput:)` applies the `ToolCallSafety` floor under session auto-approve and attaches the `ToolConfirmationCardBuilder` card to `PendingConfirmation.confirmationCard`. `requestApprovalAllowingEdits` also offers the call's editable fields and returns a `ToolApprovalOutcome` (decision + edits); holds the typed edits and the movable expiry (`updateEditedText`, `extendTimeoutForEditing`). Defines `ToolPermissionBroker` and `ToolApprovalOutcome`. |
| `ToolConfirmationView.swift` | ~285 | The confirmation card on the island's surface (`wispNotchIslandSurface` + warning rim + `WispMark`): a plain-words headline (not the lowercase spoken question), the optional confirmation card (`GlanceCardView`, minus the rows its editable fields replace), the editable fields, the exact call (with edits) folded into one line, island-style Cancel / Allow→ (Cmd-Return, accessibility-labelled), "or just say yes". Presented via the existing overlay plumbing, positioned under the notch; calls `flashIsland(.success/.error)` on allow/deny. |
| `EditableConfirmationFields.swift` | ~250 | Pure rule for inline-editable confirmation fields: which top-level string arguments a call offers (by tool name or card shape), `applyingEdits` (ignores any non-editable key, blank or unchanged edits), the tool-result note telling the model what the user changed, and hiding the card rows the fields replace. Tested by `Tests/EditableConfirmation`. |
| `EditableConfirmationFieldView.swift` | ~125 | One editable card field: reads as card text until hovered (fill, pencil, I-beam), single-line `TextField` or multi-line `TextEditor`, focus counts as editing activity, "edited" mark (`EditedConfirmationFieldMark`). |
| `ToolCallInspection.swift` | ~325 | Deterministic reading of a tool call: `server__` namespace stripping, identifier → words (camelCase/underscores), Composio execute-meta-tool unwrapping into `InspectedToolAction`s (tolerates JSON-string arguments), lenient case/underscore-insensitive argument lookup, display text for arrays/objects, path-argument extraction and `..`-safe path containment. |
| `ToolMetadata.swift` | ~100 | What a tool does (read-only, destructive, external side effect, data source) as data; whether it needs confirmation is computed from it. |
| `ToolCallSafety.swift` | ~185 | The destructive-action floor under session auto-approve: `mustAskEvenWithSessionAutoApprove(toolName:toolInput:agentWorkingDirectoryPath:)`. Word vocabularies (always-irreversible verbs, noun-ish words that count only without a reading verb), command execution, calendar invites, writes outside the agent folder, Composio meta-tool rules, `alwaysAskBareToolNames` (`run_shortcut`), and every non-read cua-driver tool (`CuaDriverToolNames.mustAlwaysAsk`). |
| `ToolConfirmationCardBuilder.swift` | ~790 | Builds the confirmation panel's `GlanceCard` from a call: Run Shortcut (by name) / cua-driver action (element resolved via `CuaDriverElementCache`) / email / message / post / event / file write / deletion / other-irreversible / Composio batch; nil for reads and unknown shapes. Truncates bodies (180 chars) and field values (80). Exposes the shape it chose (`ConfirmationCardShape`) and its key vocabularies for the editable fields. |
| `BackgroundTaskLauncher.swift` | ~127 | Tasks that outlive the conversation, max 2 concurrent, notify on completion. |
| `AgentTaskRegistry.swift` | ~165 | Task and step records backing History → Timeline. Loads saved history on launch and saves it (debounced) on every change. |
| `AgentTaskHistoryStore.swift` | ~110 | Persists the task records to `~/Library/Application Support/Wisp/task-history.json` (0600): 30-day retention, still-running tasks come back as `.interrupted`, sync flush on quit. |

### Brain
| File | Lines | Purpose |
|------|-------|---------|
| `Brain/BrainPage.swift` | ~455 | Pure page model: `BrainPageKind` (folders, symbols), frontmatter parse/render, `BrainSlug` (safe slugs, comparable names), `[[link]]` parsing, `## Section` split/join. |
| `Brain/BrainEdit.swift` | ~550 | `BrainEditProvenance` (origin + trust), `BrainEditProposal`, lenient `BrainEditProposalParser`, and `BrainEditPlanner` — the validator every brain write goes through. |
| `Brain/BrainSearch.swift` | ~205 | BM25 `BrainSearchIndex` (field-weighted, whole-word name boost) and `BrainPromptContext` (the per-turn relevant-pages block). |
| `Brain/BrainStore.swift` | ~650 | The vault: layout + seeding, page load/resolve/backlinks, `apply` (versioned, one change record, optional deletions), hand edits, undo, index.md/log.md, raw sources, Finder/Obsidian opening. |
| `Brain/BrainSchema.swift / BrainPreferences.swift` | ~50/~65 | Default SCHEMA.md + the edit-proposal prompt rules; the brain's UserDefaults switches (activity off by default). |
| `Brain/BrainAboutMe.swift / BrainMemoryMigration.swift` | ~155/~145 | me-page facts → system-prompt block, remember/forget edits; one-time memory.md → me.md migration. |
| `Brain/BrainAgentTools.swift / BrainCommandRouter.swift` | ~350/~240 | `search_brain`/`read_brain_page`/`add_to_brain`/`ingest_into_brain`; deterministic "add this to my brain" parsing + front-tab/Finder target resolution. |
| `Brain/BrainKnowledgeExtractor.swift` | ~350 | Source text → edit proposals: per-chunk model calls with relevant page titles, one stricter retry, source-page summary call. |
| `Brain/BrainIngestQueue.swift / BrainIngestJob.swift` | ~615/~140 | Serial persisted ingest queue (raw copies, trust mapping, History rows, one drain notification) and the job type + codec. |
| `Brain/BrainTextExtractor.swift / BrainTextChunker.swift` | ~685/~215 | md/txt/PDF/HTML/RTF/DOCX extraction, HTML→text, user-requested web fetch; heading/paragraph chunking with even sampling. |
| `Brain/BrainIngestProposalMerger.swift / BrainIngestFileRules.swift / BrainInboxWatcher.swift` | ~405/~125/~115 | Cross-chunk merge + batch fitting + source page; supported types and inbox stability rules; `raw/inbox/` poller. |
| `Brain/BrainConversationDigester.swift / BrainConversationDigestPlanning.swift` | ~225/~410 | Periodic digest of ended conversation sessions; pure exchange filtering, substance heuristic, material + state. |
| `Brain/BrainNotesImporter.swift / BrainNotesImportPlanning.swift / BrainNotesImportAppleNotes.swift` | ~370/~255/~185 | Folder/Obsidian import (hash-deduped, capped) and Apple Notes export via a parameterised AppleScript. |
| `Brain/BrainActivityRecorder.swift / BrainActivitySampler.swift / BrainActivityLog.swift / BrainActivitySummary.swift / BrainActivityExclusions.swift` | ~360/~230/~245/~420/~205 | Opt-in activity feed: sampling, exclusions, day spans (0600 files, 30-day retention), summaries, daily local-model digest. |
| `Brain/BrainLinter.swift / BrainLintChecks.swift / BrainPageMerger.swift / BrainPageSplitter.swift` | ~230/~595/~255/~190 | `BrainMaintenance` (periodic lint + fixes) and the pure checks, duplicate merge with relinking, and oversized-page split. |
| `WispWindow/Brain/BrainPagesPage.swift / BrainPageReaderView.swift / BrainPageEditorView.swift` | ~445/~390/~155 | Brain → Pages: search/grouped list, markdown reader with in-app `[[links]]`, chips, backlinks, back/forward; raw-markdown editor with rename. |
| `WispWindow/Brain/BrainGraphPage.swift / BrainGraphLayout.swift` | ~465/~340 | Brain → Graph: Canvas force-directed graph (clock stops when settled/hidden) and the pure layout + fast link resolver. |
| `WispWindow/Brain/BrainInboxPage.swift / BrainHealthPage.swift / BrainLogPage.swift / BrainSettingsPage.swift` | ~675/~370/~270/~610 | Inbox (drop zone, jobs, notes import), Health (overview + fixes), Log (undo), Settings (switches, activity privacy, vault, conversation history). |
| `WispWindow/Brain/BrainSharedViews.swift / BrainMarkdownRendering.swift` | ~495/~330 | Shared navigation state, chips, markdown view; pure markdown block parser and `wisp-brain://` link rewriting. |

### Jobs (Canvas calendar + daily checklist)
| File | Lines | Purpose |
|------|-------|---------|
| `Jobs/JobsEngine.swift` | ~480 | `@MainActor JobsEngine` (published sync state, diff, pending study blocks, today's checklist, access states) plus `JobsToolNames` and the injectable protocols (`JobsFeedProviding`, `JobsCalendarWriting`, `JobsReminderWriting`, `JobsStudyBlockApproving`, `JobsChangeAnnouncing`). Launch sync, then a 60s clock: sync at most hourly (15-minute floor even for Sync now), checklist rebuilt once per morning (5am-5pm). Snapshot saved only after every write succeeded; empty diff is silent. State in `jobs-engine-state.json` (0600). Tested by `Tests/JobsEngine`. |
| `Jobs/JobsEngineLiveDependencies.swift` | ~130 | The real adapters (feed store, Keychain, the two EventKit actors, `ToolConfirmationCoordinator` approval, notification + island flash, quiet-mode aware) and `JobsEngine.shared`. `NotchWindowController.show()` sets the flash hook and calls `JobsEngine.shared.start()`. |
| `Jobs/Canvas*.swift`, `Jobs/StudyBlockPlanner.swift` | ~800 | Pure Canvas core: models, ICS parser, snapshot diff, study-block planner, URL validator, Keychain store and feed store. Tested by `Tests/CanvasSync`. |
| `Jobs/ChecklistModels.swift`, `Jobs/DayChecklistBuilder.swift` | ~550 | Checklist model, the pure builder (rollover, cap, dedupe) and `JobsEventKitPlanning` (write plans). Tested by `Tests/DayChecklist`. |
| `Jobs/WispCalendarWriter.swift`, `Jobs/WispTodayReminders.swift` | ~470 | Thin EventKit actors for the "Wisp" calendar and the "Wisp Today" list. |

### Automations, quick add, first run
| File | Lines | Purpose |
|------|-------|---------|
| `Automations/Automation.swift` | ~320 | Pure `Automation` and its trigger/event/source/action/output/notify enums, `AutomationLegacyOrigin`, validation, blanks, cloud-privacy rule. |
| `Automations/AutomationSchedule.swift` | ~480 | Pure schedules: next run (DST-safe), missed-slot rule, plain-words summary. Tested by `Tests/AutomationSchedule`. |
| `Automations/AutomationDraft.swift` / `AutomationDraftParser.swift` | ~250/~745 | Draft card model and the deterministic "say it" parser (+ model-assist prompt/reply that only fills the card). Tested by `Tests/AutomationDraft`. |
| `Automations/AutomationTemplates.swift` | ~155 | The eight gallery templates, as data. |
| `Automations/AutomationStore.swift` / `AutomationRunRecord.swift` | ~300/~255 | Persistence of automations and run history (0600, 30-day retention), default-buddy assignment. |
| `Automations/AutomationEngine.swift` | ~1000 | Clock, run rules, `AutomationToolPolicy`, unattended-safe runs, history to "Needs you". Tested by `Tests/AutomationEngine`. |
| `Automations/AutomationLiveWiring.swift` | ~515 | Real adapters (model via `startAutomationRun`, EventKit, notifications, notch, JobsEngine, watchers). |
| `Automations/AutomationMigration.swift` / `AutomationMigrationRunner.swift` | ~170/~125 | Pure plan and one-time runner from Routines, buddy jobs and Jobs. Tested by `Tests/AutomationMigration`. |
| `WispWindow/Automations/*.swift` | ~3000 | `AutomationsHubView` (say-it box, list, gallery; embedded in Buddies), `AutomationDraftCardView`, chip editors, run history, next-runs tile, template gallery, `BuddyAutomationsSection`, `SaveAsAutomationButton`, display text/support. |
| `QuickAdd/AutomationQuickAddPlanner.swift` / `AutomationQuickAddRouter.swift` | ~70/~35 | Pure "is this an automation?" decision and the router that opens the draft card. Tested by `Tests/AutomationQuickAdd`. |
| `FirstRun/FirstRunSetupFlow.swift` / `WispFirstRunState.swift` | ~305/~40 | The four-step first-run setup and its once-only flag. |

### Themes and buddy personality
| File | Lines | Purpose |
|------|-------|---------|
| `DesignSystem/WispTheme.swift` | ~265 | Pure `WispTheme` definitions (six themes; the only place theme hex lives). |
| `DesignSystem/WispThemeStore.swift` | ~150 | Chosen theme, island-tint and Playful switches, thread-safe cache for dynamic colours, `.wispThemeDidChange`. |
| `DesignSystem/WispThemeContrast.swift` | ~170 | Pure contrast-ratio checks per theme, light and dark. Tested by `Tests/WispTheme`. |
| `Components/WispThemeBackdrop.swift` / `WispThemePicker.swift` | ~165/~120 | The window's blurred-gradient backdrop and the swatch picker. |
| `WispWindow/AppearanceSettingsCard.swift` | ~45 | Settings → General → Appearance: window appearance, themes, island tint, Playful. |
| `Buddies/BuddyPersonality.swift` / `BuddyPersonalityPicker.swift` | ~190/~65 | Five personality presets (persona, reply style, voice profile) and the picker. Tested by `Tests/BuddyPersonality`. |
| `Buddies/StarterBuddies.swift` / `BuddyGreeting.swift` | ~80/~85 | Planner/Briefer/Focus starters with fixed ids; the day's-buddy rule and greeting. |
| `Buddies/ChecklistStreak.swift` / `PlayfulCelebration.swift` | ~110/~110 | Day-key streak store and the squish/burst, gated by Playful. |

### Voice modes, glance cards & sources
| File | Lines | Purpose |
|------|-------|---------|
| `VoiceOutputPreference.swift` | ~50 | Source of truth for voice/silent mode (reply speech on/off). Persists; defaults on. |
| `WispSoundPlayer.swift` | ~120 | The Dynamic Island's interaction sound cues (listening / thinking / reply / success / error), played as built-in macOS system sounds at low volume. `WispSoundPreference` is the UserDefaults-backed on/off gate (default on), toggled from the notch header's bell button. Separate from reply speech (`VoiceOutputPreference`). |
| `SpokenLineParser.swift` | ~90 | Parses/strips the `[SAY: …]` tag — the model's per-reply "speak this" line. |
| `GlanceCard.swift` | ~655 | `[CARD:…]` parser + intent model (`GlanceCardRequest`/`ResolvedGlanceCard`, incl. `RemindersCardRequest`/`TimerCardRequest`) and the generic block card. |
| `FastCommandRouter.swift` | ~520 | Model-free handling of rigid commands (mute/volume, open an app, and "set a timer for …" via `TimerCommandParser`, whose `Outcome.glanceCardRequest` CompanionManager resolves like a `[CARD:]` tag). Biased toward not matching. |
| `GlanceCardView.swift` | ~180 | Renderer for the generic block card (header/list/keyValue/stats). |
| `GlanceCardDataPreference.swift` | ~40 | The single gate for **network** card data (weather, sources). Default on. |
| `WeatherSnapshot.swift` / `WeatherDataProvider.swift` / `WeatherCardView.swift` | ~330/~200/~260 | Weather kind: Open-Meteo fetch → snapshot → Apple-Weather-style card. |
| `CalendarSnapshot.swift` / `CalendarDataProvider.swift` / `CalendarCardView.swift` | ~50/~110/~160 | Calendar kind: EventKit on-device read → next events card. Needs Calendar permission. |
| `NowPlayingDataProvider.swift` / `NowPlayingCardView.swift` | ~150/~110 | Now-playing kind: AppleScript to Music/Spotify (best-effort, on-device). Needs Automation permission. |
| `PlacesSnapshot.swift` / `PlacesDataProvider.swift` / `PlacesCardView.swift` | ~85/~230/~250 | `places` kind: CoreLocation one-shot (`WispLocationProvider`, in the provider file) + MapKit `MKLocalSearch` → a Maps-style nearby-results card whose rows open in Apple Maps. Network-gated by `GlanceCardDataPreference`; requests Location permission on first use. |
| `RemindersSnapshot.swift` / `RemindersDataProvider.swift` / `RemindersCardView.swift` | ~210/~215/~240 | `reminders` kind: EventKit on-device read → incomplete-reminders card (rows open Reminders.app). The snapshot file also holds the pure `RemindersSelection` (overdue/today/all filtering + ordering) and `ReminderDueDateParser` (ISO 8601 variants for `create_reminder`); the provider also saves reminders for the confirmation-gated `create_reminder` tool. Needs Reminders permission (`NSRemindersFullAccessUsageDescription`). |
| `WispTimerStore.swift` / `TimerCardView.swift` | ~235/~225 | `timer` kind: the main-actor store that owns countdowns (completion task, scheduled `UNUserNotification`, finish callback) independent of any card, plus `WispTimerDurationFormatter`; the card is a live countdown (`CountdownSecondTickSchedule`, paused when off-screen) with a Cancel button. |
| `ConfiguredSourceStore.swift` / `RESTSourceDataProvider.swift` / `SourceCardView.swift` | ~90/~140/~90 | `source` kind: user endpoints in `~/.wisp/sources.json`, fetched over HTTPS and mapped to generic blocks. |
| `SourcesTab.swift` | ~150 | Connections → Sources: the live-card-data master toggle + the configured-source list. |

### Jobs
| File | Lines | Purpose |
|------|-------|---------|
| `Jobs/CanvasModels.swift` | ~120 | Pure `CanvasItem`, `CanvasItemChange`, `CanvasDiff`, `CanvasSnapshot`, study-block types (`StudyBlockSettings`, `StudyBlockProposal`, `BusyInterval`). |
| `Jobs/CanvasFeedParser.swift` | ~300 | Pure ICS -> `CanvasItem`s; never throws, a malformed VEVENT is skipped (and counted). |
| `Jobs/CanvasSyncPlanner.swift` | ~95 | Pure snapshot diff (first sync = everything added). |
| `Jobs/StudyBlockPlanner.swift` | ~145 | Pure study-block proposals from due items, busy intervals and settings. |
| `Jobs/CanvasFeedStore.swift` / `CanvasFeedKeychainStore.swift` | ~190/~70 | Feed URL validation + fetch + 0600 snapshot JSON; the URL's Keychain item. |
| `Jobs/ChecklistModels.swift` / `DayChecklistBuilder.swift` | ~85/~490 | `ChecklistItem` and the pure daily-checklist builder (rollover, caps, day keys). |
| `Jobs/WispCalendarWriter.swift` / `WispTodayReminders.swift` | ~285/~205 | Actors writing only the "Wisp" calendar and the "Wisp Today" Reminders list (EventKit). |
| `Jobs/JobsEngine.swift` / `JobsEngineLiveDependencies.swift` | ~690/~135 | The orchestrator (launch + hourly sync, diff, study-block approval, checklist rebuild, published state for the window and notch) and its live EventKit/network wiring. |
| `WispWindow/JobsTab.swift` | ~515 | Canvas page (inside Buddies): Canvas setup flow, sync status, change cards, study-block approval, settings. |
| `WispWindow/WispAdvancedFeaturesPreference.swift` | ~35 | Persisted Advanced features switch (`isEnabledNow` for non-UI code); hides delegation, per-buddy models, sharing and four sections, never buddies. |
| `DynamicIsland/DailyChecklistView.swift` / `CanvasDiffCardView.swift` | ~130/~100 | The notch's tickable checklist and Canvas change card. |

### Wisp window, notch and UI
| File | Lines | Purpose |
|------|-------|---------|
| `WispWindow/WispNavigation.swift` | ~175 | `WispSection` (sidebar destinations, grouped use/manage) + `WispPage` (every page and its section), `WispWindowRouter` (shared selection, last page per section) and `WispWindowNavigator.open(_:)`. Also the `.wispDismissPanel` / `.wispCloseNotchWorkspace` notification names. |
| `WispWindow/WispWindowController.swift` | ~125 | The Wisp window: `NSWindow` + `NSHostingController` with title/toolbar bridging, unified toolbar, frame autosave, full-screen capable. `WispWindowActivation` raises `.regular` while a titled window is open and drops back to `.accessory` after. |
| `WispWindow/WispWindowView.swift` | ~330 | The shell: the top bar of section tabs (dot badges: running tasks on History, working buddies on Buddies, ingest on Brain, a missing permission on Settings), the page strip, the page switch, and the status pill (mark + state + model, collapsing to the mark when narrow). |
| `Components/WispSegmented.swift` | ~50 | The window's segmented control (quiet track, raised sliding thumb); replaces the system segmented picker in settings pages. |
| `WispWindow/WispAppearancePreference.swift` | ~55 | Window appearance: System / Light / Dark, applied to the Wisp `NSWindow` only. |
| `Components/WispPill.swift` | ~140 | `WispBevel` (raised surface) and `WispPillButtonStyle` (the window's one button style). |
| `WispWindow/ChatPage.swift` | ~440 | Chat: the last 6 hours of interactive exchanges as a thread (running turns show the live browser step + Stop, answers have Copy), a follow-up box (`askTypedQuestion`; capture excludes Wisp's own windows), and a side column of running and recently finished tasks. Opened by the notch's expand button via `openConversationWindow()`. |
| `WispWindow/BuddiesPage.swift` | ~150 | Buddies: a list of buddies + the selected one's `BuddyDetailView` or `NewBuddyForm`; a single invitation when there are none. |
| `WispWindow/GeneralSettingsPage.swift` | ~330 | Settings → General: `PermissionsChecklist` (mic / accessibility / screen recording / screen content with Grant buttons — also shown on Today until granted), `ActiveStackCard` (model + residency, speech, voice, agent mode, local-only assurance), island surface, speak replies, sound cues and `VoiceUpgradeHint`. `SettingRow` is the shared title/detail/control row. |
| `WispWindow/ModelSettingsPage.swift` | ~465 | Settings → Model (`PerformanceTab`: provider choice + API key, system readouts, timings) and the shared `DashboardCard` (native grouped card) and `DashboardEmptyState` (`ContentUnavailableView`). |
| `HistoryTab.swift` | ~480 | The History **Timeline** page (`WispPage.timeline`): search (title/answer/steps), filters (All · Answers · Browser · Tools · Needs attention), day-grouped list, and a detail pane — answer, failure reason, "What Wisp did" steps, and actions: Stop, Copy answer, Ask again (closes the Wisp window first) and **Save as routine** (creates a `WispRoutine` and hands it to the Routines editor via `RoutineStore.routineIDToOpenInEditor`). Routine, skill and dictation runs are titled with `AgentTaskRecord.routineRunTitlePrefix`/`skillRunTitlePrefix`/`dictationTitlePrefix` (set via `sendTranscriptToClaudeWithScreenshot(transcript:historyTitle:)`), and `isUsersOwnQuestion` hides re-ask/save for them. |
| `HomeTab.swift` | ~1345 | The Wisp window's **Today** page as a bento grid of `WispBentoTile`s: a hero (greeting, the `WispMark` moving with `islandState` + live transcript/browser step, a signature-gradient wash that drifts only while Wisp is active, the ask bar — typed question via `CompanionManager.askTypedQuestion`, or `/` to filter and run routines — and a voice/silent toggle); a Today tile (answers / buddy runs / brain changes today + 12-hour activity bars, opens History); "Needs you" alerts with fixes (Ollama/Chatterbox unreachable — localhost checks every 30s, only for services in use — pending confirmation, a failed/interrupted task in the last 2h); Running now (live rim, per-task Stop); Buddies (avatars bob while working, unread dot; rows open that buddy via `WispWindowRouter.buddyIDToOpen`, + opens the new-buddy form); Up next (Calendar, requests access only from its Connect button); Brain; Routines (hover turns the icon into play); Recent answers (Copy on hover). Two columns when wide, one when narrow. Anything it runs closes the Wisp window first so the screenshot shows the user's work. |
| `DashboardToolsTab.swift` | ~253 | Tools & Servers tab: MCP status, per-server stderr, registered tools. |
| `MarketplaceTab.swift` | ~700 | Connections → Marketplace: browse/search/filter the curated registry, install (config-field sheet for keys), enable/disable, remove, per-tool toggles, the model tool-budget meter, and a Composio cloud-toolkits section (key entry + toolkit list + off-machine label). Reads `InstalledMCPServerStore` + `MCPManager` + `ComposioAccountStore`. |
| `ShortcutsTab.swift` | ~250 | Settings → Shortcuts: view/rebind the hold chord and hands-free double-tap, toggle hands-free, reset to defaults. Reads/writes `ShortcutBindingStore`. |
| `ActiveStackReadout.swift` | ~130 | "What's running": configured model/STT/TTS names from Info.plist (Parakeet/Kokoro rows show the download/load state and the Apple engine standing in until ready) plus Ollama residency, for the Wisp window's status pill and Settings → General's What's running card. Also labels perf timings and "Asking …" steps. |
| `MenuBarMenuController.swift` | ~180 | The menu bar item: the ribbon template icon and a native `NSMenu` rebuilt on open (status line, talk hint, Finish Setup… when a permission is missing, Ask Wisp…, Ask About a Part…, Save Worked Solution… (enabled only with a note or circle on screen), Open Wisp, Chat, Buddies, Pause Listening / Speak Replies / Sound Cues checkmarks, Settings…, Quit); dims the icon while paused. |
| `NotchWindowController.swift` | ~620 | Hosts the notch HUD in a borderless non-activating `NotchPanel`. Polls `NSEvent.mouseLocation` against fixed hot-zones (with hysteresis) to expand/collapse, and toggles `ignoresMouseEvents` so the window is click-through while collapsed. Force-collapses on `.wispDismissPanel` (so it's out of the way of a skill launch or push-to-talk capture) — except while the workspace is open — and reloads skills when the panel opens. `setWorkspacePage` grows/shrinks the window for the chat/settings workspace and toggles `NotchPanel.allowsBecomingKey`. Owns `NotchViewModel`. |
| `NotchHUDView.swift` | ~1425 | The notch HUD's SwiftUI content: collapsed pill (the liquid `WispMark` + live state dot) and the hover-expanded quick-panel — shortcuts cheat-sheet, a **SKILLS grid of one-click launcher chips** (each runs its skill via `CompanionManager.runSkill`), active integrations, and a dock-cursor toggle in the header. Pins `.colorScheme(.dark)`; mark/dot/label are driven by `companionManager.islandState`. `DS.*` throughout. |
| `NotchFileDrop.swift` | ~75 | Drop a file on the notch to add it to the brain: `NotchFileDropView` (a transparent `hitTest`-nil sibling above the hosting view; wrapping it, registering it, or SwiftUI `.onDrop` all failed to receive drags) and `NotchFileDragDetector` (drag-pasteboard change count + held button, so window drags never misfire). `NotchWindowController.updateFileDragState` opens the island under a file drag (brain on only) and `addDroppedFilesToBrain` enqueues supported files on `BrainIngestQueue`, showing the result via `viewModel.fileDropFeedback`. |
| `NotchGeometry.swift` | ~85 | Resolves collapsed/expanded window frames from `NSScreen.safeAreaInsets` + `auxiliaryTop{Left,Right}Area`, with a floating-pill fallback on non-notch Macs. |
| `DesignSystem.swift` | ~480 | The legacy `DS.*` token **facade**: `DS.Colors`, `DS.Spacing`, `DS.CornerRadius`, `DS.Animation` now forward to the `Wisp*` tokens in `DesignSystem/`, so all existing call sites reskin from one place and `DS.Colors.*` are now adaptive. Also the shared Liquid Glass helpers: `wispNotchGlassSurface(in:)` (fixed dark, notch), `wispGlassSurface(cornerRadius:interactive:)` and `wispGlassCard(cornerRadius:)` (adaptive glass tint, panel + dashboard). |
| `PerfMetricsRecorder.swift` | ~158 | Per-phase turn timings, medians split by whether a screenshot was attached. |
| `UsageTokenCounts.swift` | ~60 | Dependency-free token counts + provider-reported cost for a turn, summed over its model calls (`AgentTurnRunner.Outcome.usage`). |
| `ModelPricing.swift` | ~120 | Pure price table (estimates, dated by `pricesSetOn`) and `UsageCostEstimator` (cache-aware cost, provider-reported cost wins, cost labels incl. the subscription wording). |
| `UsageLogRecord.swift` | ~170 | Pure usage-log shape (numbers only), codec, 30-day retention, `UsageProviderIdentifier` parsing and `UsageAggregator` (today / 7 / 30 days, per-provider). |
| `UsageLogStore.swift` | ~120 | `@MainActor` singleton behind the log: `~/Library/Application Support/Wisp/usage-log.json` (0600), debounced save, `recordTurn`, `clear`, flush on quit. |
| `SystemReadouts.swift` | ~143 | Memory via `host_statistics64`; Ollama residency via `/api/ps`. |
| `WindowPositionManager.swift` | ~262 | Window placement and permission helpers. |
| `WispAnalytics.swift` | ~153 | Gated off. Sends nothing. Kept so the call sites still compile. |

### Design system & components
The Wisp visual identity. Prefer these tokens/components over ad-hoc styling; the legacy `DS.*`
names forward here.

| File | Lines | Purpose |
|------|-------|---------|
| `DesignSystem/WispColors.swift` | ~235 | The palette: raw brand hexes (`WispColor.Brand.*` — sage/lavender/moss/ink/cloud/bone), **adaptive** semantic tokens (`.background`/`.textPrimary`/`.accent`/… resolve light/dark via a dynamic `NSColor`), a fixed **on-glass** set (`OnGlass.*`) for always-dark surfaces, and adaptive glass tints. `adaptive(light:dark:)` is the helper. |
| `DesignSystem/WispTypography.swift` | ~60 | `WispFont` scale (SF Pro/rounded + SF Mono) and the lowercase `wisp` wordmark. |
| `DesignSystem/WispMetrics.swift` | ~50 | `WispSpacing` + `WispRadius` scales (softer/rounder; hero input = 22). |
| `DesignSystem/WispShadows.swift` | ~35 | `WispShadow` (`.ambient`/`.floating`/`.island`) + `wispShadow(_:)`. Soft, low-opacity only. |
| `DesignSystem/WispGradients.swift` | ~55 | The single signature gradient (sage→mist→lavender) and its animated variants. Use sparingly. |
| `DesignSystem/WispMotion.swift` | ~55 | Named animation curves (`quick`/`smooth`/`gentle`/`island`/`breath`) + the reduce-motion check. |
| `Components/WispGlassComponents.swift` | ~200 | `WispGlassPanel` container, `WispGlassButtonStyle` (subtle/prominent), `WispGlassIcon`, and `PressableScaleButtonStyle`. |
| `Components/WispBento.swift` | ~300 | The Wisp window's widget language: `WispBentoTile` (hover lift + arrow, press, optional whole-tile action and trailing accessory), `wispBentoSurface` (shared with `DashboardCard`, so every page uses the same tile), `WispLiveRim` (flowing lavender rim for work in progress), `wispEntrance(order:)` (staggered fade-up on appear), `WispBentoStat`, `WispActivityBars`, `WispBentoLink`. All motion honours Reduce Motion. |
| `Components/WispLiquidRim.swift` | ~185 | The Liquid Glass rim: `.wispLiquidRim(in:light:highlightEdge:)` adds a `.plusLighter` specular edge highlight plus state light (`WispLiquidRimLight`: resting / flowing arc / even glow). `WispIslandState.rimLight` maps AI activity → flowing lavender, confirmation/success/error → glow. Used by the notch surface and `WispGlassPanel`; the flowing clock only exists while flowing, and Reduce Motion swaps it for a steady glow. |
| `Components/WispMark.swift` | ~180 | The liquid-ribbon logo. `WispMarkState` drives per-state motion; static mode; clock paused at rest. `CompanionVoiceState.markState` maps to it. |
| `Components/WispIcon.swift` | ~200 | The Liquid Icon System: `WispIconSymbol` (bespoke single-stroke glyphs + `.system` SF-Symbol fallback), `WispIconState`, rendered by `WispIcon`. |
| `DynamicIsland/WispIslandState.swift` | ~120 | The 9-state island vocabulary + its mark/label/accent mapping. Derived, not stored — see `CompanionManager.islandState`, which now also drives `.executing` (a browser task reporting progress; step list + Stop in the hover panel, spinner + step count in the right flank) and `.processing` (idle with background tasks running). |
| `DynamicIsland/NotchWorkspaceView.swift` | ~725 | The notch's quick chat: `NotchWorkspacePage` (.chat), a sidebar of buddies and searchable conversations (Settings / Open Wisp buttons open the window), thread bubbles, the talk pill and a Type field → `askTypedQuestion`. |
| `DynamicIsland/NotchIslandStyle.swift` | ~125 | `NotchIslandSurfaceStyle` (black default / Liquid Glass), the persisted `NotchIslandStylePreference`, the `wispNotchIslandSurface(in:style:)` modifier, and `WispIslandButtonStyle` (flat subtle fill / white prominent capsule). |
| `DynamicIsland/NotchConversationSessions.swift` | ~125 | Pure grouping of `AgentTaskRecord` exchanges into sidebar conversations (a ≥30 min pause starts a new one; dictation/background excluded) + search, and `AnswerDisplayText` (machine-tag stripping for stored answers). |
| `Buddies/BuddyMemory.swift` | ~170 | `BuddyMemoryPolicy` (pure: prompt block, 60-note cap) and `BuddyMemoryStore` (per-buddy markdown files, remember/forget/delete). |
| `Buddies/BuddyModelChoice.swift` | ~75 | `BuddyModelChoice` (provider + optional Claude model, `allChoices`) and `BackgroundTaskCapacityPolicy` (local vs cloud concurrency). |
| `Buddies/BuddyDelegation.swift` | ~230 | `ask_buddy`: `BuddyDelegationPolicy` (pure: peer resolution, when to ask, the boundary note), `BuddyDelegationService` (approval, start, wait, outcome; injectable) and the run-only tool. |
| `Buddies/BuddyToolAccess.swift` | ~200 | `BuddyToolGroup`, `BuddyToolAccess` (the allow-list) and the pure `BuddyToolAccessPolicy` (`isPermitted`, server discovery, summaries). |
| `Buddies/BuddyRunToolkit.swift` | ~120 | `BuddyRunToolPolicy` (tools a cloud buddy may not use) and `BuddyRunToolkitBuilder` (per-buddy memory tools + exclusions). |
| `AgentRunToolkit.swift` | ~35 | Per-run tool changes for `AgentTurnRunner`: names to hide/refuse and run-only tools. |
| `Buddies/BuddyThread.swift` | ~175 | A buddy's continuous thread: `BuddyThreadExchange` (job or user message + answer, keyed by run task id), `BuddyThreadPolicy` (pure: prompt history projection, caps, persona addendum) and the persisted `BuddyThreadStore`. Tested by `Tests/BuddyThread`. |
| `Buddies/BuddyStore.swift` | ~580 | `BuddySchedule` (next run, summary, inference from wording), `WispBuddy` (incl. list state: pinned, last read, marked unread, notify when finished), `BuddyNameGenerator`, and the `BuddyStore` ObservableObject (persistence, minute schedule check, create/run/stop/rename/edit job/reschedule/pin/read state/duplicate/clear conversation/delete, `orderedBuddies`, `isUnread`). |
| `Buddies/BuddyListPolicy.swift` | ~105 | Pure buddy-list rules (Rakazo-style): unread (a succeeded/failed run finishing after the last read, or marked by hand), ordering (pinned → latest activity → newest), copy names, which task ids make up the visible thread (stored exchanges, not just runs History still holds), starter jobs, and `BuddyAnswerFormatting` (inline markdown for answers). Tested by `Tests/BuddyThread`. |
| `Buddies/BuddyCharacter.swift` | ~290 | The cloud character (Canvas, clock-driven): breathing, blink, pointer-following eyes, squish, moods, working ring, ground shadow; `Liveliness` cost dial. |
| `Buddies/BuddyMood.swift` | ~55 | `BuddyMood` + pure `BuddyMoodPolicy` (run state/time → mood). |
| `Buddies/BuddySpecialty.swift` | ~170 | Specialty templates: colour, tool groups, persona line, starter jobs. |
| `Buddies/BuddyFiles.swift` | ~290 | `BuddyAttachment`, pure `BuddyAttachmentPolicy` (prompt text, caps, name resolution) and the per-buddy `BuddyFileLibrary`. |
| `WispWindow/Buddies/BuddyToolsView.swift` | ~330 | What a buddy may use: Everything/Choose, app rows with logos + switches, Wisp's abilities, and the Add-app connect sheet. |
| `WispWindow/Buddies/*.swift` | ~1500 | The messenger: `BuddyRailView`, `BuddyChatView`, `BuddyInspectorView`, `BuddyCreationView`, `BuddyHubComponents` (pill/icon buttons, chips, typing dots, ambient backdrop, drop overlay, formatting). |
| `Buddies/BuddyAvatar.swift` | ~85 | `BuddyAppearance` (the 8 calm colours + tonal gradient) and `BuddyAvatar` (compact `BuddyCharacter`: still at rest, lively while working). |
| `Buddies/BuddyViews.swift` | ~1285 | `BuddyScheduleEditor`, model/tool editors, `BuddyStatusText` and `BuddyActionsMenuItems` (shared by the window list's right-click menu and the page's ⋯ menu), `BuddyDetailView` (the whole stored thread, editable job, inline clear/delete confirmation since the notch panel can't host sheets; marks the buddy read while open) and `NewBuddyForm` (with starter jobs). |
| `DynamicIsland/MorningBriefing.swift` | ~255 | The morning notch: `MorningSuggestion`, the pure `MorningSuggestionBuilder` and `MorningBriefingSchedule` (once a day, daytime, user present), and `MorningBriefingController` (1-min check, pending suggestions, `presentationSequenceNumber` the notch drops the banner on, `perform`). |
| `DynamicIsland/QuietModeMonitor.swift` | ~280 | Quiet mode: `QuietModeDetection` (CoreAudio processes capturing input, CoreMediaIO camera running, system-listener filter) and the polling `QuietModeMonitor` publishing `activeQuietReason`. |
| `DynamicIsland/FinishedWorkInbox.swift` | ~55 | Unseen finished background task ids behind the notch's "N new" badge and NEW section (in-memory, cap 5). |
| `DynamicIsland/AnnouncementPreferences.swift` | ~50 | UserDefaults switches for morning suggestions and quiet-on-calls (both default on). |
| `DynamicIsland/UpcomingEventMonitor.swift` | ~85 | Ambient next-meeting countdown: polls EventKit every 30s via `CalendarDataProvider.imminentTimedEventIfAuthorized` (never prompts — nil without access) for a timed event starting within 15 min; the notch's right flank shows `12m`, and the island stays visible at idle while one is imminent or background work runs. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, Cmd+R to build and run.
# Or build headlessly without touching TCC:
#   osascript -e 'tell application "Xcode" to build (first workspace document)'

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT launch the app by running its binary directly.** `./Wisp.app/Contents/MacOS/Wisp`
gets you stdout logs, but the process is not registered with LaunchServices, so TCC cannot
attribute the Speech Recognition request to the app bundle. The app then aborts with
`EXC_CRASH (SIGABRT)` and a TCC message claiming `NSSpeechRecognitionUsageDescription` is
missing — it is not; the key is present and the attribution is what failed. This crashes on
the first push-to-talk, every time. Launch with `open -a <path-to>/Wisp.app` instead and read
logs via `log stream --predicate 'process == "Wisp"'`.

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

**Standalone test suites** (plain `swiftc`, no Xcode build, no TCC reset; nothing needs to be
running):

```bash
./Tests/ModelProviderContract/run.sh     # provider layer, ~10s
./Tests/AgentRuntimeIntegration/run.sh   # agent loop, slower (compiles the whole app)
./Tests/HostileProviderAttack/run.sh     # adversarial provider vs the real agent loop; lists known defects
./Tests/FastPointing/run.sh              # pointing request/matching/reply parsing, ~5s
./Tests/ScreenRegionFocus/run.sh         # ask-about-a-part: region clamping, AppKit→screenshot pixels, prompt text
./Tests/WorkedSolutionExport/run.sh      # save-a-worked-solution: worth saving, display choice, file names, Markdown
./Tests/PartSelection/run.sh            # voice selection of a part: spoken-target parser, OCR list/ordinal resolver, pixels→region round trip
./Tests/UsageLog/run.sh                  # usage log: cost estimator, aggregation windows, retention, codec, no content fields, store file
./Tests/GuidedWalkthrough/run.sh         # guided walkthrough plan stepping, instruction → label, click-on-target matching
./Tests/BrainCore/run.sh                 # brain page format, edit planner, search, memory migration
./Tests/BrainIngest/run.sh               # extraction, chunking, proposal merging, queue codec
./Tests/BrainDigest/run.sh               # conversation digest + notes import policy
./Tests/BrainActivity/run.sh             # activity exclusions, spans, summaries
./Tests/BrainLint/run.sh                 # lint checks, merge, split
./Tests/BrainUI/run.sh                   # markdown rendering, graph layout
./Tests/BuddyThread/run.sh               # buddy thread history projection, caps, store round trip
./Tests/WindowManagement/run.sh          # window layout command parsing, app matching, frame math
./Tests/ScreenWatcher/run.sh             # screen-watch request parsing, text matching, evaluator
./Tests/EditableConfirmation/run.sh      # editable confirmation fields: which, edit application, refusals
./Tests/RoutineParameters/run.sh         # routine blanks: parsing, defaults, clipboard/date, filling in
./Tests/CanvasSync/run.sh                # Canvas ICS parser, diff, study blocks, feed URL validator
./Tests/DayChecklist/run.sh              # daily checklist builder + EventKit write planning
./Tests/JobsEngine/run.sh                # Jobs engine flow with fakes (sync, throttle, approval, checklist)
./Tests/MCPStructuredContent/run.sh      # MCP structuredContent rendering + caps, cua-driver floor and cards
./Tests/WispTheme/run.sh                 # themes: contrast ratio for every theme, light and dark
./Tests/BuddyPersonality/run.sh          # personality presets, greeting rule, streak policy
./Tests/AutomationDraft/run.sh           # "say it" phrases -> drafts, ambiguous -> asks, templates
./Tests/AutomationSchedule/run.sh        # next run, DST, missed slot runs once
./Tests/AutomationEngine/run.sh          # engine with fakes: unattended tool policy, approvals, privacy, test runs
./Tests/AutomationMigration/run.sh       # routines/buddy jobs/Jobs -> automations, incremental
./Tests/AutomationQuickAdd/run.sh        # quick add: automation vs ordinary question
./Tests/CanvasSync/run.sh                # Canvas ICS parsing, diff, study-block planner
./Tests/DayChecklist/run.sh              # daily checklist builder: rollover, caps, ordering
./Tests/JobsEngine/run.sh                # Jobs engine orchestration with injected dependencies
./Tests/AudioDevices/run.sh              # microphone choice (lid closed, silent mic, no loopback devices), dead-mic check, muted output
WISP_LIVE_CUA_DRIVER=1 ./Tests/MCPStructuredContent/run.sh   # + read-only live check against ~/.local/bin/cua-driver
```

`ModelProviderContract` compiles a hand-maintained `SOURCES` list — when a listed file gains a
dependency on another source file, add that file to the list or the suite stops compiling.
`AgentRuntimeIntegration` compiles every `.swift` file under `leanring-buddy/` (recursively,
minus the `@main` entry point) with PostHog and FluidAudio stubbed, because the agent runtime
reaches `CompanionManager` and through it most of the app; a new third-party import needs a stub
there. The FluidAudio stub (`Tests/AgentRuntimeIntegration/FluidAudioStub.swift`, also used by
`HostileProviderAttack`) declares only the API `FluidAudioSpeechModels.swift` uses — calling
more of FluidAudio means adding it there with the real signature.

## Local services

With the default configuration only Ollama must be running (speech in and out is on-device):

```bash
ollama serve                     # port 11434
```

Chatterbox is needed only if `VoiceTTSProvider` is set to `chatterbox`:

```bash
curl -s http://localhost:8004/ -o /dev/null -w "%{http_code}\n"   # Chatterbox TTS health
```

Ollama isn't needed while a cloud provider is selected. There is no Cloudflare Worker.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy). The app is named Wisp; the Xcode target is not.
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
