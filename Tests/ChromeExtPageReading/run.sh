#!/bin/bash
#
# Runs the Chrome extension page-reading suite (phase 02): fencing and
# trimming page text for a model, the content-vs-look classifier that decides
# when page text may replace the screenshot, and resolving a `tab` argument
# to one open tab.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). These three files
# are pure, so this compiles just them.
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
  -o "$BUILD_DIR/chrome-ext-page-reading" \
  Tests/ChromeExtPageReading/main.swift \
  leanring-buddy/ChromeExtension/ChromePageTextPrompt.swift \
  leanring-buddy/ChromeExtension/ChromePageContentRequestClassifier.swift \
  leanring-buddy/ChromeExtension/ChromeTabReferenceResolver.swift

"$BUILD_DIR/chrome-ext-page-reading"
