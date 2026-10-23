#!/bin/bash
#
# Runs the Chrome extension site-helpers suite (phase 10): Canvas assignment
# pages (trusted hosts, matching against the feed / today's checklist / study
# blocks, the "Add to today?" chip rule, the added-to-today checklist row, reply
# and prompt text), meeting captions (call addresses, "what did I miss" phrases,
# newest-first trimming and the data fence) and the phrase router with its tab
# state.
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
  -o "$BUILD_DIR/chrome-ext-site-helpers" \
  Tests/ChromeExtSiteHelpers/main.swift \
  leanring-buddy/Jobs/CanvasModels.swift \
  leanring-buddy/Jobs/ChecklistModels.swift \
  leanring-buddy/Jobs/DayChecklistBuilder.swift \
  leanring-buddy/ChromeExtension/ChromePageTextPrompt.swift \
  leanring-buddy/ChromeExtension/CanvasPageMatching.swift \
  leanring-buddy/ChromeExtension/MeetingCaptionsPrompt.swift \
  leanring-buddy/ChromeExtension/ChromeSiteHelperRouting.swift

"$BUILD_DIR/chrome-ext-site-helpers"
