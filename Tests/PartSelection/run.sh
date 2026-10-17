#!/bin/bash
#
# Runs the voice part-selection suite: the spoken-target parser, the OCR list
# resolver and the screenshot-pixels -> FocusedScreenRegion conversion.
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
  -o "$BUILD_DIR/part-selection" \
  Tests/PartSelection/main.swift \
  leanring-buddy/PartSelectionRequest.swift \
  leanring-buddy/PartSelectionResolver.swift \
  leanring-buddy/ScreenRegionFocus.swift \
  leanring-buddy/AnnotationClickTarget.swift \
  leanring-buddy/ScreenAnnotation.swift \
  leanring-buddy/AccessibilityElementSnapshot.swift \
  leanring-buddy/ScreenTextSnapshot.swift \
  leanring-buddy/FastPointing.swift

"$BUILD_DIR/part-selection"
