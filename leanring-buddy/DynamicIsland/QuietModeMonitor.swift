//
//  QuietModeMonitor.swift
//  leanring-buddy
//
//  Knows when the user is busy with other people — on a call — so Wisp keeps
//  its unprompted announcements to itself: the morning suggestions banner waits,
//  and a background task that finishes records its result in the notch (a
//  "N new" badge) instead of posting a system notification over the call.
//  Anything the user asks for directly still behaves normally.
//
//  "On a call" is read from the hardware, not guessed from which apps are open:
//  another process capturing the microphone (CoreAudio's per-process
//  `kAudioProcessPropertyIsRunningInput`, which lets Wisp's own dictation be
//  excluded by PID), or any camera running. That covers Zoom, Meet in a browser,
//  FaceTime, Teams, Slack huddles… without a list of apps to maintain.
//
//  Focus / Do Not Disturb is deliberately NOT detected: the only readable
//  signals need either Full Disk Access (`~/Library/DoNotDisturb`) or a
//  provisioned communication-notifications entitlement, and a half-working
//  guess is worse than none. The system already holds Wisp's notifications
//  during Focus anyway.
//

import Combine
import CoreAudio
import CoreMediaIO
import Foundation

/// Why Wisp is currently keeping quiet.
enum QuietModeReason: Equatable {
    /// Another app is capturing the microphone.
    case microphoneInUseByAnotherApp
    /// A camera is running.
    case cameraInUse

    /// A short phrase for tooltips and the dashboard: "You're on a call".
    var summary: String {
        switch self {
        case .microphoneInUseByAnotherApp: return "You're on a call"
        case .cameraInUse: return "Your camera is on"
        }
    }
}

/// The hardware reads behind quiet mode. Kept free of state so the process
/// filtering can be tested without a microphone.
enum QuietModeDetection {
    /// Background system services that hold the microphone for their own
    /// always-on listening ("Hey Siri", Sound Recognition, Voice Control). They
    /// capture input most of the day, so counting them would make Wisp think the
    /// user is permanently on a call. Measured on macOS 26: `com.apple.CoreSpeech`
    /// reports running input intermittently at rest.
    static let alwaysListeningSystemServiceBundleIdentifiers: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.corespeechd",
        "com.apple.assistantd",
        "com.apple.SiriNCService",
        "com.apple.accessibility.heard",
        "com.apple.universalaccessd",
    ]

    /// One process that CoreAudio reports as capturing input.
    struct AudioInputCapturingProcess: Equatable {
        let processIdentifier: pid_t
        let bundleIdentifier: String
    }

    /// Whether any of the capturing processes counts as "the user is on a call":
    /// anything other than Wisp itself and the always-listening system services.
    static func isCallLikeMicrophoneCapture(
        among capturingProcesses: [AudioInputCapturingProcess],
        excludingProcessIdentifier ownProcessIdentifier: pid_t
    ) -> Bool {
        capturingProcesses.contains { capturingProcess in
            capturingProcess.processIdentifier != ownProcessIdentifier
                && !alwaysListeningSystemServiceBundleIdentifiers.contains(capturingProcess.bundleIdentifier)
        }
    }

    /// Every process currently capturing audio input, from CoreAudio's process
    /// object list (macOS 14.2+). Returns an empty list if CoreAudio can't be read.
    static func processesCapturingAudioInput() -> [AudioInputCapturingProcess] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var processListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processListByteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &processListAddress, 0, nil, &processListByteCount) == noErr,
              processListByteCount > 0 else {
            return []
        }
        var processObjectIDs = [AudioObjectID](
            repeating: 0,
            count: Int(processListByteCount) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            systemObjectID, &processListAddress, 0, nil, &processListByteCount, &processObjectIDs
        ) == noErr else {
            return []
        }

        return processObjectIDs.compactMap { processObjectID in
            let isRunningInput: UInt32 = readAudioObjectScalar(
                processObjectID,
                selector: kAudioProcessPropertyIsRunningInput,
                fallback: 0
            )
            guard isRunningInput != 0 else { return nil }
            let processIdentifier: pid_t = readAudioObjectScalar(
                processObjectID,
                selector: kAudioProcessPropertyPID,
                fallback: -1
            )
            return AudioInputCapturingProcess(
                processIdentifier: processIdentifier,
                bundleIdentifier: readAudioProcessBundleIdentifier(processObjectID)
            )
        }
    }

    /// Whether any camera is running in any process (CoreMediaIO). Wisp never
    /// uses the camera, so there is nothing of its own to exclude.
    static func isAnyCameraRunning() -> Bool {
        let systemObjectID = CMIOObjectID(kCMIOObjectSystemObject)
        var deviceListAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var deviceListByteCount: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObjectID, &deviceListAddress, 0, nil, &deviceListByteCount) == noErr,
              deviceListByteCount > 0 else {
            return false
        }
        var cameraDeviceIDs = [CMIOObjectID](
            repeating: 0,
            count: Int(deviceListByteCount) / MemoryLayout<CMIOObjectID>.size
        )
        var deviceListBytesUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            systemObjectID, &deviceListAddress, 0, nil, deviceListByteCount, &deviceListBytesUsed, &cameraDeviceIDs
        ) == noErr else {
            return false
        }

        return cameraDeviceIDs.contains { cameraDeviceID in
            var isRunningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var isRunningSomewhere: UInt32 = 0
            var isRunningBytesUsed: UInt32 = 0
            let readStatus = CMIOObjectGetPropertyData(
                cameraDeviceID,
                &isRunningAddress,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &isRunningBytesUsed,
                &isRunningSomewhere
            )
            return readStatus == noErr && isRunningSomewhere != 0
        }
    }

    private static func readAudioObjectScalar<ScalarValue>(
        _ audioObjectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        fallback: ScalarValue
    ) -> ScalarValue {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = fallback
        var valueByteCount = UInt32(MemoryLayout<ScalarValue>.size)
        let readStatus = AudioObjectGetPropertyData(audioObjectID, &propertyAddress, 0, nil, &valueByteCount, &value)
        return readStatus == noErr ? value : fallback
    }

    private static func readAudioProcessBundleIdentifier(_ processObjectID: AudioObjectID) -> String {
        var bundleIdentifierAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleIdentifier: Unmanaged<CFString>?
        var valueByteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let readStatus = AudioObjectGetPropertyData(
            processObjectID, &bundleIdentifierAddress, 0, nil, &valueByteCount, &bundleIdentifier
        )
        guard readStatus == noErr, let bundleIdentifier else { return "" }
        return bundleIdentifier.takeRetainedValue() as String
    }
}

