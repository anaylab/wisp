#!/bin/bash
#
# Runs the Brain morning-suggestions suite: which notes are shown to the model, how its JSON is
# parsed, and the quote check that drops any follow-up whose evidence is not really in the notes.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Compiles the real BrainPage.swift
# with small stand-ins for the app types the suggestions file mentions.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$BUILD_DIR/brain-morning-suggestions" \
  Tests/BrainMorningSuggestions/main.swift \
  Tests/BrainMorningSuggestions/Stubs.swift \
  leanring-buddy/Brain/BrainPage.swift \
  leanring-buddy/DynamicIsland/BrainMorningSuggestions.swift

"$BUILD_DIR/brain-morning-suggestions"
