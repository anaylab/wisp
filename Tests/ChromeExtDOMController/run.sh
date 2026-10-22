#!/bin/bash
#
# Runs the Chrome extension DOM controller suite: which controller serves a
# browser task (extension vs AppleScript), decoding the snapshot JSON both
# controllers produce into the page text the planners and prompts read, and
# what the extension's action replies mean.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The files under
# test are pure; AppleScriptBrowserController's two budget constants are stubbed.
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
  -o "$BUILD_DIR/chrome-ext-dom-controller" \
  Tests/ChromeExtDOMController/main.swift \
  Tests/ChromeExtDOMController/AppleScriptBrowserControllerStub.swift \
  leanring-buddy/BrowserController.swift \
  leanring-buddy/BrowserPageSnapshotDecoding.swift \
  leanring-buddy/ChromeExtension/BrowserControllerSelector.swift \
  leanring-buddy/ChromeExtension/ExtensionBrowserReplies.swift

"$BUILD_DIR/chrome-ext-dom-controller" "Tests/ChromeExtDOMController/snapshot-fixture.json"
