#!/bin/bash
#
# Runs the note cards suite: building a card from a reply's notes, placement beside the
# explained area, tether end points, and which cards survive which event. Pure, plain swiftc.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/note-cards" \
  Tests/NoteCards/main.swift \
  leanring-buddy/NoteCards/NoteCard.swift \
  leanring-buddy/NoteCards/NoteCardFollowUp.swift \
  leanring-buddy/DynamicIsland/NotchConversationSessions.swift \
  leanring-buddy/BuddyChatTypes.swift \
  leanring-buddy/ToolMetadata.swift \
  leanring-buddy/ScreenAnnotation.swift \
  leanring-buddy/AccessibilityElementSnapshot.swift

"$BUILD_DIR/note-cards"