/// Polls the hardware every few seconds and publishes whether Wisp should be
/// keeping quiet. Two consecutive busy readings are needed to go quiet (a
/// dictation app grabbing the mic for a moment is not a call), and it only
/// relaxes after several idle readings (a call's brief mute is not the end of it).
@MainActor
final class QuietModeMonitor: ObservableObject {
    static let shared = QuietModeMonitor()

    private static let pollIntervalSeconds: TimeInterval = 4
    private static let busyReadingsNeededToGoQuiet = 2
    private static let idleReadingsNeededToRelax = 5

    /// Why Wisp is quiet right now, or nil when it may speak up. Always nil when
    /// the user has turned quiet mode off in the dashboard.
    @Published private(set) var activeQuietReason: QuietModeReason?

    private var pollTimer: Timer?
    private var consecutiveBusyReadings = 0
    private var consecutiveIdleReadings = 0

    private init() {}

    /// Whether unprompted announcements should be held back right now.
    var isQuiet: Bool { activeQuietReason != nil }

    /// Starts polling. Safe to call more than once.
    func start() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    private func refresh() {
        guard AnnouncementPreferences.shared.isQuietDuringCallsEnabled else {
            consecutiveBusyReadings = 0
            consecutiveIdleReadings = 0
            if activeQuietReason != nil { activeQuietReason = nil }
            return
        }

        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        // Both reads are a handful of property lookups — cheap enough for the
        // main actor every few seconds.
        let currentBusyReason: QuietModeReason?
        if QuietModeDetection.isCallLikeMicrophoneCapture(
            among: QuietModeDetection.processesCapturingAudioInput(),
            excludingProcessIdentifier: ownProcessIdentifier
        ) {
            currentBusyReason = .microphoneInUseByAnotherApp
        } else if QuietModeDetection.isAnyCameraRunning() {
            currentBusyReason = .cameraInUse
        } else {
            currentBusyReason = nil
        }

        if let currentBusyReason {
            consecutiveBusyReadings += 1
            consecutiveIdleReadings = 0
            if consecutiveBusyReadings >= Self.busyReadingsNeededToGoQuiet,
               activeQuietReason != currentBusyReason {
                activeQuietReason = currentBusyReason
            }
        } else {
            consecutiveIdleReadings += 1
            consecutiveBusyReadings = 0
            if consecutiveIdleReadings >= Self.idleReadingsNeededToRelax, activeQuietReason != nil {
                activeQuietReason = nil
            }
        }
    }
}
