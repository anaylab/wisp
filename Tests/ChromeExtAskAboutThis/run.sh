#!/bin/bash
#
# Runs the "Ask Wisp about this" suite (phase 06): decoding the extension's
# user.* events into requests, the image download rules, and which context
# each part (selection, image, link, page, address-bar question) builds for a
# turn — including when the screenshot still goes.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). These files are
# pure (Foundation only), so this compiles just them.
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
  -o "$BUILD_DIR/chrome-ext-ask-about-this" \
  Tests/ChromeExtAskAboutThis/main.swift \
  leanring-buddy/ChromeExtension/ChromeAskAboutThisRequest.swift \
  leanring-buddy/ChromeExtension/ChromeAskAboutThisContext.swift \
  leanring-buddy/ChromeExtension/ChromeAskImageDownload.swift \
  leanring-buddy/ChromeExtension/ChromePageTextPrompt.swift \
  leanring-buddy/ChromeExtension/ChromePageContentRequestClassifier.swift

"$BUILD_DIR/chrome-ext-ask-about-this"
