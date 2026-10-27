#!/bin/bash
#
# Runs the learned-shortcuts suite: which finished turns can be saved (replayability), the
# phrase template and matcher (exact-or-nothing, ambiguity), slot filling, the drift policy and
# the store file (0600, only declared keys).
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Everything under test is pure apart
# from the store, which is pointed at a temp file.
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
  -o "$BUILD_DIR/learned-shortcuts" \
  Tests/LearnedShortcuts/main.swift \
  leanring-buddy/LearnedShortcuts/ShortcutRecordedToolCall.swift \
  leanring-buddy/LearnedShortcuts/LearnedShortcut.swift \
  leanring-buddy/LearnedShortcuts/LearnedShortcutPhrase.swift \
  leanring-buddy/LearnedShortcuts/LearnedShortcutMatcher.swift \
  leanring-buddy/LearnedShortcuts/ShortcutReplayability.swift \
  leanring-buddy/LearnedShortcuts/LearnedShortcutOffer.swift \
  leanring-buddy/LearnedShortcuts/LearnedShortcutRunner.swift \
  leanring-buddy/LearnedShortcuts/LearnedShortcutDisplay.swift \
  leanring-buddy/LearnedShortcuts/LearnedShortcutPromotion.swift \
  leanring-buddy/Automations/Automation.swift \
  Tests/AutomationDraft/StarterBuddyKindShim.swift \
  leanring-buddy/Automations/AutomationSchedule.swift \
  leanring-buddy/Automations/AutomationDraft.swift \
  leanring-buddy/Automations/AutomationTemplates.swift \
  leanring-buddy/Automations/AutomationRunRecord.swift \
  leanring-buddy/Automations/AutomationStore.swift \
  leanring-buddy/Automations/AutomationEngine.swift \
  leanring-buddy/SystemReadinessMonitor.swift \
  leanring-buddy/LearnedShortcuts/LearnedShortcutStore.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift

"$BUILD_DIR/learned-shortcuts"
