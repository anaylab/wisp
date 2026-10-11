#!/bin/bash
#
# Runs the personal context suite: which requests are about the user's own
# things, the search terms and named sources read from them, ranking, the
# model's block, and the Messages body decoder.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The query side is
# pure, so this compiles just those files.
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
  -o "$BUILD_DIR/personal-context" \
  Tests/PersonalContext/main.swift \
  leanring-buddy/PersonalContext/PersonalContextQuery.swift \
  leanring-buddy/PersonalContext/MessagesHistoryDecoding.swift

"$BUILD_DIR/personal-context"
