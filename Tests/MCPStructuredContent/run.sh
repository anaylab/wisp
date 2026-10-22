#!/bin/bash
#
# Runs the MCP structured-content suite: rendering a tool result's
# `structuredContent` for the model (element lines with tokens, compact JSON,
# caps), the unchanged text-only path, MCPClient keeping the two halves apart
# (over a scripted transport), the cua-driver always-ask floor, and the
# cua-driver confirmation card built from cached element tokens.
#
# Standalone (plain swiftc, no xcodebuild — see CLAUDE.md). Reuses the
# EditableConfirmation suite's stubs for the few app-wide names the card code
# refers to.
#
# WISP_LIVE_CUA_DRIVER=1 also runs a live check against the installed
# cua-driver (~/.local/bin/cua-driver, or $CUA_DRIVER_PATH): it starts
# `cua-driver mcp --direct` through Wisp's own MCP client with telemetry off,
# calls only the read-only list_windows and get_window_state, and prints what
# the model would see. No action tool is ever called.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

SHARED_SOURCES=(
  Tests/EditableConfirmation/AppStubs.swift
  leanring-buddy/MCPToolResultRendering.swift
  leanring-buddy/CuaDriverSupport.swift
  leanring-buddy/WindowManagement/WindowLayoutCommand.swift
  leanring-buddy/EditableConfirmationFields.swift
  leanring-buddy/ToolConfirmationCardBuilder.swift
  leanring-buddy/ToolCallInspection.swift
  leanring-buddy/ToolCallSafety.swift
  leanring-buddy/GlanceCard.swift
  leanring-buddy/BuddyChatTypes.swift
  leanring-buddy/ToolMetadata.swift
  leanring-buddy/MCPClient.swift
  leanring-buddy/MCPTransport.swift
  leanring-buddy/MCPStdioTransport.swift
  leanring-buddy/MCPStreamableHTTPTransport.swift
  leanring-buddy/ChromeExtension/ChromeTabLifeCards.swift
  leanring-buddy/ChromeExtension/ChromeTabLifeCardText.swift
)

SWIFTC_FLAGS=(
  -target arm64-apple-macos14.0
  -sdk "$(xcrun --show-sdk-path --sdk macosx)"
  -swift-version 5
  -default-isolation MainActor
  -enable-upcoming-feature MemberImportVisibility
)

swiftc "${SWIFTC_FLAGS[@]}" \
  -o "$BUILD_DIR/mcp-structured-content" \
  Tests/MCPStructuredContent/main.swift \
  Tests/MCPStructuredContent/ScriptedTransportChecks.swift \
  "${SHARED_SOURCES[@]}"

"$BUILD_DIR/mcp-structured-content" Tests/MCPStructuredContent/Fixtures/cua-get-window-state-mail.json

if [[ "${WISP_LIVE_CUA_DRIVER:-0}" == "1" ]]; then
  swiftc "${SWIFTC_FLAGS[@]}" \
    -o "$BUILD_DIR/mcp-live-cua-driver" \
    Tests/MCPStructuredContent/LiveCuaDriver/main.swift \
    "${SHARED_SOURCES[@]}"
  "$BUILD_DIR/mcp-live-cua-driver" "${CUA_DRIVER_PATH:-$HOME/.local/bin/cua-driver}"
fi
