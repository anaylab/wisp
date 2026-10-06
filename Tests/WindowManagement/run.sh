#!/bin/bash
#
# Runs the window-management suite: recognising spoken layout commands
# ("put Safari on the left and Xcode on the right"), resolving app names, and
# computing target frames across displays and the AppKit/Accessibility flip.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The parser and
# frame calculator are pure, so this compiles just that one file.
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
  -o "$BUILD_DIR/window-management" \
  Tests/WindowManagement/main.swift \
  leanring-buddy/WindowManagement/WindowLayoutCommand.swift

"$BUILD_DIR/window-management"
