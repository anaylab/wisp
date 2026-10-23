#!/bin/bash
#
# Runs the form helper suite (phase 12): the refusal list (adversarial labels
# included), autocomplete and label mapping, the profile read from the Me card
# and the brain's facts, the leftover-label model prompt and its reply parsing,
# the prepared input, the card, edited values winning, and the phrases.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The planner and the
# card are pure; this compiles them with the confirmation-card code they plug
# into, using the editable-confirmation suite's stubs for its app constants.
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
  -o "$BUILD_DIR/chrome-ext-form-helper" \
  Tests/ChromeExtFormHelper/main.swift \
  Tests/EditableConfirmation/AppStubs.swift \
  leanring-buddy/ChromeExtension/FormFillPlanner.swift \
  leanring-buddy/ChromeExtension/FormFillCards.swift \
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
  leanring-buddy/ChromeExtension/ChromeTabLifeCardText.swift

"$BUILD_DIR/chrome-ext-form-helper"
