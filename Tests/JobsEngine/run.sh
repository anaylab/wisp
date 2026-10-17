#!/bin/bash
#
# Runs the JobsEngine suite: the Canvas sync / checklist / study-block flow driven
# with in-memory fakes for the feed, EventKit writers, approval card and
# announcements. No Keychain, network, EventKit or app launch.
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
  -o "$BUILD_DIR/jobs-engine" \
  Tests/JobsEngine/main.swift \
  leanring-buddy/Jobs/JobsEngine.swift \
  leanring-buddy/Jobs/CanvasModels.swift \
  leanring-buddy/Jobs/CanvasFeedParser.swift \
  leanring-buddy/Jobs/CanvasSyncPlanner.swift \
  leanring-buddy/Jobs/StudyBlockPlanner.swift \
  leanring-buddy/Jobs/CanvasFeedKeychainStore.swift \
  leanring-buddy/Jobs/CanvasFeedStore.swift \
  leanring-buddy/Jobs/ChecklistModels.swift \
  leanring-buddy/Jobs/DayChecklistBuilder.swift

"$BUILD_DIR/jobs-engine"
