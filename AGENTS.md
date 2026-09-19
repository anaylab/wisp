# Wisp - Agent Instructions

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar
(no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel
with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input,
transcribes it on-device, and sends the transcript + a screenshot to a local model. The
model responds with text, which is spoken by a local TTS server. A blue cursor overlay
can fly to and point at UI elements the model references on any connected monitor, and
can draw boxes, arrows and highlights on screen.

**Local-first and private by default.** Out of the box everything runs on this machine: the
local Ollama model, on-device speech, and the local TTS server, with the only network
traffic being HTTP to `localhost` (Ollama on 11434, Chatterbox TTS on 8004) — no Cloudflare
Worker and no analytics. The model backend is now *selectable*: a user can opt in, in the
dashboard, to a bring-your-own-key cloud provider (`ModelProviderFactory` /
`BuddyChatProviderSelection`, key in the Keychain via `ProviderKeychainStore`), which sends
screenshots and the transcript off this machine and is labelled as such. Local remains the
default and the private path — do not make a cloud provider the default, and do not add a
cloud dependency to the local path, without asking.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon. The dashboard raises the
  activation policy to `.regular` while open, and drops back to `.accessory` on close.
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel, cursor
  overlay, and dashboard window
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Chat / Vision**: a pluggable `ModelProvider`, chosen at runtime via
  `BuddyChatProviderSelection` and built by `ModelProviderFactory`. Default is local Ollama
  `qwen2.5vl:3b` at `http://localhost:11434` (NDJSON streaming); cloud providers such as
  `GeminiProvider` are bring-your-own-key. The Info.plist `ChatProvider` key is now only a
  shipped-default hint — the live selection lives in `BuddyChatProviderSelection`.
- **Speech-to-Text**: Apple Speech framework, on-device. Recognition **language** and a
  **custom dictionary** are user-configurable via `DictationSettingsStore` (Dictation tab):
  the language chooses the recogniser's locale, and the dictionary words are passed as
  `SFSpeechAudioBufferRecognitionRequest.contextualStrings` to bias spelling (this was a
  no-op before — the provider accepted keyterms and dropped them). Both are read on the main
  actor by `BuddyDictationManager` and threaded into `startStreamingSession`.
- **Text-to-Speech**: Chatterbox Nano at `http://localhost:8004`. Reply speech is now
  **opt-in per reply and gated by a voice/silent mode** (`VoiceOutputPreference`, default on).
  The notch is the primary answer surface: every reply renders there as text
  (`CompanionManager.currentReplyText`) plus an optional glance card. In **silent mode** no
  reply is spoken. In **voice mode** the model chooses whether/what to speak via a `[SAY: …]`
  tag (`SpokenLineParser`) — only that short line is synthesised, at the end of the turn; a
  reply with no tag stays silent. The old incremental sentence-streaming of the whole reply
  is retired. Confirmation/failure speech is unaffected.
- **Deployment target**: macOS 26 (raised from 14.2) so the notch HUD can use real SwiftUI
  **Liquid Glass** (`.glassEffect` / `GlassEffectContainer`), dark-tinted for legibility
  (`DS.Colors.notchGlassTint`, `View.wispNotchGlassSurface(in:)`).
- **Design system**: the Wisp visual identity ("quiet intelligence × organic × native macOS")
  lives in `DesignSystem/` — `WispColor` (sage/ink/cloud palette; a **sage** brand accent, a
  **lavender** AI-activity accent, muted-terracotta errors), `WispFont`, `WispSpacing`,
  `WispRadius`, `WispShadow`, `WispGradient` (the single signature sage→mist→lavender gradient,
  used sparingly) and `WispMotion` (named curves + reduce-motion). Colours come in three layers:
  raw brand (fixed), **adaptive** semantic tokens (`WispColor.background` etc., resolve light/dark
  live via a dynamic `NSColor`), and a fixed **on-glass** set (`WispColor.OnGlass.*`) for the
  always-dark surfaces. The legacy `DS.*` API is a thin facade that **forwards to these tokens**,
  so `DS.Colors.background` etc. are now adaptive and the whole app reskins from one place.
  Reusable components live in `Components/` (`WispGlassPanel`/`WispGlassButtonStyle`/`WispGlassIcon`,
  `WispGlassInput`, `WispMark`, `WispIcon`). **Do not reintroduce hardcoded hex** — reference the
  tokens.
- **Light/dark**: the **dashboard follows the system appearance** (its `WispColor` tokens resolve
  light or dark). The **notch HUD, on-screen overlay, and menu-bar panel stay a dark glass
  material in every appearance** — they pin `.environment(\.colorScheme, .dark)` so their adaptive
  tokens resolve dark, keeping near-white text legible over any wallpaper. `wispGlassSurface` /
  `wispGlassCard` use an **adaptive** glass tint (`WispColor.glassTint` / `glassCardTint`);
  `wispNotchGlassSurface` stays fixed dark.
- **The Wisp mark**: a flowing liquid-ribbon logo (`Components/WispMark.swift`), filled with the
  signature gradient, with subtle per-state motion (idle/listening/thinking/acting/success/error),
  a static mode, and a paused `TimelineView` clock while at rest. It replaced the old rotated
  `Triangle` glyph in the notch. Icons are the single-stroke **Liquid Icon System**
  (`Components/WispIcon.swift`): bespoke glyphs for the high-value actions (message, search, mic,
  send, voice, files, calendar, gear-free settings) with an SF-Symbol fallback for the long tail.
- **Dynamic Island state**: `DynamicIsland/WispIslandState.swift` is a 9-state vocabulary
  (idle/listening/thinking/processing/preview/confirmation/executing/responding/success/error)
  **derived**, not a replacement, from existing signals. `CompanionManager.islandState` projects
  it from `voiceState` + `pendingToolConfirmation` + whether an answer is lingering, plus a
  transient `islandFlash` (`flashIsland(_:)`) for success/error moments. It drives the notch
  mark's motion, the state dot, and the label. The tool-confirmation card
  (`ToolConfirmationView`) is the island's glass confirmation panel, still presented via the
  existing overlay plumbing (so the prompt is seen even when the cursor is hidden).
- **Glance cards**: a visual answer surface in the notch's expanded panel, parsed from one
  `[CARD:{...json...}]` tag at the end of the reply (same structured-text mechanism as
  `[POINT:]`/`[BOX:]`/`[TOOL:]` — the local model can't do native structured output; the tag is
  stripped from spoken text). The model emits a small payload naming a card *kind*, and Wisp
  owns the look and data (`GlanceCardParser` → `GlanceCardRequest` → `ResolvedGlanceCard`,
  drawn by a per-kind template). Kinds: `generic` (model-supplied `header`/`list`/`keyValue`/
  `stats` blocks, tone `good`/`bad`/`neutral` → `DS.Colors`, 3-block cap, SF Symbol allowlist,
  network-free), `weather` (the model sends only a place name → Open-Meteo, no API key, Apple
  Weather layout), `calendar` (EventKit, on-device), `music`/now-playing (AppleScript to
  Music/Spotify, on-device, best-effort), and `source` (user-configured HTTPS endpoints in
  `~/.wisp/sources.json`, mapped to generic blocks). Network kinds are gated by
  `GlanceCardDataPreference` (default on) and labelled "Live · source"; on-device kinds are
  gated only by their macOS permission. Managed in the dashboard's **Sources tab**. Adding an
  app = one data provider + one template.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor, downscaled to 896px
- **Element Pointing**: the model embeds `[POINT:x,y:label:screenN]` tags; the overlay
  parses them, maps to the correct monitor, and animates the cursor along a bezier arc
- **Screen Annotation**: `[BOX:left,top,right,bottom:label]`, `[HIGHLIGHT:...]` and
  `[ARROW:x,y:label]` tags render through a `Canvas` layer in the overlay. Note the corner
  format — the model emits corners, not origin+size. When several tags appear in one reply
  they are kept in document order and **auto-numbered** into a step-by-step walkthrough (badges
  drawn per step, cap 8). The cursor and all annotations draw in the user-chosen colour from
  `CursorAppearanceStore` (Cursor tab: blue/red/yellow/green).
- **Agent loop**: off by default behind `AgentModeEnabled` in Info.plist. When on, tools
  are called via structured `[TOOL:name:{json}]` tags rather than native tool_calls, since
  the local model is unreliable at the latter. Surfaced in the dashboard's Agent tab: the
  **working folder** (`AgentSettingsStore`, read by the tool registry; defaults to
  `CodeProjectDirectory`), a **session auto-approve** toggle (`ToolConfirmationCoordinator.autoApproveThisSession`
  — short-circuits the confirmation prompt, reset every launch), and **permission** rows with
  deep-links to System Settings. Note: session auto-approve is currently blanket — it approves
  every tool while on, including MCP writes; a per-tool destructive floor is a follow-up.
- **MCP**: hand-rolled JSON-RPC 2.0. Config at `~/.wisp/mcp.json` in Claude Desktop's
  format. The byte transport is abstracted behind `MCPTransport`
  (`MCPTransport.swift`): `MCPServerConnection` owns only JSON-RPC framing + the handshake,
  while `StdioMCPTransport` (`MCPStdioTransport.swift`) carries the child-process/stdin/stdout
  path. This split is the foundation for the in-flight **MCP marketplace** (remote Streamable
  HTTP transport + Composio managed-OAuth toolkits + a curated registry) — see
  `docs/mcp-marketplace-architecture.md`. Remote servers now work: a `~/.wisp/mcp.json` entry
  with a `url` (and optional `headers` for auth) connects over `MCPStreamableHTTPTransport`
  (`MCPStreamableHTTPTransport.swift`); an entry with a `command` is stdio as before. The
  dashboard's **Marketplace tab** (`MarketplaceTab.swift`) browses a bundled curated registry
  (`curated-mcp-registry.json`) and installs/removes/enables servers via `InstalledMCPServerStore`,
  which owns `~/.wisp/mcp.json` (preserving unknown keys) and reloads the manager live. Installing
  is separate from exposing: only `MCPManager.maximumExposedTools` (8) tools are registered at
  once, the allow-list + budget are applied by `MCPManager` at registration (the connection no
  longer filters), and the tab shows a budget meter + per-tool toggles. A **Composio** section
  (opt-in, off-machine, labelled) lets a user paste a Composio API key (`ComposioKeychainStore`),
  browse toolkits (`ComposioClient`/`ComposioAccountStore`), and install one as a managed remote
  MCP server; the key is injected into the transport from the Keychain at connect time, never
  written to `mcp.json`. Composio here is the **connect universal server**
  (`https://connect.composio.dev/mcp`, auth `x-consumer-api-key`): connecting installs one
  remote server whose meta-tools (`COMPOSIO_SEARCH_TOOLS`/`MULTI_EXECUTE_TOOL`/
  `MANAGE_CONNECTIONS`, …) reach 500+ apps and count against the same tool budget.
- **Skills**: markdown files with a `name`/`description` frontmatter header, dropped in
  `~/.wisp/skills/`. Only the name+description index (a few tokens each) is always in the
  prompt; the full body is loaded on demand via the read-only `load_skill` tool —
  progressive disclosure, so an arbitrarily large skill library costs nothing until used.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: none. `WispAnalytics.swift` is gated off and sends nothing.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon
and a custom borderless `NSPanel` for the floating control panel. This gives full control
over appearance and avoids standard macOS menu/popover chrome. The panel is non-activating
so it doesn't steal focus.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion.
It's non-activating, joins all Spaces, and never steals focus. Because it covers the whole
screen at `.screenSaver` level, it must keep `ignoresMouseEvents = true` except while a
tool confirmation card is up — otherwise the desktop becomes unclickable.

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
notch cheat-sheet and the dashboard's Shortcuts tab), which pushes live values into the plain
statics the tap reads on the main thread (`BuddyPushToTalkShortcut.currentShortcutOption` /
`.handsFreeDoubleTapModifier`). The tap recognises three gestures: **hold** the chord
(Talk; Dictate = hold + Shift; action on release), **tap** the chord (a release shorter than
`tapMaxDuration` → open the text composer), and **double-tap** a bare modifier (default:
double-tap Control → hands-free dictation). Recording still starts instantly on press for the
hold case; a tap simply `cancelCurrentDictation`s the just-started session and opens the
composer instead, so hold-to-talk latency is untouched. The double-tap detector is independent
of the hold path — the hold chord always needs a second modifier, so a bare-modifier tap can
never be confused with it. The text composer (`TextComposerWindowController`) is a keyable
panel that activates the app for typing and routes the typed question through the same
screenshot turn as voice (spoken answer + on-screen pointing).

**Model residency is the binding constraint.** On 18GB, one 7B vision model plus the TTS
server leaves almost nothing spare. A second concurrently-resident LLM is not feasible at
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
| `CompanionManager.swift` | ~2000 | Central state machine and integration hub. Owns dictation, shortcut monitoring, screen capture, the chat client, TTS, overlays, annotations, agent mode and tool confirmations. `runSkill(named:)` is the notch's one-click launcher. Also exposes the Dynamic Island projection: the computed `islandState` (`WispIslandState`, derived from `voiceState` + `pendingToolConfirmation` + reply/card presence) and `flashIsland(_:)` / `islandFlash` for transient success/error moments. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline: mic capture via `AVAudioEngine`, permission checks, transcript finalisation, live audio levels for the waveform. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~210 | System-wide shortcuts via a listen-only `CGEvent` tap: the hold chord plus an additive bare-modifier double-tap recogniser (hands-free dictation). |
| `ShortcutBindingStore.swift` | ~150 | Data-driven source of truth for shortcuts: hold chord, hands-free enable + modifier. Persists to UserDefaults, resets to defaults, and pushes live values to the tap's statics. |
| `TextComposerWindowController.swift` | ~230 | The tap-to-type text composer: a keyable floating panel (activates the app for typing, Return to send, Esc to dismiss) whose typed question runs through the normal screenshot turn. |
| `DictationSettingsStore.swift` | ~110 | Source of truth for dictation language + custom dictionary. Persists to UserDefaults; read by `BuddyDictationManager` when starting a session. |
| `DictationTab.swift` | ~200 | Dashboard Dictation tab: language picker (Automatic + on-device locales) and a removable-chip custom dictionary editor. |
| `CursorAppearanceStore.swift` | ~90 | Source of truth for the cursor/annotation colour (blue/red/yellow/green). Observed by the overlay, annotation layer, and brand glyphs so a change applies live. |
| `CursorTab.swift` | ~110 | Dashboard Cursor tab: dock-cursor toggle (shared with the notch) and the colour swatches. |
| `AgentSettingsStore.swift` | ~80 | Source of truth for the agent working folder. Persists to UserDefaults; the resolved path is readable off the main actor for the tool registry. |
| `AgentTab.swift` | ~250 | Dashboard Agent tab: agent folder (folder picker + reset), session auto-approve toggle, and permission rows with System Settings deep-links. |
| `CompanionScreenCaptureUtility.swift` | ~139 | Multi-monitor capture via ScreenCaptureKit, downscaled to 896px. |

### Local model stack
| File | Lines | Purpose |
|------|-------|---------|
| `LocalOllamaAPI.swift` | ~235 | Ollama client: NDJSON streaming, `keep_alive`, per-mode context and token limits, and the heuristic that decides whether a prompt needs a screenshot at all. |
| `ModelProvider.swift` | ~248 | Provider-agnostic runtime: the `ModelProvider` protocol (`streamTurn`), plus `ModelRequest`, `ModelCapabilities`, and `ModelDeployment` (`sendsDataOffThisMachine`, which drives the local-only-machinery gates). |
| `OllamaProvider.swift` | ~294 | Presents `LocalOllamaAPI` as a `ModelProvider`; owns the `[TOOL:...]` text convention that fakes tool calls for the local model. |
| `GeminiProvider.swift` | ~300 | Google Gemini as a `ModelProvider`: SSE streaming, native function calls, API key in a request header. The first bring-your-own-key cloud backend. |
| `ModelProviderFactory.swift` | ~75 | Builds the `ModelProvider` for the current `BuddyChatProviderSelection`, reading a cloud provider's key from `ProviderKeychainStore`. Used by CompanionManager's turn path. |
| `BuddyChatProviderKind.swift` | ~65 | The provider enum (local Ollama / Anthropic / OpenAI / Gemini) with `displayName`, `sendsScreenshotsOffThisMachine`, `requiresAPIKey`. |
| `BuddyChatProviderSelection.swift` | ~50 | The `UserDefaults`-backed live provider selection. Source of truth, defaulting to local. |
| `ProviderKeychainStore.swift` | ~90 | Per-provider API keys in the login Keychain — never in UserDefaults, Info.plist, or logs. |
| `BuddyVisionChatClient.swift` | ~47 | Legacy chat-client protocol + factory. Superseded by `ModelProvider` on the main path; still used by `BrowserAgent` for its own local vision. |
| `LocalChatterboxTTSClient.swift` | ~231 | Sentence-by-sentence local TTS: synthesises sentence N+1 while N is playing. |
| `BuddyTTSProvider.swift` | ~53 | TTS protocol and factory, keyed off `VoiceTTSProvider`. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | On-device STT via the Speech framework. The active provider. |
| `FluidAudioTranscriptionProvider.swift` | ~212 | Parakeet STT via CoreML. Built and working, currently unused. |
| `ModelAccessGate.swift` | ~104 | Actor serialising all model calls, with interactive priority, so background work never evicts the prefix cache a live turn depends on. |

### Overlay and annotation
| File | Lines | Purpose |
|------|-------|---------|
| `OverlayWindow.swift` | ~927 | Full-screen transparent overlay: blue cursor, waveform, pointing arcs, multi-monitor mapping. Also owns `ignoresMouseEvents` toggling. |
| `ScreenAnnotation.swift` | ~217 | Parses `[BOX:...]` / `[HIGHLIGHT:...]` / arrow tags. Corner format, lenient about separators. |
| `ScreenAnnotationLayer.swift` | ~150 | `Canvas` rendering for boxes, arrows and highlights. |
| `CompanionResponseOverlay.swift` | ~217 | Response bubble and waveform next to the cursor. |
| `ElementLocationDetector.swift` | ~335 | Locates UI elements in screenshots for pointing. |

### Agent, tools and MCP
| File | Lines | Purpose |
|------|-------|---------|
| `AgentTurnRunner.swift` | ~250 | The agent loop: max 4 iterations, screenshot on iteration 0 only, per-tool timeouts. |
| `AgentToolRegistry.swift` | ~490 | Built-in read-only tools. `requiresConfirmation` defaults to true for unknown names. |
| `StructuredTextToolProtocol.swift` | ~330 | `[TOOL:name:{json}]` prompt generation and lenient parsing, with an anti-echo guard. |
| `MCPClient.swift` | ~330 | `MCPServerConnection`: transport-agnostic JSON-RPC 2.0 framing, timeouts, and the MCP handshake. Picks a transport via `makeTransport(for:)`. |
| `MCPTransport.swift` | ~55 | The `MCPTransport` protocol: start/send/incomingMessages/recentDiagnostics/close. Isolates byte transport + framing from JSON-RPC. |
| `MCPStdioTransport.swift` | ~230 | Stdio transport: child process over stdin/stdout as NDJSON, login-shell PATH resolution (`LoginShellEnvironment`), stderr ring buffer. |
| `MCPStreamableHTTPTransport.swift` | ~230 | Remote transport: JSON-RPC over MCP Streamable HTTP (one POST per message; parses JSON + SSE replies; `Mcp-Session-Id`, auth headers). |
| `MCPCatalog.swift` | ~90 | Marketplace catalog model: `MCPCatalogEntry` (stdio/remote install template) + `ConfigField` (user-supplied env/header, secret flag) + the bundled-registry file shape. |
| `MCPCatalogProvider.swift` | ~55 | `MCPCatalogProvider` protocol + `CuratedRegistryCatalogProvider` (loads the bundled `curated-mcp-registry.json`). Composio's provider will conform here in Phase 3. |
| `curated-mcp-registry.json` | ~180 | Bundled curated MCP registry (resource): 8 official stdio servers + the hosted GitHub remote server. |
| `InstalledMCPServerStore.swift` | ~270 | Source of truth over `~/.wisp/mcp.json` (preserves unknown keys). Install/uninstall/enable/allow-list + `installRemoteServer` (Composio); reloads MCPManager on every change. |
| `ComposioKeychainStore.swift` | ~75 | The Composio `x-api-key` in the login Keychain (mirrors `ProviderKeychainStore`). Never in the config file or logs. |
| `ComposioClient.swift` | ~110 | Validates the Composio **connect** key by an MCP `initialize` against `https://connect.composio.dev/mcp` (auth header `x-consumer-api-key`). No provisioning — the connect server is a fixed universal endpoint. |
| `ComposioAccountStore.swift` | ~110 | Composio marketplace state: `connect(apiKey:)` validates the key then installs one remote server (`composio-connect`) over the Phase 1 transport; `disconnect()` removes it. Off-machine/opt-in. |
| `MCPManager.swift` | ~258 | Reads `~/.wisp/mcp.json`, namespaces tools `server__tool`, caps exposed tools at 8. |
| `SkillManager.swift` | ~120 | Reads `~/.wisp/skills/*.md`, parses `name`/`description` frontmatter, serves full bodies on demand via `load_skill`. |
| `SkillIndex.swift` | ~35 | Terse per-line skill index appended to the system prompt alongside tool instructions. |
| `ToolConfirmationCoordinator.swift` | ~193 | Permission requests with a 45s timeout and spoken-affirmative parsing. |
| `ToolConfirmationView.swift` | ~130 | The Dynamic-Island glass confirmation panel (`WispGlassPanel` + `WispMark`): request-dominant, exact call in a chip, Cancel / Allow→, "or just say yes". Presented via the existing overlay plumbing, positioned under the notch; calls `flashIsland(.success/.error)` on allow/deny. |
| `BackgroundTaskLauncher.swift` | ~127 | Tasks that outlive the conversation, max 2 concurrent, notify on completion. |
| `AgentTaskRegistry.swift` | ~140 | Task and step records backing the dashboard's Activity tab. |

### Voice modes, glance cards & sources
| File | Lines | Purpose |
|------|-------|---------|
| `VoiceOutputPreference.swift` | ~50 | Source of truth for voice/silent mode (reply speech on/off). Persists; defaults on. |
| `WispVoiceAffordance.swift` | ~200 | Shared VoiceOS-style voice affordance: a Liquid Glass waveform reflecting `voiceState` and the live mic level (`currentAudioPowerLevel`). Used as the notch HUD's centerpiece and in the menu bar panel so both surfaces show one living voice element. Self-animates via a `TimelineView` clock that pauses while idle (no redraws on a resident app). |
| `SpokenLineParser.swift` | ~90 | Parses/strips the `[SAY: …]` tag — the model's per-reply "speak this" line. |
| `GlanceCard.swift` | ~500 | `[CARD:…]` parser + intent model (`GlanceCardRequest`/`ResolvedGlanceCard`) and the generic block card. |
| `GlanceCardView.swift` | ~180 | Renderer for the generic block card (header/list/keyValue/stats). |
| `GlanceCardDataPreference.swift` | ~40 | The single gate for **network** card data (weather, sources). Default on. |
| `WeatherSnapshot.swift` / `WeatherDataProvider.swift` / `WeatherCardView.swift` | ~330/~200/~260 | Weather kind: Open-Meteo fetch → snapshot → Apple-Weather-style card. |
| `CalendarSnapshot.swift` / `CalendarDataProvider.swift` / `CalendarCardView.swift` | ~50/~110/~160 | Calendar kind: EventKit on-device read → next events card. Needs Calendar permission. |
| `NowPlayingDataProvider.swift` / `NowPlayingCardView.swift` | ~150/~110 | Now-playing kind: AppleScript to Music/Spotify (best-effort, on-device). Needs Automation permission. |
| `ConfiguredSourceStore.swift` / `RESTSourceDataProvider.swift` / `SourceCardView.swift` | ~90/~140/~90 | `source` kind: user endpoints in `~/.wisp/sources.json`, fetched over HTTPS and mapped to generic blocks. |
| `SourcesTab.swift` | ~150 | Dashboard Sources tab: the live-card-data master toggle + the configured-source list. |

### Dashboard and UI
| File | Lines | Purpose |
|------|-------|---------|
| `DashboardWindowController.swift` | ~109 | Real `NSWindow` host. Raises activation policy to `.regular` while open. |
| `DashboardView.swift` | ~708 | Sidebar shell plus the tabs (Home is the default) and the live memory footer. The content area follows the system appearance (adaptive light/dark). |
| `HomeTab.swift` | ~250 | The dashboard's **Home command centre**: a hero (Wisp mark + `wisp` wordmark + "What can I help with?"), a summon card showing the talk/type/dictate gestures, a quick-actions grid that navigates the other tabs, and a recent-activity list from `AgentTaskRegistry`. Adaptive. The conversational hero itself lives in the Dynamic Island, not here. |
| `DashboardToolsTab.swift` | ~253 | Tools & Servers tab: MCP status, per-server stderr, registered tools. |
| `MarketplaceTab.swift` | ~700 | Dashboard Marketplace tab: browse/search/filter the curated registry, install (config-field sheet for keys), enable/disable, remove, per-tool toggles, the model tool-budget meter, and a Composio cloud-toolkits section (key entry + toolkit list + off-machine label). Reads `InstalledMCPServerStore` + `MCPManager` + `ComposioAccountStore`. |
| `ShortcutsTab.swift` | ~250 | Dashboard Shortcuts tab: view/rebind the hold chord and hands-free double-tap, toggle hands-free, reset to defaults. Reads/writes `ShortcutBindingStore`. |
| `MenuBarPanelManager.swift` | ~247 | `NSStatusItem` + floating `NSPanel` lifecycle. |
| `NotchWindowController.swift` | ~230 | Hosts the notch HUD in a fixed-size borderless non-activating `NotchPanel`. Polls `NSEvent.mouseLocation` against fixed hot-zones (with hysteresis) to expand/collapse, and toggles `ignoresMouseEvents` so the window is click-through while collapsed. Force-collapses on `.wispDismissPanel` (so it's out of the way of a skill launch or push-to-talk capture) and reloads skills when the panel opens. Owns `NotchViewModel`. |
| `NotchHUDView.swift` | ~380 | The notch HUD's SwiftUI content: collapsed pill (the liquid `WispMark` + live state dot) and the hover-expanded quick-panel — shortcuts cheat-sheet, a **SKILLS grid of one-click launcher chips** (each runs its skill via `CompanionManager.runSkill`), active integrations, and a dock-cursor toggle in the header. Pins `.colorScheme(.dark)`; mark/dot/label are driven by `companionManager.islandState`. `DS.*` throughout. |
| `NotchGeometry.swift` | ~85 | Resolves collapsed/expanded window frames from `NSScreen.safeAreaInsets` + `auxiliaryTop{Left,Right}Area`, with a floating-pill fallback on non-notch Macs. |
| `CompanionPanelView.swift` | ~775 | The menu bar panel's SwiftUI content. |
| `DesignSystem.swift` | ~940 | The legacy `DS.*` token **facade**: `DS.Colors`, `DS.Spacing`, `DS.CornerRadius`, `DS.Animation` now forward to the `Wisp*` tokens in `DesignSystem/`, so all existing call sites reskin from one place and `DS.Colors.*` are now adaptive. Also the shared Liquid Glass helpers: `wispNotchGlassSurface(in:)` (fixed dark, notch), `wispGlassSurface(cornerRadius:interactive:)` and `wispGlassCard(cornerRadius:)` (adaptive glass tint, panel + dashboard). |
| `PerfMetricsRecorder.swift` | ~158 | Per-phase turn timings, medians split by whether a screenshot was attached. |
| `SystemReadouts.swift` | ~143 | Memory via `host_statistics64`; Ollama residency via `/api/ps`. |
| `WindowPositionManager.swift` | ~262 | Window placement and permission helpers. |
| `WispAnalytics.swift` | ~153 | Gated off. Sends nothing. Kept so the call sites still compile. |

### Design system & components
The Wisp visual identity. Prefer these tokens/components over ad-hoc styling; the legacy `DS.*`
names forward here.

| File | Lines | Purpose |
|------|-------|---------|
| `DesignSystem/WispColors.swift` | ~180 | The palette: raw brand hexes (`WispColor.Brand.*` — sage/lavender/moss/ink/cloud/bone), **adaptive** semantic tokens (`.background`/`.textPrimary`/`.accent`/… resolve light/dark via a dynamic `NSColor`), a fixed **on-glass** set (`OnGlass.*`) for always-dark surfaces, and adaptive glass tints. `adaptive(light:dark:)` is the helper. |
| `DesignSystem/WispTypography.swift` | ~60 | `WispFont` scale (SF Pro/rounded + SF Mono), the lowercase `wisp` wordmark, and `wispSectionLabel()`. |
| `DesignSystem/WispMetrics.swift` | ~50 | `WispSpacing` + `WispRadius` scales (softer/rounder; hero input = 22). |
| `DesignSystem/WispShadows.swift` | ~35 | `WispShadow` (`.ambient`/`.floating`/`.island`) + `wispShadow(_:)`. Soft, low-opacity only. |
| `DesignSystem/WispGradients.swift` | ~55 | The single signature gradient (sage→mist→lavender) and its animated variants. Use sparingly. |
| `DesignSystem/WispMotion.swift` | ~55 | Named animation curves (`quick`/`smooth`/`gentle`/`island`/`springSoft`/`breath`) + reduce-motion helpers. |
| `Components/WispGlassComponents.swift` | ~200 | `WispGlassPanel` container, `WispGlassButtonStyle` (subtle/prominent), `WispGlassIcon`, and `PressableScaleButtonStyle`. |
| `Components/WispGlassInput.swift` | ~90 | The floating "Ask Wisp anything…" field; the signature gradient blooms into the border on focus. |
| `Components/WispMark.swift` | ~180 | The liquid-ribbon logo. `WispMarkState` drives per-state motion; static mode; clock paused at rest. `CompanionVoiceState.markState` maps to it. |
| `Components/WispIcon.swift` | ~200 | The Liquid Icon System: `WispIconSymbol` (bespoke single-stroke glyphs + `.system` SF-Symbol fallback), `WispIconState`, rendered by `WispIcon`. |
| `DynamicIsland/WispIslandState.swift` | ~120 | The 9-state island vocabulary + its mark/label/accent mapping. Derived, not stored — see `CompanionManager.islandState`. |

### Unused upstream leftovers
The old cloud client files (`ClaudeAPI.swift`, `OpenAIAPI.swift`, `ElevenLabsTTSClient.swift`,
`AssemblyAIStreamingTranscriptionProvider.swift`, `OpenAIAudioTranscriptionProvider.swift`)
have been deleted. Cloud chat is now the bring-your-own-key `ModelProvider` path above, not
these. Only the `worker/` directory remains as upstream leftover, and it is not used by this
build — there is no Cloudflare Worker.

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

## Local services

Both must be running for the app to work:

```bash
ollama serve                     # port 11434
```

```bash
curl -s http://localhost:8004/ -o /dev/null -w "%{http_code}\n"   # Chatterbox TTS health
```

There is no Cloudflare Worker. The `worker/` directory is upstream leftover and is not
used by this build.

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
