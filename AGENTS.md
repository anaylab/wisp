# Wisp - Agent Instructions

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar
(no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel
with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input,
transcribes it on-device, and sends the transcript + a screenshot to a local model. The
model responds with text, shown in the notch; speech is optional (voice/silent mode, and in
voice mode only the short line the model tags with `[SAY: …]` is spoken, by the on-device
macOS voice by default). A transparent screen
overlay can mark UI elements the model references on any connected monitor with a pulsing
marker, and can draw boxes, arrows and highlights on screen.

**Local-first and private by default.** Out of the box everything runs on this machine: the
local Ollama model, on-device speech recognition, and on-device speech synthesis (macOS
voices), with the model traffic being HTTP to `localhost` (Ollama on 11434; Chatterbox TTS on
8004 only if opted into) — no Cloudflare Worker and no analytics. The only other default
network use is live glance-card data (weather, places, configured sources), gated by
`GlanceCardDataPreference`, which sends a place name or search query (plus, for places, the
location to Apple Maps), never a screenshot. The model backend is now *selectable*: a user
can opt in, in Settings → Model, to a bring-your-own-key cloud provider (`ModelProviderFactory` /
`BuddyChatProviderSelection`, key in the Keychain via `ProviderKeychainStore`), which sends
screenshots and the transcript off this machine and is labelled as such. Local remains the
default and the private path — do not make a cloud provider the default, and do not add a
cloud dependency to the local path, without asking.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon. The Wisp window raises the
  activation policy to `.regular` while open, and drops back to `.accessory` on close.
- **Surfaces (notch-first layout)**: the **notch** is where Wisp is *used* (answers, cards, quick
  panel, quick chat); the **Wisp window** is where it's *managed*; the **menu bar item** is a plain
  native `NSMenu` (`MenuBarMenuController`: status, Ask Wisp…, Open Wisp, Chat, Buddies, Pause
  Listening / Speak Replies / Sound Cues checkmarks, Settings…, Quit — rebuilt in `menuNeedsUpdate`).
  **Pause listening** (`CompanionManager.isListeningPaused` / `setListeningPaused`) drops every talk
  gesture and routine digit at the shortcut sinks (cancelling a hold in progress); typed questions
  still work. It isn't persisted, dims the menu bar icon (`appearsDisabled`), and shows a Resume
  banner on Today and "Listening paused" in the notch chat's talk pill. The window
  (`WispWindow/`) replaced the old dashboard, the pop-out conversation window, the notch's own
  settings pages and the big menu bar panel, so every setting has exactly one home. It has no sidebar:
  a slim top bar (`WispWindowView`) holds the eight `WispSection`s as icons (Today, Chat, Buddies, Brain, Routines,
  History, Connections, Settings) — the open one expands to its name and the pill slides between tabs
  (`matchedGeometryEffect`) — with a status pill (mark + state + model) at the end, and a section with several
  pages (`WispPage`) gets a segmented strip beneath. The `NSWindow` is full-size-content with a transparent title
  bar and hidden title; the bar sits in it, doubles as the drag handle (`WindowDragArea`), and
  `WispWindowController.positionTrafficLights` grows the title bar container and centres the traffic lights on it
  (re-run on resize/key, since AppKit resets it). Nothing from SwiftUI is bridged into the title or toolbar
  (`sceneBridgingOptions = []`). Anything opens it at a page with
  `WispWindowNavigator.open(_:)` (closes the notch workspace + quick panel first). On launch with a
  permission missing, the window opens on Today, which leads with the `PermissionsChecklist`.
  Look: calm and tactile — `WispColor` surface tokens, hairlines, and **one button treatment**: the lit-edge pill
  (`Components/WispPill.swift`: `WispBevel` + `WispPillButtonStyle`, prominent = tinted with the accent, otherwise
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
- **Speech-to-Text**: Apple Speech framework, on-device. Recognition **language** and a
  **custom dictionary** are user-configurable via `DictationSettingsStore` (Dictation tab):
  the language chooses the recogniser's locale, and the dictionary words are passed as
  `SFSpeechAudioBufferRecognitionRequest.contextualStrings` to bias spelling (this was a
  no-op before — the provider accepted keyterms and dropped them). Both are read on the main
  actor by `BuddyDictationManager` and threaded into `startStreamingSession`.
- **Text-to-Speech**: chosen once at launch by `BuddyTTSProviderFactory` from the Info.plist
  `VoiceTTSProvider` key, which ships as `apple`: `AppleSpeechSynthesisClient`
  (`AVSpeechSynthesizer`, the built-in macOS voices — on-device, no server, no resident memory
  in the app). Setting it to `chatterbox` opts into `LocalChatterboxTTSClient`, a
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
  (`ToolConfirmationView`) is the island's glass confirmation panel, still presented via the
  existing overlay plumbing (so the prompt is seen even when the cursor is hidden). On a
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
  from a `[POINT:]`. Note the corner format — the model emits corners, not origin+size. When
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
  can't be read; remote bash/workbench always) — still go to the confirmation card with
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
  actions (identifying args + "can't be taken back"), and Composio batches (one row per unwrapped
  tool). Reading tools and unrecognised shapes get no card, so the panel falls back to the plain
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
  `chrome_ungroup_tabs` (browser scope). Status and install help live in the Agent tab's Chrome Tabs card.
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
  tool router** (`AgentToolRouter.swift`) shows the model only the ~6 most relevant to the request
  (`AgentToolScope.maximumExposedTools`), ranked by lexical relevance with a bonus for built-in
  scope membership. So a large installed library costs nothing until a request is about it. The
  tab shows how many tools are available + per-tool toggles (the allow-list). A **Composio** section
  (opt-in, off-machine, labelled) lets a user paste a Composio API key (`ComposioKeychainStore`),
  browse toolkits (`ComposioClient`/`ComposioAccountStore`), and install one as a managed remote
  MCP server; the key is injected into the transport from the Keychain at connect time, never
  written to `mcp.json`. Composio here is the **connect universal server**
  (`https://connect.composio.dev/mcp`, auth `x-consumer-api-key`): connecting installs one
  remote server whose meta-tools (`COMPOSIO_SEARCH_TOOLS`/`MULTI_EXECUTE_TOOL`/
  `MANAGE_CONNECTIONS`, …) reach 500+ apps and count against the same tool budget.
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
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: none. `WispAnalytics.swift` is gated off and sends nothing.

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
(the 3B default, or a 7B) leaves little spare — which is also why the default TTS is the
system synthesizer rather than the Chatterbox server, whose resident memory grew to several
gigabytes with use. A second concurrently-resident LLM is not feasible at
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
| `ShortcutBindingStore.swift` | ~150 | Data-driven source of truth for shortcuts: hold chord, hands-free enable + modifier. Persists to UserDefaults, resets to defaults, and pushes live values to the tap's statics. |
| `TextComposerWindowController.swift` | ~230 | The tap-to-type text composer: a keyable floating panel (activates the app for typing, Return to send, Esc to dismiss) whose typed question runs through the normal screenshot turn. |
| `DictationSettingsStore.swift` | ~110 | Source of truth for dictation language + custom dictionary. Persists to UserDefaults; read by `BuddyDictationManager` when starting a session. |
| `DictationTab.swift` | ~200 | Settings → Dictation: language picker (Automatic + on-device locales) and a removable-chip custom dictionary editor. |
| `CursorAppearanceStore.swift` | ~90 | Source of truth for the cursor/annotation colour (blue/red/yellow/green). Observed by the overlay, annotation layer, and brand glyphs so a change applies live. |
| `AgentSettingsStore.swift` | ~80 | Source of truth for the agent working folder. Persists to UserDefaults; the resolved path is readable off the main actor for the tool registry. |
| `AgentTab.swift` | ~395 | Settings → Agent: agent folder (folder picker + reset), session auto-approve toggle (its subtitle names what still asks — the `ToolCallSafety` floor), announcements, an Apple Shortcuts card (availability, shortcut count, Refresh via `ShortcutsBridge`) and the Chrome Tabs card. Permissions moved to Settings → General. |
| `BuddyChatTypes.swift` | ~685 | Shared value types: `JSONValue`, `BuddyContentBlock`, `BuddyChatMessage`/`BuddyChatTurn`, `BuddyToolDefinition`, `ConversationTranscript`, and the `AgentTaskRecord`/`AgentStepRecord` history records. |
| `AppBundleConfiguration.swift` | ~30 | Reads Info.plist string keys (`VoiceTTSProvider`, `AgentModeEnabled`, `OllamaModel`, …) from the built bundle. |
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
| `BuddyTTSProvider.swift` | ~53 | TTS protocol and factory, keyed off `VoiceTTSProvider`: Chatterbox only when it says `chatterbox`, otherwise the Apple synthesizer (the shipped default). |
| `AppleSpeechSynthesisClient.swift` | ~205 | The default TTS: `AVSpeechSynthesizer` with the built-in macOS voices — on-device, no server, no resident memory in the app. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | On-device STT via the Speech framework. The only provider. |
| `BuddyTranscriptionProvider.swift` | ~45 | STT protocol (`BuddyTranscriptionProvider` / `BuddyStreamingTranscriptionSession`) and the factory, which always returns the Apple provider. |
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

### Agent, tools and MCP
| File | Lines | Purpose |
|------|-------|---------|
| `AgentTurnRunner.swift` | ~415 | The agent loop: max 4 iterations, screenshot on iteration 0 only, per-tool timeouts. |
| `BrowserCommandRouter.swift` | ~200 | Deterministic recognition of spoken browser commands: tab commands (`BrowserTabCommand`) and clear web tasks, so they run without the model choosing a tool. Conservative — misses fall through to a normal turn. |
| `ChromeExtensionBridge.swift` | ~330 | Loopback-only WebSocket server (127.0.0.1:47823) for the Wisp Tabs extension: Origin-pinned handshake, one live connection, JSON request/response with 10s timeouts, `connectionState` for the Agent tab. |
| `ChromeTabOrganizer.swift` | ~600 | Tab organizing: `ChromeTab`/`ChromeTabsSnapshot`, `ChromeSiteNamer`, `ChromeTabGroupingPlanner` (per-window plans, loose tabs only, stable colours), `ChromeDuplicateTabFinder`, `ChromeTabTopicPrompt` (numbered prompt + strict reply parsing), `ChromeTabCommand`, and `ChromeTabOrganizer` (runs a plan through the bridge). |
| `MessageCommandParser.swift` | ~210 | Pure parsing of spoken message commands ("text X saying Y", "send X a text …", "tell X that Y", unseparated "text X Y" → longest-first splits). Conservative; declines pronouns and noun uses ("text size"). |
| `ContactsDirectory.swift` | ~440 | `ContactRecord`/`ContactHandle` (preferred handle: mobile → phone → email), the pure `ContactMatcher` (ranked tiers, ambiguity, relation words via the Me card), `DirectMessagingHandleParser`, and `ContactsDirectory` (CNContactStore access + off-main fetch). |
| `MessagesSender.swift` | ~175 | `MessageRecipientResolver` (candidates → one person + handle, or a reason, or "not a message command") and `MessagesAppSender` (AppleScript handler call to Messages with Apple Event parameters; iMessage then SMS; -1743 → Automation hint). |
| `WindowManagement/WindowLayoutCommand.swift` | ~700 | Pure side of window management: `WindowPlacement`, `WindowLayoutTarget`/`Assignment`/`Command`, `WindowLayoutApplicationNameMatcher` (unique running-app match), `WindowLayoutCommandParser` (spoken commands + tool-argument placements, conservative), `WindowLayoutReplyText`, and `WindowFrameCalculator` (placement + display visibleFrames → AX frame, primary-height flip, next-display relative move). Tested by `Tests/WindowManagement`. |
| `WindowManagement/WindowLayoutExecutor.swift` | ~300 | Places windows over Accessibility: running-app resolution (regular apps, not Wisp; "this" via `FrontmostAppTracker`), detached AX with a 0.5s timeout, unminimize, position/size/position, raise + activate, `PlacementFailure` reasons. |
| `WindowManagement/WindowManagementAgentTools.swift` | ~85 | The `arrange_windows` agent tool (`registerWindowManagementTools()`). |
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
| `AgentToolScope.swift` | ~130 | Deterministic built-in scope vocabulary (browser/filesystem/coding/memory/messaging/general) + `alwaysAvailableToolNames` + the per-turn budget (`maximumExposedTools` = 6). Used by the router as a relevance bonus. |
| `AgentToolRouter.swift` | ~150 | Per-turn tool selection: ranks every registered tool by lexical relevance to the request (name words weighted over description), scope membership (or a caller's `boostedToolNames`, e.g. `run_shortcut` when the request names a shortcut) adds a bonus, returns the top few within budget. Deterministic, model-free. |
| `StructuredTextToolProtocol.swift` | ~330 | `[TOOL:name:{json}]` prompt generation and lenient parsing, with an anti-echo guard. |
| `MCPClient.swift` | ~420 | `MCPServerConnection`: transport-agnostic JSON-RPC 2.0 framing, timeouts, and the MCP handshake. Picks a transport via `makeTransport(for:)`. `MCPStartupTimeoutPolicy` gives a package runner's `initialize` a long first-run budget. |
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
| `RoutinesTab.swift` | ~450 | Routines page: list + auto-saving editor (name, instruction, icon, shortcut digit with "used by" warnings, suggested apps from running apps or /Applications, pin toggle, Run now — closes the Wisp window first so the screenshot sees the user's work). |
| `SkillIndex.swift` | ~35 | Terse per-line skill index appended to the system prompt alongside tool instructions. |
| `ShortcutsBridge.swift` | ~455 | Apple Shortcuts via `/usr/bin/shortcuts`: `ShortcutsListParser` (`list --show-identifiers` → name + UUID), `ShortcutsCommandLine` (argument arrays; name after `--`), `ShortcutsProcessRunner` (off-main `Process`, both pipes drained, timeout + cancellation terminate), `ShortcutRunResultFormatter` (capped text for the model), and the `ShortcutsBridge` ObservableObject (5-min cached list, availability, `runShortcut(named:textInput:)` with exact-name resolution and temp-file I/O). |
| `ShortcutsAgentTools.swift` | ~280 | `ShortcutNameMatcher` (request → matching shortcut names; exact-name resolution), `ShortcutsToolRouting` (boost hints + per-turn `run_shortcut` description naming ≤3 matches; the `list_shortcuts`/`run_shortcut` definitions), and `AgentToolRegistry.registerShortcutsTools()`. |
| `ConversationHistoryStore.swift` | ~420 | Persists the last 20 transcript turns to `~/Library/Application Support/Wisp/conversation.json` (Codable `Persisted*` shapes, images dropped, debounced + flushed on quit) and hands back the ≤6h-old ones to resume on launch. `ConversationHistoryCodec` holds the pure encode/decode/merge/resume policy. |
| `MemoryStore.swift` | ~330 | `~/.wisp/memory.md` user memory: `MemoryFileFormat` (pure bullet parse/append/remove), `MemoryIndex` (the ≤800-char system-prompt block, newest facts first), and the `MemoryStore` ObservableObject behind the `remember`/`forget` tools and the Memory tab. |
| `ToolConfirmationCoordinator.swift` | ~530 | Permission requests with a 45s timeout and spoken-affirmative parsing. `requestApproval(toolName:toolInput:)` applies the `ToolCallSafety` floor under session auto-approve and attaches the `ToolConfirmationCardBuilder` card to `PendingConfirmation.confirmationCard`. `requestApprovalAllowingEdits` also offers the call's editable fields and returns a `ToolApprovalOutcome` (decision + edits); holds the typed edits and the movable expiry (`updateEditedText`, `extendTimeoutForEditing`). Defines `ToolPermissionBroker` and `ToolApprovalOutcome`. |
| `ToolConfirmationView.swift` | ~240 | The Dynamic-Island glass confirmation panel (`WispGlassPanel` + `WispMark`): request-dominant, the optional confirmation card (`GlanceCardView`, minus the rows its editable fields replace), the editable fields, exact call (with edits) in a chip, Cancel / Allow→ (Cmd-Return), "or just say yes". Presented via the existing overlay plumbing, positioned under the notch; calls `flashIsland(.success/.error)` on allow/deny. |
| `EditableConfirmationFields.swift` | ~250 | Pure rule for inline-editable confirmation fields: which top-level string arguments a call offers (by tool name or card shape), `applyingEdits` (ignores any non-editable key, blank or unchanged edits), the tool-result note telling the model what the user changed, and hiding the card rows the fields replace. Tested by `Tests/EditableConfirmation`. |
| `EditableConfirmationFieldView.swift` | ~125 | One editable card field: reads as card text until hovered (fill, pencil, I-beam), single-line `TextField` or multi-line `TextEditor`, focus counts as editing activity, "edited" mark (`EditedConfirmationFieldMark`). |
| `ToolCallInspection.swift` | ~325 | Deterministic reading of a tool call: `server__` namespace stripping, identifier → words (camelCase/underscores), Composio execute-meta-tool unwrapping into `InspectedToolAction`s (tolerates JSON-string arguments), lenient case/underscore-insensitive argument lookup, display text for arrays/objects, path-argument extraction and `..`-safe path containment. |
| `ToolMetadata.swift` | ~100 | What a tool does (read-only, destructive, external side effect, data source) as data; whether it needs confirmation is computed from it. |
| `ToolCallSafety.swift` | ~185 | The destructive-action floor under session auto-approve: `mustAskEvenWithSessionAutoApprove(toolName:toolInput:agentWorkingDirectoryPath:)`. Word vocabularies (always-irreversible verbs, noun-ish words that count only without a reading verb), command execution, calendar invites, writes outside the agent folder, Composio meta-tool rules, and `alwaysAskBareToolNames` (`run_shortcut`). |
| `ToolConfirmationCardBuilder.swift` | ~610 | Builds the confirmation panel's `GlanceCard` from a call: Run Shortcut (by name) / email / message / post / event / file write / deletion / other-irreversible / Composio batch; nil for reads and unknown shapes. Truncates bodies (180 chars) and field values (80). Exposes the shape it chose (`ConfirmationCardShape`) and its key vocabularies for the editable fields. |
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
| `ActiveStackReadout.swift` | ~100 | "What's running": configured model/STT/TTS names from Info.plist plus Ollama residency, for the Wisp window's status pill and Settings → General's What's running card. Also labels perf timings and "Asking …" steps. |
| `MenuBarMenuController.swift` | ~180 | The menu bar item: the ribbon template icon and a native `NSMenu` rebuilt on open (status line, talk hint, Finish Setup… when a permission is missing, Ask Wisp…, Open Wisp, Chat, Buddies, Pause Listening / Speak Replies / Sound Cues checkmarks, Settings…, Quit); dims the icon while paused. |
| `NotchWindowController.swift` | ~620 | Hosts the notch HUD in a borderless non-activating `NotchPanel`. Polls `NSEvent.mouseLocation` against fixed hot-zones (with hysteresis) to expand/collapse, and toggles `ignoresMouseEvents` so the window is click-through while collapsed. Force-collapses on `.wispDismissPanel` (so it's out of the way of a skill launch or push-to-talk capture) — except while the workspace is open — and reloads skills when the panel opens. `setWorkspacePage` grows/shrinks the window for the chat/settings workspace and toggles `NotchPanel.allowsBecomingKey`. Owns `NotchViewModel`. |
| `NotchHUDView.swift` | ~1425 | The notch HUD's SwiftUI content: collapsed pill (the liquid `WispMark` + live state dot) and the hover-expanded quick-panel — shortcuts cheat-sheet, a **SKILLS grid of one-click launcher chips** (each runs its skill via `CompanionManager.runSkill`), active integrations, and a dock-cursor toggle in the header. Pins `.colorScheme(.dark)`; mark/dot/label are driven by `companionManager.islandState`. `DS.*` throughout. |
| `NotchFileDrop.swift` | ~75 | Drop a file on the notch to add it to the brain: `NotchFileDropView` (a transparent `hitTest`-nil sibling above the hosting view; wrapping it, registering it, or SwiftUI `.onDrop` all failed to receive drags) and `NotchFileDragDetector` (drag-pasteboard change count + held button, so window drags never misfire). `NotchWindowController.updateFileDragState` opens the island under a file drag (brain on only) and `addDroppedFilesToBrain` enqueues supported files on `BrainIngestQueue`, showing the result via `viewModel.fileDropFeedback`. |
| `NotchGeometry.swift` | ~85 | Resolves collapsed/expanded window frames from `NSScreen.safeAreaInsets` + `auxiliaryTop{Left,Right}Area`, with a floating-pill fallback on non-notch Macs. |
| `DesignSystem.swift` | ~480 | The legacy `DS.*` token **facade**: `DS.Colors`, `DS.Spacing`, `DS.CornerRadius`, `DS.Animation` now forward to the `Wisp*` tokens in `DesignSystem/`, so all existing call sites reskin from one place and `DS.Colors.*` are now adaptive. Also the shared Liquid Glass helpers: `wispNotchGlassSurface(in:)` (fixed dark, notch), `wispGlassSurface(cornerRadius:interactive:)` and `wispGlassCard(cornerRadius:)` (adaptive glass tint, panel + dashboard). |
| `PerfMetricsRecorder.swift` | ~158 | Per-phase turn timings, medians split by whether a screenshot was attached. |
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
```

`ModelProviderContract` compiles a hand-maintained `SOURCES` list — when a listed file gains a
dependency on another source file, add that file to the list or the suite stops compiling.
`AgentRuntimeIntegration` compiles every `.swift` file under `leanring-buddy/` (recursively,
minus the `@main` entry point) with PostHog stubbed, because the agent runtime reaches
`CompanionManager` and through it most of the app; a new third-party import needs a stub there.

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
