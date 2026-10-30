#!/bin/bash
#
# Runs the browser reply grounding suite: the browser load-readiness rule and
# the explicit "completed, now on <page>" line the task result gives the model.
# Pure, plain swiftc.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/browser-reply-grounding" \
  Tests/BrowserReplyGrounding/main.swift \
  leanring-buddy/BrowserController.swift \
  leanring-buddy/BrowserTask.swift \
  leanring-buddy/BrowserSiteRegistry.swift \
  leanring-buddy/BrowserPlanCache.swift

"$BUILD_DIR/browser-reply-grounding"
