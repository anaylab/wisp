#!/bin/bash
#
# Runs the automation migration suite: routines, buddy jobs and Jobs -> automations, the round
# trip (plan, encode, decode, plan again = nothing), and a missing or corrupt old file.
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
  -o "$BUILD_DIR/automation-migration" \
  Tests/AutomationMigration/main.swift \
  leanring-buddy/Automations/Automation.swift \
  leanring-buddy/Automations/AutomationSchedule.swift \
  leanring-buddy/Automations/AutomationMigration.swift

"$BUILD_DIR/automation-migration"
