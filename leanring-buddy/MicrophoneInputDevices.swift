//
//  MicrophoneInputDevices.swift
//  leanring-buddy
//
//  Which microphone push-to-talk records from, when the system default would hear nothing:
//  - With a MacBook's lid closed the built-in mic still reads as the default input, but it
//    records near-silence. Wisp picks another input (a display's, a headset's, a USB mic).
//  - A mic that is plugged in but wedged delivers no audio, or exact digital zeros. Wisp notices
//    within a couple of seconds of the hold starting, switches to another input, and says so.
//
//  The pure rules (`MicrophoneInputChoicePolicy`, `MicrophoneSignalPolicy`) are Foundation-only
//  and tested by Tests/AudioDevices; the CoreAudio and IOKit reads are below them.
//

import CoreAudio
import Foundation
import IOKit

nonisolated struct MicrophoneInputDevice: Equatable, Sendable {
    let deviceID: AudioDeviceID
    /// Stable across launches and reconnects, unlike the id.
    let uniqueIdentifier: String
    let name: String
    let isBuiltIn: Bool
    /// A software device (loopback drivers like Teams Audio or BlackHole) that captures other
    /// apps' sound, not the room. Never chosen as a fallback.
    let isVirtual: Bool
}

/// Picks the device to record from. Nil = leave the system default alone.
nonisolated enum MicrophoneInputChoicePolicy {
    static func deviceToUseInsteadOfDefault(
        defaultDevice: MicrophoneInputDevice?,
        availableDevices: [MicrophoneInputDevice],
        isLidClosed: Bool,
        recentlySilentDeviceIdentifiers: Set<String>
    ) -> MicrophoneInputDevice? {
        guard let defaultDevice else { return nil }
        let defaultIsUnusable = (defaultDevice.isBuiltIn && isLidClosed)
            || recentlySilentDeviceIdentifiers.contains(defaultDevice.uniqueIdentifier)
        guard defaultIsUnusable else { return nil }
        return alternative(
            to: defaultDevice,
            among: availableDevices,
            isLidClosed: isLidClosed,
            recentlySilentDeviceIdentifiers: recentlySilentDeviceIdentifiers
        )
    }

    /// Another input than `currentDevice`: never the built-in mic with the lid closed, never one
    /// that just went silent. The built-in mic is preferred when the lid is open (it is always
    /// there and rarely the thing that broke); otherwise the first other device.
    static func alternative(
        to currentDevice: MicrophoneInputDevice,
        among availableDevices: [MicrophoneInputDevice],
        isLidClosed: Bool,
        recentlySilentDeviceIdentifiers: Set<String>
    ) -> MicrophoneInputDevice? {
        let candidates = availableDevices.filter { candidate in
            candidate.uniqueIdentifier != currentDevice.uniqueIdentifier
                && !recentlySilentDeviceIdentifiers.contains(candidate.uniqueIdentifier)
                && !(candidate.isBuiltIn && isLidClosed)
                && !candidate.isVirtual
        }
        return candidates.first { $0.isBuiltIn } ?? candidates.first
    }
}

/// Whether the audio arriving during the first moments of a hold shows a dead microphone.
nonisolated enum MicrophoneSignalPolicy {
    /// How long into a hold the check runs. Long enough for a Bluetooth headset to finish
    /// switching to its microphone profile, short enough that most of what was said is still ahead.
    static let checkDelaySeconds: TimeInterval = 2.0
    /// How long a device that went silent is passed over before Wisp tries it again.
    static let silentDeviceAvoidanceSeconds: TimeInterval = 10 * 60

    /// A live microphone always carries a noise floor, so not a single buffer, or buffers that
    /// are all exact zeros, means nothing is being captured. A quiet room is never this.
    static func looksDead(bufferCount: Int, peakAbsoluteSample: Float) -> Bool {
        bufferCount == 0 || peakAbsoluteSample == 0
    }
}

/// Counts what the input tap delivers. Written on the audio thread, read on the main thread.
nonisolated final class MicrophoneSignalMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferCount = 0
    private var peakAbsoluteSample: Float = 0

    func reset() {
        lock.lock()
        bufferCount = 0
        peakAbsoluteSample = 0
        lock.unlock()
    }

    func record(samples: UnsafePointer<Float>, frameCount: Int) {
        var bufferPeak: Float = 0
        for sampleIndex in 0..<frameCount {
            bufferPeak = max(bufferPeak, abs(samples[sampleIndex]))
        }
        lock.lock()
        bufferCount += 1
        peakAbsoluteSample = max(peakAbsoluteSample, bufferPeak)
        lock.unlock()
    }

    var looksDead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return MicrophoneSignalPolicy.looksDead(bufferCount: bufferCount, peakAbsoluteSample: peakAbsoluteSample)
    }
}

// MARK: - System reads

nonisolated enum MicrophoneInputDevices {
    static func defaultInputDevice() -> MicrophoneInputDevice? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return device(withID: deviceID)
    }

    /// Every device with at least one input channel that is alive right now, in system order.
    static func availableInputDevices() -> [MicrophoneInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(propertySize) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs) == noErr else { return [] }
        return deviceIDs.compactMap { deviceID in
            guard hasInputChannels(deviceID), isAlive(deviceID) else { return nil }
            return device(withID: deviceID)
        }
    }

    /// The MacBook lid, from the power-management root domain. False on desktops (no property).
    static func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        guard let clamshellState = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return false }
        return clamshellState
    }

    private static func device(withID deviceID: AudioDeviceID) -> MicrophoneInputDevice? {
        guard let uniqueIdentifier = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID) else { return nil }
        let name = stringProperty(kAudioObjectPropertyName, of: deviceID) ?? "Microphone"
        let deviceTransportType = transportType(of: deviceID)
        return MicrophoneInputDevice(
            deviceID: deviceID,
            uniqueIdentifier: uniqueIdentifier,
            name: name,
            isBuiltIn: deviceTransportType == kAudioDeviceTransportTypeBuiltIn,
            isVirtual: deviceTransportType == kAudioDeviceTransportTypeVirtual
                || deviceTransportType == kAudioDeviceTransportTypeAggregate
                || deviceTransportType == kAudioDeviceTransportTypeAutoAggregate
                || deviceTransportType == kAudioDeviceTransportTypeUnknown
        )
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &transportType)
        return transportType
    }

    private static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var isAliveValue: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &isAliveValue) == noErr else { return false }
        return isAliveValue != 0
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr, propertySize > 0 else { return false }
        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferListPointer) == noErr else { return false }
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.contains { $0.mNumberChannels > 0 }
    }
}
