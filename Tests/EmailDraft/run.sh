#!/bin/bash
#
# Runs the email-draft suite: recognising "draft an email to sam about …",
# reading the model's draft back into fields, and the address checks the
# composer makes before Send.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). The parser and
# formatting rules are pure, so this compiles just that one file.
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
  -o "$BUILD_DIR/email-draft" \
  Tests/EmailDraft/main.swift \
  leanring-buddy/Email/EmailDraft.swift

"$BUILD_DIR/email-draft"
