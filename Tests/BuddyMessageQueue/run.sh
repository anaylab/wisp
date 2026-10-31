#!/bin/bash
#
# Runs the buddy message queue suite: FIFO order, cap, pause, cancel, codec.
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
  -o "$BUILD_DIR/buddy-message-queue" \
  Tests/BuddyMessageQueue/main.swift \
  leanring-buddy/Buddies/BuddyMessageQueue.swift

"$BUILD_DIR/buddy-message-queue"
