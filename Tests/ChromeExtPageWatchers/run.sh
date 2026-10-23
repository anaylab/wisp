#!/bin/bash
#
# Runs the Chrome page watchers suite (phase 08): whether a spoken "tell me
# when …" watches the Chrome tab or the screen, the reload interval, the new
# number phrasing, the condition's wire shape, keeping Wisp's watch list in
# step with the extension's, the ending wording, site matching and the
# time-on-site accumulator behind "if I'm on reddit for 30 minutes".
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Everything here is
# pure; the store and the monitor need the app and are not compiled.
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
  -o "$BUILD_DIR/chrome-ext-page-watchers" \
  Tests/ChromeExtPageWatchers/main.swift \
  leanring-buddy/ScreenWatcher.swift \
  leanring-buddy/WatchedNumberParsing.swift \
  leanring-buddy/ChromeExtension/ChromePageWatch.swift \
  leanring-buddy/ChromeExtension/ChromeBrowsingActivity.swift

"$BUILD_DIR/chrome-ext-page-watchers"
