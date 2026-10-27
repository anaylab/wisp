#!/bin/bash
#
# Runs the theme suite: WCAG contrast for every theme in light and dark (accent text,
# label on accent, AI accent, text on the tinted glass), structure (3 backdrop stops,
# 8 buddy colours, valid hex, unique ids) and the Sage-equals-today guarantee.
# Plain swiftc, no Xcode build.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/wisp-theme" \
  Tests/WispTheme/main.swift \
  leanring-buddy/DesignSystem/WispTheme.swift \
  leanring-buddy/DesignSystem/WispThemeContrast.swift

"$BUILD_DIR/wisp-theme"
