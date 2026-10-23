#!/bin/bash
#
# Runs the other-Chromium-browsers suite: naming a connected browser, the
# per-profile key one connection is kept under, which connected browser Wisp
# talks to (frontmost, held, sticky, Chrome), the extension-vs-AppleScript and
# in-page-pointing choices when the browser in front isn't the connected one,
# reading `hello.instanceId`, and — live, on this Mac — finding the app that
# owns a loopback socket.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md).
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
  -o "$BUILD_DIR/chrome-ext-browsers" \
  Tests/ChromeExtBrowsers/main.swift \
  leanring-buddy/ChromeExtension/ChromiumBrowsers.swift \
  leanring-buddy/ChromeExtension/ChromeExtensionPeerProcess.swift \
  leanring-buddy/ChromeExtension/BrowserControllerSelector.swift \
  leanring-buddy/ChromeExtension/ChromeInPagePointingPolicy.swift \
  leanring-buddy/ChromeExtension/ChromeExtensionIncomingMessage.swift \
  leanring-buddy/ChromeExtension/ChromeExtensionEvent.swift \
  leanring-buddy/ChromeExtension/ChromeExtensionCapability.swift \
  leanring-buddy/GuidedWalkthrough.swift \
  leanring-buddy/FastPointing.swift \
  leanring-buddy/ScreenAnnotation.swift \
  leanring-buddy/AccessibilityElementSnapshot.swift

"$BUILD_DIR/chrome-ext-browsers"
