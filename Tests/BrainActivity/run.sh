#!/bin/bash
#
# Runs the brain activity-feed suite: exclusions, URL cleaning, span merging,
# day files, work-item naming, the day summary, the digest text and schedule.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Compiles only the
# activity feed's pure files plus the sampler (for its reply parser).
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
  -o "$BUILD_DIR/brain-activity" \
  Tests/BrainActivity/main.swift \
  leanring-buddy/Brain/BrainActivityExclusions.swift \
  leanring-buddy/Brain/BrainActivityLog.swift \
  leanring-buddy/Brain/BrainActivitySummary.swift \
  leanring-buddy/Brain/BrainActivitySampler.swift

"$BUILD_DIR/brain-activity"
