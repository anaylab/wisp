#!/bin/bash
#
# Integration tests for the migrated agent loop.
#
# Links the real application sources — everything except the @main entry point,
# which would clash with the suite's own main.swift. The third-party imports
# (PostHog, FluidAudio) are stubbed, so this needs no SwiftPM checkout and,
# critically, never invokes xcodebuild (which would invalidate the app's TCC
# permissions — see CLAUDE.md).
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

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
# Built as a real object as well as a module, so the final link resolves.
swiftc -emit-module -module-name PostHog -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  "$BUILD_DIR/stub/PostHog.swift" \
  -emit-module-path "$BUILD_DIR/stub/PostHog.swiftmodule"
swiftc -c -parse-as-library -module-name PostHog -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  "$BUILD_DIR/stub/PostHog.swift" -o "$BUILD_DIR/stub/PostHog.o"

# FluidAudio (Parakeet + Kokoro) is a SwiftPM package in the app; here it's
# replaced by a stub declaring just the API Wisp uses, built the same way.
swiftc -emit-module -module-name FluidAudio -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  Tests/AgentRuntimeIntegration/FluidAudioStub.swift \
  -emit-module-path "$BUILD_DIR/stub/FluidAudio.swiftmodule"
swiftc -c -parse-as-library -module-name FluidAudio -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  Tests/AgentRuntimeIntegration/FluidAudioStub.swift -o "$BUILD_DIR/stub/FluidAudio.o"

# Every Swift file under leanring-buddy/, subfolders included (DesignSystem/,
# Components/, DynamicIsland/, WispWindow/, …). The agent runtime reaches
# CompanionManager, which reaches most of the app, so a hand-picked list would
# be nearly the whole target anyway and would go stale on every new file.
APP_SOURCES=()
while IFS= read -r file; do
  [[ "$file" == *"leanring_buddyApp.swift" ]] && continue
  APP_SOURCES+=("$file")
done < <(find leanring-buddy -name '*.swift' | sort)

# Flags mirror the app target's own settings (SWIFT_VERSION,
# SWIFT_DEFAULT_ACTOR_ISOLATION, MemberImportVisibility) so the suite compiles
# the code the same way Xcode does. Without -default-isolation MainActor,
# bare swiftc reports actor-isolation errors the real build does not have.
swiftc -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -I "$BUILD_DIR/stub" \
  -o "$BUILD_DIR/integration" \
  Tests/AgentRuntimeIntegration/main.swift \
  Tests/AgentRuntimeIntegration/BuddyRedesignTests.swift \
  Tests/AgentRuntimeIntegration/AnthropicProviderTests.swift \
  Tests/AgentRuntimeIntegration/BuddyBotTests.swift \
  Tests/AgentRuntimeIntegration/ClaudeSubscriptionProviderTests.swift \
  Tests/AgentRuntimeIntegration/ComposioConnectionsTests.swift \
  "${APP_SOURCES[@]}" \
  "$BUILD_DIR/stub/PostHog.o" \
  "$BUILD_DIR/stub/FluidAudio.o"

"$BUILD_DIR/integration"
