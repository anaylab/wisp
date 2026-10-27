# BYOK Provider Selection — Implementation Plan

Let users choose which model backs Wisp — the local Ollama model (default, private,
free) or a cloud provider they supply their own key for. Cloud is strictly opt-in, and
any cloud selection is labeled "your screenshots leave this machine," because this app
captures the screen every turn.

This plan is grounded in the current code, not the CLAUDE.md description of it.

---

## Ground truth corrections (read first)

Two facts in `CLAUDE.md` are stale and change the plan:

1. **`ClaudeAPI.swift`, `OpenAIAPI.swift`, `ElevenLabsTTSClient.swift` no longer exist.**
   `ls` confirms they were deleted in the provider-runtime refactor. CLAUDE.md's "Unused
   upstream leftovers" section still lists them. There is **nothing to rehabilitate** — cloud
   clients are written from scratch. (Fix CLAUDE.md as the last step of this work.)

2. **There are two model surfaces, and the newer one is the target.**
   - Legacy: `BuddyVisionChatClient.analyzeImageStreaming(...)` — flat strings + images.
     Used by the **spoken/interactive turn** at `CompanionManager.swift:870`.
   - Current: `ModelProvider.streamTurn(_:onTextDelta:)` over `ModelRequest` / `BuddyChatTurn`.
     Used by the **agent loop** (`AgentTurnRunner`, `BackgroundTaskLauncher`).

   `ModelProvider` already declares `ModelCapabilities.supportsVision` and
   `ModelDeployment.sendsDataOffThisMachine`, with comments about "a router choosing between
   providers" and "routing on privacy." It is the abstraction the architects built *for this
   feature*. New providers conform to `ModelProvider`; the spoken path migrates onto it so
   there is one selected provider, not two.

---

## Target architecture

```
                 BuddyChatProviderSelection (UserDefaults)  ← user's live choice
                 ProviderKeychainStore       (Keychain)     ← per-provider API key
                                   │
                                   ▼
                   ModelProviderFactory.make(...)  → any ModelProvider
                                   │
        ┌──────────────────────────┼───────────────────────────┐
        ▼                          ▼                            ▼
   OllamaProvider          AnthropicProvider              GeminiProvider
   (exists, local)         (new, cloud)                   (new, cloud)      … OpenAIProvider
                                   │
                                   ▼
        CompanionManager.selectedModelProvider   ← ONE provider, both paths
             ├── spoken turn   (migrated to streamTurn)
             └── agent loop    (already streamTurn)
```

The local-only machinery (keep-warm heartbeat, PTT preload, `ModelAccessGate` residency
serialization, 896px screenshot cap) is gated on `deployment.location == .onThisMachine`,
read off the live provider — not on a hardcoded `ChatProvider == "ollama"` string.

---

## Step 1 — Provider selection model (no behavior change yet)

**New file: `BuddyChatProviderKind.swift`**

```swift
import Foundation

/// Which backend answers the user. The selection is a runtime setting, not a
/// compile-time Info.plist value, because users change it live in the dashboard.
enum BuddyChatProviderKind: String, CaseIterable, Identifiable, Sendable {
    case localOllama
    case anthropic
    case openAI
    case gemini

    var id: String { rawValue }

    /// Shown in the provider picker.
    var displayName: String {
        switch self {
        case .localOllama: return "Local (Ollama)"
        case .anthropic:   return "Claude (Anthropic)"
        case .openAI:      return "GPT (OpenAI)"
        case .gemini:      return "Gemini (Google)"
        }
    }

    /// True when choosing this provider sends screenshots off this machine.
    /// Drives the privacy notice in the UI and the local-only-machinery gates.
    var sendsScreenshotsOffThisMachine: Bool {
        self != .localOllama
    }

    /// Whether this provider needs a user-supplied API key.
    var requiresAPIKey: Bool {
        self != .localOllama
    }
}
```

**New file: `BuddyChatProviderSelection.swift`** — the persisted live choice.

