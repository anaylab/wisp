#!/bin/bash
#
# Runs the buddy runtime suite: which conversation a run belongs to, what a
# kept session is sent, missing-session detection, and the session store file.
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
  -o "$BUILD_DIR/buddy-runtime" \
  Tests/BuddyRuntime/main.swift \
  leanring-buddy/Buddies/BuddyRuntime.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift

"$BUILD_DIR/buddy-runtime" "$BUILD_DIR"
