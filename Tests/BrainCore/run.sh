#!/bin/bash
#
# Runs the brain core suite: page format, slugs, links, sections, the edit
# planner's policies, the proposal parser, BM25 search and prompt context,
# plus the integration's pure pieces (about-me block, memory.md migration,
# agent-tool helpers, brain command router).
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). MemoryStore.swift
# comes along because the about-me block and the migration reuse its pure
# MemoryFileFormat, and it in turn reaches BrainStore/BrainPreferences.
# BrainAgentTools.swift's registration half extends AgentToolRegistry (which
# reaches most of the app), so only its pure half — everything above
# "MARK: - Registration" — is compiled, cut out with sed.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

sed '/MARK: - Registration/,$d' leanring-buddy/Brain/BrainAgentTools.swift > "$BUILD_DIR/BrainAgentToolsPure.swift"

swiftc -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$BUILD_DIR/brain-core" \
  Tests/BrainCore/main.swift \
  leanring-buddy/Brain/BrainPage.swift \
  leanring-buddy/Brain/BrainEdit.swift \
  leanring-buddy/Brain/BrainSearch.swift \
  leanring-buddy/Brain/BrainSchema.swift \
  leanring-buddy/Brain/BrainStore.swift \
  leanring-buddy/Brain/BrainPreferences.swift \
  leanring-buddy/Brain/BrainAboutMe.swift \
  leanring-buddy/Brain/BrainMemoryMigration.swift \
  leanring-buddy/Brain/BrainCommandRouter.swift \
  leanring-buddy/FrontmostAppTracker.swift \
  leanring-buddy/MemoryStore.swift \
  "$BUILD_DIR/BrainAgentToolsPure.swift"

"$BUILD_DIR/brain-core"
