#!/bin/bash
#
# Runs the calendar-event command suite: recognising spoken scheduling
# requests, resolving the time phrase deterministically, and splitting title
# from place — plus the checks on Apple's on-device model's extraction.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The parser is
# pure, so this compiles just that one file.
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
  -o "$BUILD_DIR/calendar-event-command" \
  Tests/CalendarEventCommand/main.swift \
  leanring-buddy/CalendarEventCommand.swift \
  leanring-buddy/SchedulingPhrasing.swift \
  leanring-buddy/ClockQuestion.swift

"$BUILD_DIR/calendar-event-command"
