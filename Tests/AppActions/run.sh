#!/bin/bash
#
# Runs the app-actions suite: reading other apps' App Intents metadata,
# matching a request to an app and its actions, naming the shortcut to build,
# and recognising (with its input) a request to run that shortcut later.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The matching is
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
  -o "$BUILD_DIR/app-actions" \
  Tests/AppActions/main.swift \
  leanring-buddy/OtherAppActions/AppActionMatching.swift

"$BUILD_DIR/app-actions"
