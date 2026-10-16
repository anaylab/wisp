#!/bin/bash
#
# Runs the routine parameter suite: placeholder parsing, defaults, built-ins
# ({clipboard}, {date}, {time}) and how values are filled in.
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
  -o "$BUILD_DIR/routine-parameters" \
  Tests/RoutineParameters/main.swift \
  leanring-buddy/RoutineParameters.swift

"$BUILD_DIR/routine-parameters"
