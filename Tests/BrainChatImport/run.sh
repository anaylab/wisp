#!/bin/bash
#
# Runs the AI chat import suite: reading ChatGPT and Claude exports
# (conversations.json), the transcript written to raw/chats/, file names, and
# which chats an import brings (too short, unchanged, grown, capped).
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Compiles only the
# pure parsing file and the notes-import planner it borrows helpers from.
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
  -o "$BUILD_DIR/brain-chat-import" \
  Tests/BrainChatImport/main.swift \
  leanring-buddy/Brain/BrainNotesImportPlanning.swift \
  leanring-buddy/Brain/BrainChatExportParsing.swift

"$BUILD_DIR/brain-chat-import"
