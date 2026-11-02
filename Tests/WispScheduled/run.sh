#!/bin/bash
#
# Runs the scheduled suite: how automations, buddy schedules and workflow schedules merge into one
# soonest-first list and group by day. No model, no app.
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
  -o "$BUILD_DIR/wisp-scheduled" \
  Tests/WispScheduled/main.swift \
  leanring-buddy/Scheduling/WispScheduled.swift

"$BUILD_DIR/wisp-scheduled"
