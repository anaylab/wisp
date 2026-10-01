#!/bin/bash
#
# Runs the buddy thread suite: the prompt-history projection, the stored-thread
# cap, and the store's begin/complete/persist/delete round trip.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md).
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$BUILD_DIR/buddy-thread" \
  Tests/BuddyThread/main.swift \
  leanring-buddy/Buddies/BuddyThread.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift

"$BUILD_DIR/buddy-thread"
