#!/bin/bash
#
# Runs the "ask about a part" suite: the selected region, its conversion into
# the screenshot's pixel space, and the prompt text. Pure, plain swiftc.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/screen-region-focus" \
  Tests/ScreenRegionFocus/main.swift \
  leanring-buddy/ScreenRegionFocus.swift

"$BUILD_DIR/screen-region-focus"
