#!/bin/bash
#
# Runs the automation draft suite: spoken phrases -> drafts, ambiguous -> asks, templates,
# validation, the optional model-assist reply. No model, no app.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md).
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$BUILD_DIR/automation-draft" \
  Tests/AutomationDraft/main.swift \
  Tests/AutomationDraft/StarterBuddyKindShim.swift \
  leanring-buddy/Automations/Automation.swift \
  leanring-buddy/Automations/AutomationSchedule.swift \
  leanring-buddy/Automations/AutomationDraft.swift \
  leanring-buddy/Automations/AutomationDraftParser.swift \
  leanring-buddy/Automations/AutomationTemplates.swift \
  leanring-buddy/ChromeExtension/ChromeFocusCommand.swift

"$BUILD_DIR/automation-draft"
