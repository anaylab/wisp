//
//  SystemAudioOutput.swift
//  leanring-buddy
//
//  Reads (and, on request, fixes) whether the Mac's current output device can be heard. A reply
//  spoken into a muted speaker is lost without a trace, so the reply path checks first and, when
//  the output is silent, copies the answer to the clipboard and offers a one-click "turn sound
//  on" in the notch instead (`CompanionManager.mutedReplyNoticeText`).
//
//  CoreAudio on the default output device. Devices that expose no mute or volume control (many
//  HDMI/DisplayPort outputs) read as audible, since Wisp can't tell and shouldn't guess.
//

import AudioToolbox
import CoreAudio
import Foundation

nonisolated enum SystemAudioOutput {
    /// What a lifted volume is raised to when the user asks Wisp to turn the sound on: audible
    /// but not loud, since they may be in a quiet room.
    static let volumeAfterTurningSoundOn: Float32 = 0.4

    /// True when the default output is muted or at (effectively) zero volume.
    static func isDefaultOutputSilent() -> Bool {
        guard let outputDeviceID = defaultOutputDeviceID() else { return false }
        return SystemAudioOutputPolicy.isSilent(
            isMuted: readMute(of: outputDeviceID),
            volume: readVolume(of: outputDeviceID)
        )
    }

    /// Unmutes the default output and lifts a zero volume. Returns whether it is audible now.
    @discardableResult
    static func turnSoundOnForDefaultOutput() -> Bool {
        guard let outputDeviceID = defaultOutputDeviceID() else { return false }
        if readMute(of: outputDeviceID) == true {
            var unmutedValue: UInt32 = 0
            var muteAddress = outputPropertyAddress(selector: kAudioDevicePropertyMute)
            _ = AudioObjectSetPropertyData(outputDeviceID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmutedValue)
        }
        if let currentVolume = readVolume(of: outputDeviceID),
           currentVolume < SystemAudioOutputPolicy.silentVolumeThreshold {
            var raisedVolume = volumeAfterTurningSoundOn
            var volumeAddress = outputPropertyAddress(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            _ = AudioObjectSetPropertyData(outputDeviceID, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &raisedVolume)
        }
        return !isDefaultOutputSilent()
    }

    // MARK: - CoreAudio

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func outputPropertyAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Nil when the device has no mute control.
    private static func readMute(of deviceID: AudioObjectID) -> Bool? {
        var address = outputPropertyAddress(selector: kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muteValue: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &muteValue) == noErr else { return nil }
        return muteValue != 0
    }

    /// 0...1, or nil when the device has no volume control (the "virtual main volume" is the
    /// one the menu bar slider moves, across a device's channels).
    private static func readVolume(of deviceID: AudioObjectID) -> Float32? {
        var address = outputPropertyAddress(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &volume) == noErr else { return nil }
        return volume
    }
}

/// The pure rule, so it can be tested without touching the user's speakers.
nonisolated enum SystemAudioOutputPolicy {
    /// Below this the menu bar slider is at its bottom notch.
    static let silentVolumeThreshold: Float32 = 0.01

    /// Unknown (nil) never counts as silent.
    static func isSilent(isMuted: Bool?, volume: Float32?) -> Bool {
        if isMuted == true { return true }
        if let volume, volume < silentVolumeThreshold { return true }
        return false
    }
}
