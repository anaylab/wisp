#!/bin/bash
#
# Runs the quick-add suite: which spoken or typed lines become an automation draft card and which
# carry on to the model. No model, no app.
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
  -o "$BUILD_DIR/automation-quick-add" \
  Tests/AutomationQuickAdd/main.swift \
  Tests/AutomationDraft/StarterBuddyKindShim.swift \
  leanring-buddy/Automations/Automation.swift \
  leanring-buddy/Automations/AutomationSchedule.swift \
  leanring-buddy/Automations/AutomationDraft.swift \
  leanring-buddy/Automations/AutomationDraftParser.swift \
  leanring-buddy/Automations/AutomationTemplates.swift \
  leanring-buddy/QuickAdd/AutomationQuickAddPlanner.swift

"$BUILD_DIR/automation-quick-add"
