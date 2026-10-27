#!/bin/bash
#
# Runs the audio device rules: which microphone to record from (lid closed, a mic that went
# silent, virtual loopback devices never chosen), the dead-microphone check, and when the
# output counts as muted. Pure rules only; nothing touches the real devices.
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
  -o "$BUILD_DIR/audio-devices" \
  Tests/AudioDevices/main.swift \
  leanring-buddy/MicrophoneInputDevices.swift \
  leanring-buddy/SystemAudioOutput.swift

"$BUILD_DIR/audio-devices"
