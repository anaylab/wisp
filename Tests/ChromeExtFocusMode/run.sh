#!/bin/bash
#
# Runs the Chrome focus mode suite (phase 09): the planner's keep / collapse /
# mute / move decisions, the study-block auto-start rule, and which spoken
# phrases start or stop focus (and, as importantly, which don't).
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The planner and the
# phrase parser are pure; `ChromeTabsShim.swift` stands in for the tab types in
# ChromeTabOrganizer.swift, which can't compile without the app.
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
  -o "$BUILD_DIR/chrome-ext-focus-mode" \
  Tests/ChromeExtFocusMode/main.swift \
  Tests/ChromeExtFocusMode/ChromeTabsShim.swift \
  leanring-buddy/ChromeExtension/ChromeFocusPlanner.swift \
  leanring-buddy/ChromeExtension/ChromeFocusCommand.swift

"$BUILD_DIR/chrome-ext-focus-mode"
