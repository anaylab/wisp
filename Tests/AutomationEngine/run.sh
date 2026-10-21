#!/bin/bash
#
# Runs the automation engine suite with fake dependencies: the unattended toolkit rule, busy skips,
# a test run that writes nothing, JobsEngine-driven automations never double scheduled, declined
# approvals, events, the cloud-data rule, the stores' files and retention.
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
  -o "$BUILD_DIR/automation-engine" \
  Tests/AutomationEngine/main.swift \
  Tests/AutomationDraft/StarterBuddyKindShim.swift \
  leanring-buddy/Automations/Automation.swift \
  leanring-buddy/Automations/AutomationSchedule.swift \
  leanring-buddy/Automations/AutomationDraft.swift \
  leanring-buddy/Automations/AutomationTemplates.swift \
  leanring-buddy/Automations/AutomationRunRecord.swift \
  leanring-buddy/Automations/AutomationStore.swift \
  leanring-buddy/Automations/AutomationEngine.swift \
  leanring-buddy/SystemReadinessMonitor.swift

"$BUILD_DIR/automation-engine"
