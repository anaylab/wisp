#!/bin/bash
#
# Runs the automation schedule suite: next run per recurrence, DST gaps and repeats
# (America/New_York, Europe/London), month-end clamp, missed runs run once, schedule inference.
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
  -o "$BUILD_DIR/automation-schedule" \
  Tests/AutomationSchedule/main.swift \
  leanring-buddy/Automations/AutomationSchedule.swift

"$BUILD_DIR/automation-schedule"
