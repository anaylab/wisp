#!/bin/bash
#
# Runs the coding agents & services suite: hook payload parsing, the
# settings-file merging behind "Install hooks", the Python hook relay end to
# end against a test socket (skipped without the command line tools), and the
# service integrations' response parsing.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md).
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
  -o "$BUILD_DIR/coding-agents-and-services" \
  Tests/CodingAgentsAndServices/main.swift \
  leanring-buddy/CodingAgents/CodingAgentHookEvent.swift \
  leanring-buddy/CodingAgents/CodingAgentHookRelay.swift \
  leanring-buddy/CodingAgents/CodingAgentHookServer.swift \
  leanring-buddy/CodingAgents/CodingAgentHookInstaller.swift \
  leanring-buddy/Integrations/ServiceIntegration.swift \
  leanring-buddy/Integrations/ServiceIntegrationClient.swift

"$BUILD_DIR/coding-agents-and-services"
