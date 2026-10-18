#!/bin/bash
#
# Runs the radial quick menu suite: wedge positions and which wedge a pointer
# direction chooses. Pure, plain swiftc.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/radial-menu" \
  Tests/RadialMenu/main.swift \
  leanring-buddy/RadialMenu/RadialMenuGeometry.swift

"$BUILD_DIR/radial-menu"
