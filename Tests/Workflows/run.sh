#!/bin/bash
#
# Runs the workflow suite: which connections are allowed, loops, the editing rules, undo history,
# the camera (zoom around a point, fit), the dot grid, and the store's file.
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
  -o "$BUILD_DIR/workflows" \
  Tests/Workflows/main.swift \
  leanring-buddy/Workflows/Workflow.swift \
  leanring-buddy/Workflows/WorkflowEditing.swift \
  leanring-buddy/Workflows/WorkflowRun.swift

"$BUILD_DIR/workflows"
