#!/bin/bash
#
# Runs the buddy memory review suite: when a review starts, the prompt, reading
# the model's reply, and the checks that keep the user's notes untouched.
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
  -o "$BUILD_DIR/buddy-memory-review" \
  Tests/BuddyMemoryReview/main.swift \
  leanring-buddy/Buddies/BuddyMemoryReview.swift

"$BUILD_DIR/buddy-memory-review"
