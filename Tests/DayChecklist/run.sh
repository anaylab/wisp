#!/bin/bash
#
# Runs the daily checklist suite: DayChecklistBuilder (rollover, dedupe, ordering,
# completion merge, overdue) and the pure EventKit write planning.
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
  -o "$BUILD_DIR/day-checklist" \
  Tests/DayChecklist/main.swift \
  leanring-buddy/Jobs/CanvasModels.swift \
  leanring-buddy/Jobs/ChecklistModels.swift \
  leanring-buddy/Jobs/DayChecklistBuilder.swift

"$BUILD_DIR/day-checklist"
