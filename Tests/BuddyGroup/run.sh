#!/bin/bash
#
# Runs the group chat suite: who answers a message (@Name, last owner, lead),
# handoff tags and the hop cap's inputs, the shared history one buddy sees, and
# the transcript cap and codec.
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
  -o "$BUILD_DIR/buddy-group" \
  Tests/BuddyGroup/main.swift \
  leanring-buddy/Buddies/BuddyGroup.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift

"$BUILD_DIR/buddy-group"
