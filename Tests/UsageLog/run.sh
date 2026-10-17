#!/bin/bash
#
# Runs the usage-log suite: price table, cost estimator, aggregation windows,
# retention, codec, the persisted shape (no content fields) and the store's
# file handling. Plain swiftc, no Xcode build.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -swift-version 5 \
  -default-isolation MainActor \
  -o "$BUILD_DIR/usage-log" \
  Tests/UsageLog/main.swift \
  leanring-buddy/UsageTokenCounts.swift \
  leanring-buddy/ModelPricing.swift \
  leanring-buddy/UsageLogRecord.swift \
  leanring-buddy/UsageLogStore.swift \
  leanring-buddy/BuddyChatProviderKind.swift

"$BUILD_DIR/usage-log"
