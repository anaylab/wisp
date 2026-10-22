#!/bin/bash
#
# Runs the Chrome extension foundation suite: reading the extension's
# WebSocket frames (hello, ping, capabilities, events, replies), decoding
# event payloads, capability names and the request-timeout cap.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The frame parser
# and its types are pure, so this compiles just those files.
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
  -o "$BUILD_DIR/chrome-ext-foundation" \
  Tests/ChromeExtFoundation/main.swift \
  leanring-buddy/ChromeExtension/ChromeExtensionCapability.swift \
  leanring-buddy/ChromeExtension/ChromeExtensionEvent.swift \
  leanring-buddy/ChromeExtension/ChromeExtensionIncomingMessage.swift

"$BUILD_DIR/chrome-ext-foundation"
