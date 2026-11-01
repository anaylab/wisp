#!/bin/bash
#
# Runs the Study mode suite: plan clamping, the session state machine (rounds,
# long break, pause, skip, sleep), blocklist matching and the stats. Pure, plain swiftc.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/study-mode" \
  Tests/StudyMode/main.swift \
  leanring-buddy/Study/StudyModel.swift \
  leanring-buddy/Study/StudyBlocklist.swift \
  leanring-buddy/Study/StudyStats.swift \
  leanring-buddy/Study/StudyBuddy.swift

"$BUILD_DIR/study-mode"
