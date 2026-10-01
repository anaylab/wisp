#!/bin/bash
#
# Runs the brain digest suite: which finished conversation sessions are
# digested, which exchanges count, the "worth a model call" gate, the
# transcript/material text, and notes-import planning (folder walk filters,
# content-hash dedupe, raw paths, Apple Notes change detection).
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Compiles only the
# pure planning files plus the history record types they read.
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
  -o "$BUILD_DIR/brain-digest" \
  Tests/BrainDigest/main.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift \
  leanring-buddy/DynamicIsland/NotchConversationSessions.swift \
  leanring-buddy/Brain/BrainConversationDigestPlanning.swift \
  leanring-buddy/Brain/BrainNotesImportPlanning.swift

"$BUILD_DIR/brain-digest"
