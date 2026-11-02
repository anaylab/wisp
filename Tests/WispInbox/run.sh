#!/bin/bash
#
# Runs the inbox suite: how approvals, failures, system problems and results are ordered and
# capped. No model, no app.
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
  -o "$BUILD_DIR/wisp-inbox" \
  Tests/WispInbox/main.swift \
  leanring-buddy/Inbox/WispInbox.swift

"$BUILD_DIR/wisp-inbox"