```swift
import Foundation

/// The user's currently selected chat provider, persisted across launches.
/// Single source of truth read by the factory and the local-only-machinery gates.
enum BuddyChatProviderSelection {
    private static let userDefaultsKey = "SelectedChatProviderKind"

    /// Falls back to the Info.plist default the first time, so an unconfigured
    /// install still starts on local Ollama.
    static var current: BuddyChatProviderKind {
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let kind = BuddyChatProviderKind(rawValue: raw) {
            return kind
        }
        let plistDefault = AppBundleConfiguration.stringValue(forKey: "ChatProvider")?.lowercased()
        return plistDefault == "ollama" ? .localOllama : .localOllama
    }

    static func set(_ kind: BuddyChatProviderKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: userDefaultsKey)
    }
}
```

*Nothing consumes these yet.* Land them first so later diffs are small.

---

## Step 2 — API key storage in the Keychain

**New file: `ProviderKeychainStore.swift`** — one key per provider, never in UserDefaults,
never in Info.plist, never logged.

```swift
import Foundation
import Security

/// Stores per-provider API keys in the login Keychain. The user pastes their own
/// key; Wisp only stores and retrieves it. Never logged, never written to
/// UserDefaults or Info.plist. Deleting a provider's key disables it.
enum ProviderKeychainStore {
    private static let service = "com.wisp.provider-api-keys"

    static func save(_ apiKey: String, for provider: BuddyChatProviderKind) {
        let account = provider.rawValue
        // Replace any existing item: delete-then-add is simpler than SecItemUpdate
        // and there is only ever one key per provider.
        delete(for: provider)
        guard let data = apiKey.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func apiKey(for provider: BuddyChatProviderKind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    static func hasKey(for provider: BuddyChatProviderKind) -> Bool {
        apiKey(for: provider) != nil
    }

    static func delete(for provider: BuddyChatProviderKind) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

Note on entitlements: a menu-bar app writing generic-password items to its own login
Keychain works without the Keychain-sharing entitlement. Confirm the app isn't sandboxed
in a way that needs a keychain-access-group; if it is, add one.

---

## Step 3 — The cloud providers (conform to `ModelProvider`)

Each new provider is a `struct`/`final class` conforming to `ModelProvider`
(`ModelProvider.swift:191`). The required surface:

- `var identifier: String`
- `var capabilities: ModelCapabilities` — set `supportsVision: true`,
  `supportsNativeToolCalls: true` for cloud (unlike the local `[TOOL:...]` text hack),
  a real `contextWindowTokens`.
- `var deployment: ModelDeployment` — `.remote(serviceName:)`, which makes
  `sendsDataOffThisMachine` true automatically.
- `func streamTurn(_:onTextDelta:) async throws -> BuddyChatTurn`

Each provider's `streamTurn` must:

1. Translate `ModelRequest` (systemPrompt, `[BuddyChatMessage]` with `.image`/`.text`/
   `.toolResult` blocks, `tools`, `maxOutputTokens`) into that vendor's wire format.
2. Stream tokens, calling `onTextDelta` with **newly generated text only** (the protocol
   doc is explicit — cumulative text produces garbled speech; diff if the vendor sends
   cumulative).
3. Build a `BuddyChatTurn` of ordered `BuddyContentBlock`s — prose runs and `toolUse`
   blocks in the position the model produced them. Native tool calls map straight to
   `.toolUse`; **do not** route cloud output through `StructuredTextToolProtocol` (that's a
   local-model workaround, per `OllamaProvider`'s own comment).
4. Rethrow `CancellationError` as itself, wrap other failures as `BuddyChatError`.

**New files:**
- `AnthropicProvider.swift` — Messages API, `image` content blocks (base64), streaming SSE,
  native `tool_use` / `tool_result`.
- `GeminiProvider.swift` — `generateContent` streaming; **best pixel-grounding of the cloud
  options**, so prioritize it for the pointing capability.
- `OpenAIProvider.swift` — Chat Completions / Responses API, image_url data URIs.

Each reads its key via `ProviderKeychainStore.apiKey(for:)` at construction and throws a
clear "no API key set" `BuddyChatError` if absent.

Reference the `claude-api` skill before writing `AnthropicProvider` for current model IDs,
streaming shape, and image-block format.

---

## Step 4 — The factory

**Rewrite `BuddyVisionChatClient.swift`'s factory** (or add a new `ModelProviderFactory.swift`
and retire `BuddyVisionChatClientFactory`):

```swift
enum ModelProviderFactory {
    static func make(
        _ kind: BuddyChatProviderKind = BuddyChatProviderSelection.current
    ) -> any ModelProvider {
        switch kind {
        case .localOllama:
            let baseURL = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL")
                ?? "http://localhost:11434"
            let model = AppBundleConfiguration.stringValue(forKey: "OllamaModel")
                ?? "qwen2.5vl:3b"
            return OllamaProvider(baseURL: baseURL, model: model)
        case .anthropic:
            return AnthropicProvider(apiKey: ProviderKeychainStore.apiKey(for: .anthropic))
        case .openAI:
            return OpenAIProvider(apiKey: ProviderKeychainStore.apiKey(for: .openAI))
        case .gemini:
            return GeminiProvider(apiKey: ProviderKeychainStore.apiKey(for: .gemini))
        }
    }
}
```

---

## Step 5 — Collapse CompanionManager onto one selected provider

Today `CompanionManager` holds **two** clients:
- `visionChatClient: any BuddyVisionChatClient` (`:77`) — spoken path.
- `agentModelProvider: any ModelProvider` (`:88`) — agent path, wraps the same Ollama client.

Replace both with a single:

```swift
private var selectedModelProvider: any ModelProvider = ModelProviderFactory.make()
```

**Migrate the spoken path** (`CompanionManager.swift:867–889`) from
`visionChatClient.analyzeImageStreaming(...)` to `selectedModelProvider.streamTurn(...)`:

- Build a `ModelRequest` from the system prompt (`companionVoiceResponseSystemPrompt +
  ScreenAnnotationParser.promptInstructions`), the history as `[BuddyChatMessage]` (drop
  `legacyStringPairs`), the transcript as a user message, and the labeled images as `.image`
  blocks. Pass `maxOutputTokens: nil` so each provider applies its own spoken-reply ceiling
  (local keeps its short cap; cloud uses a billing-appropriate one).
- Feed `onTextDelta` into `sentenceStreamer?.append` exactly as `onTextChunk` does now.
- Keep the `ModelAccessGate.withAccess(priority: .interactive)` wrapper for local; see Step 6
  for gating it out on cloud.

Both `agentModelProvider` call sites (`:819`, `:1396`) become `selectedModelProvider`.

**Add `rebuildSelectedModelProvider()`** — called when the dashboard changes provider or key,
so the switch takes effect mid-session without a relaunch:

```swift
func rebuildSelectedModelProvider() {
    selectedModelProvider = ModelProviderFactory.make()
    reconfigureLocalOnlyMachinery()   // see Step 6
}
```

Once nothing constructs `LocalOllamaAPI` directly through `BuddyVisionChatClient`, that
protocol and its factory can be deleted (or kept only if `OllamaProvider` still wraps a
`LocalOllamaAPI` internally — it does, so keep `LocalOllamaAPI`, retire only the *factory*
and the `visionChatClient` property).

---

## Step 6 — Gate local-only machinery on deployment, not a plist string

Everything below is meaningful only for a model resident on this machine. Drive each off
`selectedModelProvider.deployment.location == .onThisMachine` (or the
`BuddyChatProviderSelection.current.sendsScreenshotsOffThisMachine` flag):

| Machinery | File / anchor | Change |
|---|---|---|
| Keep-warm heartbeat | `CompanionManager.swift:1071` | Skip entirely when provider is remote. Already checks `ChatProvider == "ollama"` — switch to the live selection. |
| **PTT key-down preload** | `CompanionManager.swift` `preloadLocalModelForImminentPushToTalkTurn()` | Already gated on `ChatProvider == "ollama"`; change to read `BuddyChatProviderSelection.current`. |
| `ModelAccessGate` serialization | spoken path `:867`, agent runner | The gate exists to protect prefix-cache residency of a local model. For cloud it's needless serialization of independent network calls — bypass or make it a no-op when remote. |
| 896px screenshot cap | `CompanionScreenCaptureUtility.swift` | Local caps at 896px for vision-token cost. Cloud can afford higher-res but pays latency/$$. Make capture dimension a per-provider property (add to `ModelCapabilities` or a small `preferredCaptureLongestEdge` on the provider). Start conservative. |
| Screenshot-skip heuristic | `LocalOllamaAPI` / `OllamaProvider` | The "does this prompt need a screenshot" heuristic is fine to keep for all providers — it saves cost everywhere. |

Add `reconfigureLocalOnlyMachinery()` that starts/stops the keep-warm task based on the
current provider.

---

## Step 7 — Settings UI (Model & Performance tab)

In `DashboardView.swift` (Model & Performance tab):

- **Provider picker** over `BuddyChatProviderKind.allCases`, bound to
  `BuddyChatProviderSelection`. On change → `companionManager.rebuildSelectedModelProvider()`.
- **Per-provider API key field** (SecureField) for the selected cloud provider. Save →
  `ProviderKeychainStore.save(...)` then rebuild. Show only "key set / not set", never the
  key value. A "Clear key" button calls `.delete`.
- **Privacy notice**, prominent, shown whenever a cloud provider is selected:
  > ⚠️ Screenshots and your voice transcript will be sent to <provider> over the network.
  > Paid API tiers generally don't train on your data; free tiers often do. Local stays on
  > this machine.
- Follow `DesignSystem.swift` tokens (`DS.Colors`, `DS.Spacing`, `DS.CornerRadius`); every
  interactive control shows a pointer cursor on hover (project convention).

---

## Step 8 — Per-provider pointing verification

Pixel-accurate `[POINT:x,y]` is the load-bearing capability. Cloud models vary at raw pixel
grounding (Gemini strongest; Claude/GPT weaker historically). For each cloud provider:

- Run the same pointing check described at `LocalOllamaAPI.swift:5` (image whose true pixel
  size matches its declared size).
- Expect per-provider system-prompt tuning of the `[POINT/BOX/HIGHLIGHT]` instructions.
- If a provider can't ground reliably, still allow it for chat but note pointing may be
  approximate. Don't silently ship bad coordinates.

---

## Step 9 — Housekeeping

- Update `CLAUDE.md`: remove the dead `ClaudeAPI.swift`/`OpenAIAPI.swift`/`ElevenLabsTTSClient.swift`
  leftovers section; add the new files; document that provider selection is a runtime setting
  with keys in the Keychain; note the local-first default is preserved.
- Add the new files to the Xcode target (via Xcode, not `xcodebuild` — TCC).
- `WispAnalytics` stays gated off. No telemetry about provider choice.

---

## Suggested sequencing (each step compiles and is shippable)

1. **Steps 1 + 2** — enum, selection store, Keychain store. No behavior change. Land it.
2. **Step 3 (Gemini only) + Step 4 + Step 5** — one cloud provider end-to-end behind the
   factory, spoken path migrated to `streamTurn`. Local still default. This is the risky
   refactor; keep it isolated.
3. **Step 6** — gate local-only machinery. Verify local still preloads/keeps warm and cloud
   doesn't ping localhost.
4. **Step 7** — settings UI + privacy label. Now users can actually switch.
5. **Step 8** — pointing verification for Gemini; tune prompt.
6. **Add Anthropic + OpenAI** (repeat Step 3 shape), verify pointing each.
7. **Step 9** — docs + CLAUDE.md.

## Explicitly out of scope

- Any *provided* free cloud tier (embedded shared key or a proxy/worker). That reintroduces
  the deleted Cloudflare worker and/or trains-on-your-screenshots free tiers. Parked pending
  a separate privacy decision. BYOK only.
- Per-turn provider routing (auto-pick cheapest/fastest). The `ModelCapabilities` fields
  support it later, but selection stays a manual user setting for now.
