#!/bin/bash
#
# Runs the buddy flow suite: links, loops, which buddy runs when, fan-in, skips,
# blocked links and the hand-off message.
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
  -o "$BUILD_DIR/buddy-flow" \
  Tests/BuddyFlow/main.swift \
  leanring-buddy/Buddies/BuddyFlow.swift

"$BUILD_DIR/buddy-flow"
