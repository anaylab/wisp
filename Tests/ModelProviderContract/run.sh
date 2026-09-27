#!/bin/bash
#
# Runs the ModelProvider contract suite.
#
# Standalone by design: it compiles the handful of source files the provider
# layer actually depends on and runs them directly, so it needs no Xcode build
# and — importantly — never invokes xcodebuild, which would invalidate the
# app's TCC permissions (see CLAUDE.md).
#
set -euo pipefail
cd "$(dirname "$0")/../.."

SOURCES=(
  leanring-buddy/ModelProvider.swift
  leanring-buddy/OllamaProvider.swift
  leanring-buddy/LocalOllamaAPI.swift
  leanring-buddy/BuddyVisionChatClient.swift
  leanring-buddy/BuddyChatTypes.swift
  leanring-buddy/ToolMetadata.swift
  leanring-buddy/StructuredTextToolProtocol.swift
  leanring-buddy/SpokenSentenceStreamer.swift
  leanring-buddy/AppBundleConfiguration.swift
)

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Flags mirror the app target's own settings (SWIFT_VERSION,
# SWIFT_DEFAULT_ACTOR_ISOLATION, MemberImportVisibility) so the suite compiles
# the code the same way Xcode does. Without -default-isolation MainActor,
# bare swiftc reports actor-isolation errors the real build does not have.
swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$BUILD_DIR/contract" \
  Tests/ModelProviderContract/TestSupport.swift \
  Tests/ModelProviderContract/main.swift \
  "${SOURCES[@]}"

"$BUILD_DIR/contract"
