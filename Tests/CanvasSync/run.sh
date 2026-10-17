#!/bin/bash
#
# Runs the Canvas sync suite: ICS parser, snapshot diff, study-block planner,
# feed URL validator, and snapshot file handling.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The Keychain store
# and feed store are compiled in so they are type-checked, but the suite never
# touches the Keychain or the network.
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
  -o "$BUILD_DIR/canvas-sync" \
  Tests/CanvasSync/main.swift \
  leanring-buddy/Jobs/CanvasModels.swift \
  leanring-buddy/Jobs/CanvasFeedParser.swift \
  leanring-buddy/Jobs/CanvasSyncPlanner.swift \
  leanring-buddy/Jobs/StudyBlockPlanner.swift \
  leanring-buddy/Jobs/CanvasFeedKeychainStore.swift \
  leanring-buddy/Jobs/CanvasFeedStore.swift

"$BUILD_DIR/canvas-sync"
