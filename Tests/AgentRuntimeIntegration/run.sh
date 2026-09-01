#!/bin/bash
#
# Integration tests for the migrated agent loop.
#
# Links the real application sources — everything except the @main entry point,
# which would clash with the suite's own main.swift. PostHog is the only
# third-party import and is stubbed, so this needs no SwiftPM checkout and,
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
swiftc -emit-module -module-name PostHog -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  "$BUILD_DIR/stub/PostHog.swift" \
  -emit-module-path "$BUILD_DIR/stub/PostHog.swiftmodule"
swiftc -c -parse-as-library -module-name PostHog -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  "$BUILD_DIR/stub/PostHog.swift" -o "$BUILD_DIR/stub/PostHog.o"

APP_SOURCES=()
for file in leanring-buddy/*.swift; do
  [[ "$file" == *"leanring_buddyApp.swift" ]] && continue
  APP_SOURCES+=("$file")
done

# Flags mirror the app target's own settings (SWIFT_VERSION,
# SWIFT_DEFAULT_ACTOR_ISOLATION, MemberImportVisibility) so the suite compiles
# the code the same way Xcode does. Without -default-isolation MainActor,
# bare swiftc reports actor-isolation errors the real build does not have.
swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -I "$BUILD_DIR/stub" \
  -o "$BUILD_DIR/integration" \
  Tests/AgentRuntimeIntegration/main.swift \
  "${APP_SOURCES[@]}" \
  "$BUILD_DIR/stub/PostHog.o"

"$BUILD_DIR/integration"
