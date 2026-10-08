#!/bin/bash
#
# Runs the reminder command suite: recognising spoken reminder requests
# ("remind me to … at …", "add … to my … list"), reading the time with the
# calendar fast path's resolver, and checking the on-device model's extraction.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The parsers are
# pure, so this compiles just those two files.
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
  -o "$BUILD_DIR/reminder-command" \
  Tests/ReminderCommand/main.swift \
  leanring-buddy/CalendarEventCommand.swift \
  leanring-buddy/ReminderCommand.swift

"$BUILD_DIR/reminder-command"
