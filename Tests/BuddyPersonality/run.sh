#!/bin/bash
#
# Runs the buddy personality suite: the five work styles (persona line, reply
# style, voice clamp, reaction, mood words), how a personality reaches the system
# prompt, the checklist streak rule and store, and the day's-buddy greeting rules.
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
  -o "$BUILD_DIR/buddy-personality" \
  Tests/BuddyPersonality/main.swift \
  leanring-buddy/Buddies/BuddyPersonality.swift \
  leanring-buddy/Buddies/BuddyMood.swift \
  leanring-buddy/Buddies/BuddyGreeting.swift \
  leanring-buddy/Buddies/ChecklistStreak.swift \
  leanring-buddy/Buddies/BuddyThread.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift

"$BUILD_DIR/buddy-personality"
