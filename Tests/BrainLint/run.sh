#!/bin/bash
#
# Runs the brain-lint suite: the pure health checks (broken links, orphans,
# likely duplicates and their false positives, oversized pages, missing
# summaries), stub-kind inference, the deterministic merge and split, and the
# summary text cleanup.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Everything under
# test is pure, so this compiles only the page model, the edit planner and the
# three lint files — not the store or the model stack.
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
  -o "$BUILD_DIR/brain-lint" \
  Tests/BrainLint/main.swift \
  leanring-buddy/Brain/BrainPage.swift \
  leanring-buddy/Brain/BrainEdit.swift \
  leanring-buddy/Brain/BrainLintChecks.swift \
  leanring-buddy/Brain/BrainPageMerger.swift \
  leanring-buddy/Brain/BrainPageSplitter.swift

"$BUILD_DIR/brain-lint"
