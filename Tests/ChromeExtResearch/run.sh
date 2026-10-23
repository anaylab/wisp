#!/bin/bash
#
# Runs the Chrome extension research-mode suite (phase 11): quote checking
# (folding, exact substrings, word limits, fabricated quotes dropped), claim and
# source numbering, text-fragment addresses, source picking (redirects, skipped
# sites, dedupe by host + path), the request and "done" phrases, the map/reduce
# prompt budgets and reply parsing, a hostile page, and the Brain proposals.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Every file here is
# pure, so this compiles just them.
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
  -o "$BUILD_DIR/chrome-ext-research" \
  Tests/ChromeExtResearch/main.swift \
  leanring-buddy/Brain/BrainPage.swift \
  leanring-buddy/Brain/BrainEdit.swift \
  leanring-buddy/ChromeExtension/ChromePageTextPrompt.swift \
  leanring-buddy/ChromeExtension/ResearchCitationVerifier.swift \
  leanring-buddy/ChromeExtension/ResearchReport.swift \
  leanring-buddy/ChromeExtension/ResearchPlanning.swift \
  leanring-buddy/ChromeExtension/ResearchPrompts.swift \
  leanring-buddy/ChromeExtension/ResearchBrainPages.swift

"$BUILD_DIR/chrome-ext-research"
