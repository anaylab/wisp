#!/bin/bash
#
# Runs the fast-pointing suite: request recognition, target matching and the
# lenient reading of the text-only model reply.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The matcher is
# pure, so this compiles just that one file.
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
  -o "$BUILD_DIR/fast-pointing" \
  Tests/FastPointing/main.swift \
  leanring-buddy/FastPointing.swift

"$BUILD_DIR/fast-pointing"
