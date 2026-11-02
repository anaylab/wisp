#!/bin/bash
#
# Runs the buddy run lanes suite: which conversations may run at once, why a message waits, per-lane queue, steering.
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
  -o "$BUILD_DIR/buddy-run-lanes" \
  Tests/BuddyRunLanes/main.swift \
  leanring-buddy/Buddies/BuddyMessageQueue.swift \
  leanring-buddy/Buddies/BuddyRunLanes.swift \
  leanring-buddy/AgentRunToolkit.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift

"$BUILD_DIR/buddy-run-lanes"
