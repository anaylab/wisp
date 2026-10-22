#!/bin/bash
#
# Runs the Chrome extension tab-life suite (phase 04): session building, the
# sessions file codec and cap, "restore thesis research" name matching, restore
# requests, stale-tab rules, triage ordering, the confirmation cards' text and
# the spoken-command router (positive and negative phrases).
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The planners these
# build on live in ChromeTabOrganizer.swift, which is compiled with small stubs
# for the app types it names (AppStubs.swift).
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
  -o "$BUILD_DIR/chrome-ext-tab-life" \
  Tests/ChromeExtTabLife/main.swift \
  Tests/ChromeExtTabLife/AppStubs.swift \
  leanring-buddy/ChromeTabOrganizer.swift \
  leanring-buddy/ChromeExtension/ChromeTabSession.swift \
  leanring-buddy/ChromeExtension/ChromeStaleTabFinder.swift \
  leanring-buddy/ChromeExtension/ChromeTabTriagePlanner.swift \
  leanring-buddy/ChromeExtension/ChromeTabLifeCommand.swift \
  leanring-buddy/ChromeExtension/ChromeTabLifeCardText.swift

"$BUILD_DIR/chrome-ext-tab-life"
