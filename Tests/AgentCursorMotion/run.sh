#!/bin/bash
#
# Runs the agent cursor motion suite: planned glides and swoops, timing,
# playback by elapsed time. Pure, plain swiftc.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/agent-cursor-motion" \
  Tests/AgentCursorMotion/main.swift \
  leanring-buddy/AgentCursorMotion.swift

"$BUILD_DIR/agent-cursor-motion"
