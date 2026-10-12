#!/bin/bash
#
# Runs the guided-walkthrough suite: plan stepping, instruction → label,
# and click-on-target matching.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). All of it is pure.
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
  -o "$BUILD_DIR/guided-walkthrough" \
  Tests/GuidedWalkthrough/main.swift \
  leanring-buddy/GuidedWalkthrough.swift \
  leanring-buddy/FastPointing.swift \
  leanring-buddy/ScreenAnnotation.swift \
  leanring-buddy/AccessibilityElementSnapshot.swift

"$BUILD_DIR/guided-walkthrough"
