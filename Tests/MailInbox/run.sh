#!/bin/bash
#
# Runs the Inbox suite: threading by subject, the rules that sort mail into
# Important or Everything else, reading the model's triage answer, when a
# reply is drafted ahead, and parsing the Mail script's output.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The rules are
# pure, so this compiles just that one file.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$BUILD_DIR/mail-inbox" \
  Tests/MailInbox/main.swift \
  leanring-buddy/MailInbox/MailInboxModel.swift

"$BUILD_DIR/mail-inbox"
