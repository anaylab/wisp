# Wisp - Agent Instructions

## Overview

macOS menu bar companion app, formerly Clicky. Lives entirely in the macOS status bar
(no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel
with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input,
transcribes it on-device, and sends the transcript + a screenshot to a local model. The
model responds with text, which is spoken by a local TTS server. A blue cursor overlay
can fly to and point at UI elements the model references on any connected monitor, and
can draw boxes, arrows and highlights on screen.

**Everything runs on this machine. There are no API keys, no Cloudflare Worker, and no
analytics.** The only network traffic is HTTP to `localhost` (Ollama on 11434, Chatterbox
TTS on 8004). This is the defining constraint of the project — do not introduce a cloud
dependency without asking.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon. The dashboard raises the
  activation policy to `.regular` while open, and drops back to `.accessory` on close.
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel, cursor
  overlay, and dashboard window
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Chat / Vision**: Ollama `qwen2.5vl:7b` at `http://localhost:11434`, NDJSON streaming,
  selected via `ChatProvider` in Info.plist
- **Speech-to-Text**: Apple Speech framework, on-device, via `VoiceTranscriptionProvider`
- **Text-to-Speech**: Chatterbox Nano at `http://localhost:8004`, synthesised and played
  sentence-by-sentence so playback starts before the whole reply is rendered
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor, downscaled to 896px
- **Element Pointing**: the model embeds `[POINT:x,y:label:screenN]` tags; the overlay
  parses them, maps to the correct monitor, and animates the cursor along a bezier arc
- **Screen Annotation**: `[BOX:left,top,right,bottom:label]` and `[HIGHLIGHT:...]` tags
  render through a `Canvas` layer in the overlay. Note the corner format — the model emits
  corners, not origin+size.
- **Agent loop**: off by default behind `AgentModeEnabled` in Info.plist. When on, tools
  are called via structured `[TOOL:name:{json}]` tags rather than native tool_calls, since
  the local model is unreliable at the latter.
- **MCP**: hand-rolled JSON-RPC 2.0 over stdio subprocess. Config at `~/.wisp/mcp.json`
  in Claude Desktop's format.
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

**Global Push-To-Talk Shortcut**: Uses a listen-only `CGEvent` tap rather than an AppKit
global monitor, so modifier-based shortcuts like ctrl+option are detected reliably in the
background.

**Model residency is the binding constraint.** On 18GB, one 7B vision model plus the TTS
server leaves almost nothing spare. A second concurrently-resident LLM is not feasible at
that size. `ModelAccessGate` serialises all model calls so background work never evicts
the prefix cache an interactive turn is depending on, and the keep-warm heartbeat is
suspended during agent loops for the same reason.

**Vision encoding dominates latency.** At 1280px a screenshot costs ~4049 tokens; at 896px
it costs ~1095. Screenshots are therefore capped at 896px, and are skipped entirely when
the prompt does not appear to refer to the screen.

## Key Files

Grouped by what they do. Line counts are approximate.

### Core pipeline
| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~105 | Menu bar app entry point. `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate`, which creates `MenuBarPanelManager` and starts `CompanionManager`. |
| `CompanionManager.swift` | ~1475 | Central state machine and integration hub. Owns dictation, shortcut monitoring, screen capture, the chat client, TTS, overlays, annotations, agent mode and tool confirmations. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline: mic capture via `AVAudioEngine`, permission checks, transcript finalisation, live audio levels for the waveform. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk via a listen-only `CGEvent` tap. |
| `CompanionScreenCaptureUtility.swift` | ~139 | Multi-monitor capture via ScreenCaptureKit, downscaled to 896px. |

### Local model stack
| File | Lines | Purpose |
|------|-------|---------|
| `LocalOllamaAPI.swift` | ~235 | Ollama client: NDJSON streaming, `keep_alive`, per-mode context and token limits, and the heuristic that decides whether a prompt needs a screenshot at all. |
| `BuddyVisionChatClient.swift` | ~47 | Chat-client protocol and factory, keyed off `ChatProvider`. |
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
| `AgentToolRegistry.swift` | ~167 | Built-in read-only tools. `requiresConfirmation` defaults to true for unknown names. |
| `StructuredTextToolProtocol.swift` | ~275 | `[TOOL:name:{json}]` prompt generation and lenient parsing, with an anti-echo guard. |
| `MCPClient.swift` | ~447 | JSON-RPC 2.0 over stdio subprocess, login-shell PATH resolution, stderr ring buffer. |
| `MCPManager.swift` | ~258 | Reads `~/.wisp/mcp.json`, namespaces tools `server__tool`, caps exposed tools at 8. |
| `ToolConfirmationCoordinator.swift` | ~193 | Permission requests with a 45s timeout and spoken-affirmative parsing. |
| `ToolConfirmationView.swift` | ~130 | The on-screen approve/deny card. |
| `BackgroundTaskLauncher.swift` | ~127 | Tasks that outlive the conversation, max 2 concurrent, notify on completion. |
| `AgentTaskRegistry.swift` | ~140 | Task and step records backing the dashboard's Activity tab. |

### Dashboard and UI
| File | Lines | Purpose |
|------|-------|---------|
| `DashboardWindowController.swift` | ~109 | Real `NSWindow` host. Raises activation policy to `.regular` while open. |
| `DashboardView.swift` | ~708 | Sidebar shell plus Activity, Conversation and Model & Performance tabs, and the live memory footer. |
| `DashboardToolsTab.swift` | ~253 | Tools & Servers tab: MCP status, per-server stderr, registered tools. |
| `MenuBarPanelManager.swift` | ~247 | `NSStatusItem` + floating `NSPanel` lifecycle. |
| `CompanionPanelView.swift` | ~775 | The menu bar panel's SwiftUI content. |
| `DesignSystem.swift` | ~880 | `DS.Colors`, `DS.Spacing`, `DS.CornerRadius` tokens. All UI references these. |
| `PerfMetricsRecorder.swift` | ~158 | Per-phase turn timings, medians split by whether a screenshot was attached. |
| `SystemReadouts.swift` | ~143 | Memory via `host_statistics64`; Ollama residency via `/api/ps`. |
| `WindowPositionManager.swift` | ~262 | Window placement and permission helpers. |
| `WispAnalytics.swift` | ~153 | Gated off. Sends nothing. Kept so the call sites still compile. |

### Unused upstream leftovers
`ClaudeAPI.swift`, `OpenAIAPI.swift`, `ElevenLabsTTSClient.swift`,
`AssemblyAIStreamingTranscriptionProvider.swift`, `OpenAIAudioTranscriptionProvider.swift`
and `worker/` all target cloud services this build does not use. They are still compiled
and still referenced by their provider factories, so they work if a key is supplied — but
nothing selects them by default.

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
