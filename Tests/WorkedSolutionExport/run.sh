#!/bin/bash
#
# Runs the "save a worked solution" suite: what is worth saving, which display
# to save, file names and the Markdown text. Pure, plain swiftc.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/worked-solution-export" \
  Tests/WorkedSolutionExport/main.swift \
  leanring-buddy/WorkedSolutionExport.swift \
  leanring-buddy/ScreenAnnotation.swift \
  leanring-buddy/AccessibilityElementSnapshot.swift

"$BUILD_DIR/worked-solution-export"
