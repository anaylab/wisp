#!/bin/bash
#
# Runs the editable-confirmation suite: which fields of a pending tool call the
# card offers for editing, how edits are applied (and refused), the note given
# back to the model, and the card rows the fields replace.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The rules are pure;
# this compiles them with the card builder, argument inspection and the safety
# floor they follow, plus `AppStubs.swift` for three tool-name constants.
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
  -o "$BUILD_DIR/editable-confirmation" \
  Tests/EditableConfirmation/main.swift \
  Tests/EditableConfirmation/AppStubs.swift \
  leanring-buddy/EditableConfirmationFields.swift \
  leanring-buddy/ToolConfirmationCardBuilder.swift \
  leanring-buddy/ToolCallInspection.swift \
  leanring-buddy/ToolCallSafety.swift \
  leanring-buddy/CuaDriverSupport.swift \
  leanring-buddy/WindowManagement/WindowLayoutCommand.swift \
  leanring-buddy/MCPToolResultRendering.swift \
  leanring-buddy/GlanceCard.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift \
  leanring-buddy/ChromeExtension/ChromeTabLifeCards.swift \
  leanring-buddy/ChromeExtension/ChromeTabLifeCardText.swift \
  leanring-buddy/ChromeExtension/FormFillCards.swift \
  leanring-buddy/ChromeExtension/FormFillPlanner.swift

"$BUILD_DIR/editable-confirmation"
