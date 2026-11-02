#!/bin/bash
#
# Runs the demo mode suite: the sample day (checklist, calendar, buddy answers)
# and that demo mode is off unless Wisp was launched with -WispDemoMode YES.
# Pure, plain swiftc.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/demo-mode" \
  Tests/DemoMode/main.swift \
  leanring-buddy/DemoMode/WispDemoMode.swift \
  leanring-buddy/DemoMode/WispDemoSampleData.swift \
  leanring-buddy/Jobs/ChecklistModels.swift \
  leanring-buddy/CalendarSnapshot.swift

"$BUILD_DIR/demo-mode"
