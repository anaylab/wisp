#!/bin/bash
#
# Runs the screen-watcher suite: spoken request recognition ("tell me when the
# build finishes", "stop watching"), whole-word OCR text matching, and the
# evaluator that decides from successive readings when a watch is satisfied.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The watcher's core
# is pure, so this compiles just that one file.
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
  -o "$BUILD_DIR/screen-watcher" \
  Tests/ScreenWatcher/main.swift \
  leanring-buddy/ScreenWatcher.swift

"$BUILD_DIR/screen-watcher"
