#!/bin/bash
#
# Runs the in-page pointing suite (Chrome extension phase 05): when a mark goes
# into the page instead of onto the overlay, which page element a pointing
# target or walkthrough step means, and which extension events move a
# walkthrough on.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The policy is pure;
# it reuses fast pointing's word scoring and the walkthrough's instruction
# reading, so those files come along.
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
  -o "$BUILD_DIR/chrome-ext-in-page-pointing" \
  Tests/ChromeExtInPagePointing/main.swift \
  leanring-buddy/ChromeExtension/ChromeInPagePointingPolicy.swift \
  leanring-buddy/ChromeExtension/BrowserControllerSelector.swift \
  leanring-buddy/ChromeExtension/ChromiumBrowsers.swift \
  leanring-buddy/GuidedWalkthrough.swift \
  leanring-buddy/FastPointing.swift \
  leanring-buddy/ScreenAnnotation.swift \
  leanring-buddy/AccessibilityElementSnapshot.swift

"$BUILD_DIR/chrome-ext-in-page-pointing"
