#!/bin/bash
#
# Runs the update rules suite: which copies of Wisp may update themselves, how the version reads, when
# a waiting update notifies. No Sparkle, no network.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md).
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$BUILD_DIR/app-updates" \
  Tests/AppUpdates/main.swift \
  leanring-buddy/Updates/WispUpdatePolicy.swift

"$BUILD_DIR/app-updates"
