//
//  Audio device rules: microphone choice, dead-microphone detection, muted output.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

let builtInMic = MicrophoneInputDevice(deviceID: 1, uniqueIdentifier: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isBuiltIn: true, isVirtual: false)
let usbMic = MicrophoneInputDevice(deviceID: 2, uniqueIdentifier: "usb-mic", name: "Yeti", isBuiltIn: false, isVirtual: false)
let displayMic = MicrophoneInputDevice(deviceID: 3, uniqueIdentifier: "studio-display", name: "Studio Display Microphone", isBuiltIn: false, isVirtual: false)
let teamsLoopback = MicrophoneInputDevice(deviceID: 4, uniqueIdentifier: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio", isBuiltIn: false, isVirtual: true)

// MARK: - Which microphone

check(MicrophoneInputChoicePolicy.deviceToUseInsteadOfDefault(defaultDevice: builtInMic, availableDevices: [builtInMic, usbMic], isLidClosed: false, recentlySilentDeviceIdentifiers: []) == nil, "lid open, built-in default: leave the default alone")
check(MicrophoneInputChoicePolicy.deviceToUseInsteadOfDefault(defaultDevice: builtInMic, availableDevices: [builtInMic, teamsLoopback, displayMic], isLidClosed: true, recentlySilentDeviceIdentifiers: []) == displayMic, "lid closed: use another real microphone")
check(MicrophoneInputChoicePolicy.deviceToUseInsteadOfDefault(defaultDevice: builtInMic, availableDevices: [builtInMic, teamsLoopback], isLidClosed: true, recentlySilentDeviceIdentifiers: []) == nil, "lid closed with only a loopback device: never record other apps' sound, keep the default")
check(MicrophoneInputChoicePolicy.deviceToUseInsteadOfDefault(defaultDevice: usbMic, availableDevices: [builtInMic, usbMic], isLidClosed: true, recentlySilentDeviceIdentifiers: []) == nil, "lid closed but an external default: keep it")
check(MicrophoneInputChoicePolicy.deviceToUseInsteadOfDefault(defaultDevice: usbMic, availableDevices: [usbMic, displayMic, builtInMic], isLidClosed: false, recentlySilentDeviceIdentifiers: ["usb-mic"]) == builtInMic, "a default that just went silent: fall back to the built-in mic first")
check(MicrophoneInputChoicePolicy.deviceToUseInsteadOfDefault(defaultDevice: usbMic, availableDevices: [usbMic, displayMic, builtInMic], isLidClosed: true, recentlySilentDeviceIdentifiers: ["usb-mic"]) == displayMic, "went silent with the lid closed: another external mic, not the built-in")
check(MicrophoneInputChoicePolicy.deviceToUseInsteadOfDefault(defaultDevice: nil, availableDevices: [builtInMic], isLidClosed: true, recentlySilentDeviceIdentifiers: []) == nil, "no default device: nothing to replace")
check(MicrophoneInputChoicePolicy.alternative(to: builtInMic, among: [builtInMic], isLidClosed: false, recentlySilentDeviceIdentifiers: []) == nil, "only one microphone: no alternative")
check(MicrophoneInputChoicePolicy.alternative(to: displayMic, among: [displayMic, usbMic, builtInMic], isLidClosed: false, recentlySilentDeviceIdentifiers: ["BuiltInMicrophoneDevice"]) == usbMic, "a recently silent device is passed over")

// MARK: - Dead microphone

check(MicrophoneSignalPolicy.looksDead(bufferCount: 0, peakAbsoluteSample: 0), "no buffers at all is dead")
check(MicrophoneSignalPolicy.looksDead(bufferCount: 90, peakAbsoluteSample: 0), "only exact zeros is dead")
check(!MicrophoneSignalPolicy.looksDead(bufferCount: 90, peakAbsoluteSample: 0.0004), "a quiet room's noise floor is alive")

let meter = MicrophoneSignalMeter()
check(meter.looksDead, "a meter that has seen nothing reads dead")
var silentSamples = [Float](repeating: 0, count: 512)
silentSamples.withUnsafeBufferPointer { meter.record(samples: $0.baseAddress!, frameCount: $0.count) }
check(meter.looksDead, "silent buffers still read dead")
var quietSamples = [Float](repeating: 0, count: 512)
quietSamples[100] = -0.002
quietSamples.withUnsafeBufferPointer { meter.record(samples: $0.baseAddress!, frameCount: $0.count) }
check(!meter.looksDead, "one buffer with a noise floor (negative samples too) reads alive")
meter.reset()
check(meter.looksDead, "reset starts over")

// MARK: - Muted output

check(SystemAudioOutputPolicy.isSilent(isMuted: true, volume: 0.6), "muted is silent")
check(SystemAudioOutputPolicy.isSilent(isMuted: false, volume: 0), "zero volume is silent")
check(!SystemAudioOutputPolicy.isSilent(isMuted: false, volume: 0.3), "unmuted with volume is audible")
check(!SystemAudioOutputPolicy.isSilent(isMuted: nil, volume: nil), "a device without controls (HDMI) is never assumed silent")
check(SystemAudioOutputPolicy.isSilent(isMuted: nil, volume: 0.001), "no mute control but volume at the bottom is silent")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
if failureCount > 0 {
    print("\(failureCount) FAILED")
    exit(1)
}
