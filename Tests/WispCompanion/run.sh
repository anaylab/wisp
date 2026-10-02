#!/bin/bash
#
# Runs the Wisp companion suite: mood precedence, pokes and dizziness, gaze
# and blinking — the pure side of the notch's companion.
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
  -o "$BUILD_DIR/wisp-companion" \
  Tests/WispCompanion/main.swift \
  leanring-buddy/Components/WispCompanionMood.swift

"$BUILD_DIR/wisp-companion"
