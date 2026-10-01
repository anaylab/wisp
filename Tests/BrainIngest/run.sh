#!/bin/bash
#
# Runs the brain-ingest suite: chunking, HTML-to-text, proposal merging and
# batch fitting, the queue's persistence codec, and file-type/inbox decisions.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Compiles only the
# pure ingest files plus the page/edit model they build on.
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
  -o "$BUILD_DIR/brain-ingest" \
  Tests/BrainIngest/main.swift \
  leanring-buddy/Brain/BrainPage.swift \
  leanring-buddy/Brain/BrainEdit.swift \
  leanring-buddy/Brain/BrainIngestFileRules.swift \
  leanring-buddy/Brain/BrainTextChunker.swift \
  leanring-buddy/Brain/BrainTextExtractor.swift \
  leanring-buddy/Brain/BrainIngestProposalMerger.swift \
  leanring-buddy/Brain/BrainIngestJob.swift \
  leanring-buddy/Brain/BrainSourceSanitizer.swift

"$BUILD_DIR/brain-ingest"
