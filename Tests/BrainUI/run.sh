#!/bin/bash
#
# Runs the Brain UI suite: the reader's markdown blocks and [[link]] rendering,
# backlink context lines, link resolution, and the graph's layout step.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The rendering and
# layout halves of the Brain UI are pure, so this compiles just those files and
# the page model they read.
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
  -o "$BUILD_DIR/brain-ui" \
  Tests/BrainUI/main.swift \
  leanring-buddy/Brain/BrainPage.swift \
  leanring-buddy/WispWindow/Brain/BrainMarkdownRendering.swift \
  leanring-buddy/WispWindow/Brain/BrainGraphLayout.swift

"$BUILD_DIR/brain-ui"
