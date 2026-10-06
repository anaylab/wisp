#!/bin/bash
#
# Adversarial suite against the provider-agnostic runtime.
#
# Two parts:
#   1. A structural check that AgentTurnRunner type-checks with no Ollama
#      source file present at all (invariant 1).
#   2. The behavioural suite, linked against the real application sources so
#      the REAL AgentTurnRunner / AgentToolRegistry / ToolConfirmationCoordinator
#      are the code under attack.
#
# Never invokes xcodebuild — that would invalidate the app's TCC permissions
# (see CLAUDE.md).
#
set -uo pipefail
cd "$(dirname "$0")/../.."

SDK="$(xcrun --show-sdk-path --sdk macosx)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

SWIFTFLAGS=(-target arm64-apple-macos26.0 -sdk "$SDK"
            -swift-version 5 -default-isolation MainActor
            -enable-upcoming-feature MemberImportVisibility)

# ── Part 1: invariant 1, structurally ────────────────────────────────────
#
# AgentTurnRunner's own collaborators are stubbed so the check is about the
# runner, not about the built-in tool zoo the registry happens to pull in.
echo "── Invariant 1 — AgentTurnRunner compiles with zero Ollama sources ──"
mkdir -p "$BUILD_DIR/iso"
cat > "$BUILD_DIR/iso/Stubs.swift" <<'STUB'
import Foundation
@MainActor final class AgentToolRegistry {
    static let shared = AgentToolRegistry()
    struct Outcome: Sendable {
        let content: String; let isError: Bool; let wasDeclined: Bool
        var executedToolInput: JSONValue? = nil
    }
    func definitions(forRequest transcript: String,
                     isToolPermitted: (String) -> Bool) -> [BuddyToolDefinition] { [] }
    func invoke(name: String, input: JSONValue) async -> Outcome {
        Outcome(content: "", isError: false, wasDeclined: false)
    }
}
@MainActor final class ToolConfirmationCoordinator {
    static let shared = ToolConfirmationCoordinator()
    static let confirmationTimeoutSeconds: TimeInterval = 45
    func expiryDateOfPendingConfirmation(forToolNamed toolName: String) -> Date? { nil }
}
// Named only for their long-running tool timeouts.
enum BuddyDelegationToolNames { static let askBuddy = "ask_buddy" }
enum BuddyDelegationPolicy { static let answerTimeoutSeconds: TimeInterval = 300 }
enum ShortcutsBridge { static let runTimeoutSeconds: TimeInterval = 120 }
STUB
if swiftc -typecheck "${SWIFTFLAGS[@]}" \
     leanring-buddy/AgentTurnRunner.swift \
     leanring-buddy/ModelProvider.swift \
     leanring-buddy/BuddyChatTypes.swift \
     leanring-buddy/ToolMetadata.swift \
     leanring-buddy/ModelAccessGate.swift \
     leanring-buddy/AgentRunToolkit.swift \
     "$BUILD_DIR/iso/Stubs.swift" 2> "$BUILD_DIR/iso.err"; then
  echo "  PASS  runner type-checks without OllamaProvider.swift or LocalOllamaAPI.swift"
else
  echo "  FAIL  runner does not compile without the Ollama sources"
  sed -n '1,25p' "$BUILD_DIR/iso.err"
fi
if grep -nE '\b(LocalOllamaAPI|OllamaProvider|ollama|11434|num_ctx|keep_alive|qwen)\b' \
     leanring-buddy/AgentTurnRunner.swift | grep -vE '^\s*[0-9]+:\s*//' > "$BUILD_DIR/refs" ; then
  echo "  FAIL  AgentTurnRunner names Ollama outside comments:"; cat "$BUILD_DIR/refs"
else
  echo "  PASS  AgentTurnRunner names Ollama only in prose"
fi

# ── Part 2: the behavioural suite ────────────────────────────────────────
mkdir -p "$BUILD_DIR/stub"
cat > "$BUILD_DIR/stub/PostHog.swift" <<'STUB'
import Foundation
public final class PostHogConfig { public init(apiKey: String, host: String) {} }
public final class PostHogSDK {
    public static let shared = PostHogSDK()
    public func setup(_ config: PostHogConfig) {}
    public func capture(_ event: String, properties: [String: Any]? = nil) {}
}
STUB
swiftc -emit-module -module-name PostHog "${SWIFTFLAGS[@]:0:4}" \
  "$BUILD_DIR/stub/PostHog.swift" -emit-module-path "$BUILD_DIR/stub/PostHog.swiftmodule"
swiftc -c -parse-as-library -module-name PostHog "${SWIFTFLAGS[@]:0:4}" \
  "$BUILD_DIR/stub/PostHog.swift" -o "$BUILD_DIR/stub/PostHog.o"

APP_SOURCES=()
# Every Swift file under leanring-buddy/, subfolders included, as in
# Tests/AgentRuntimeIntegration/run.sh.
while IFS= read -r file; do
  [[ "$file" == *"leanring_buddyApp.swift" ]] && continue
  APP_SOURCES+=("$file")
done < <(find leanring-buddy -name '*.swift' | sort)

swiftc "${SWIFTFLAGS[@]}" \
  -I "$BUILD_DIR/stub" \
  -o "$BUILD_DIR/attack" \
  Tests/HostileProviderAttack/main.swift \
  "${APP_SOURCES[@]}" \
  "$BUILD_DIR/stub/PostHog.o" || { echo "COMPILE FAILED"; exit 1; }

"$BUILD_DIR/attack"
