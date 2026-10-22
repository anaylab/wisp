#!/bin/bash
#
# Runs the download concierge suite (Chrome extension phase 07): reading the
# download payload, rule matching, the rules file, suggested names and
# templates, collision-safe names, and the refusals (dangerous downloads,
# paths outside home, Library and hidden folders).
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The rules are
# pure, so this compiles just that file.
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
  -o "$BUILD_DIR/chrome-ext-downloads" \
  Tests/ChromeExtDownloads/main.swift \
  leanring-buddy/ChromeExtension/DownloadFilingRules.swift

"$BUILD_DIR/chrome-ext-downloads"
