//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Voice input for the whole app. It records from the microphone with
//  AVAudioEngine, feeds the audio to the active transcription provider, and
//  hands the finished text back to whoever started the recording (the chat
//  composer's mic button, or the push-to-talk shortcut).
//

import AppKit
import AudioToolbox
import AVFoundation
import Combine
import Foundation
import Speech

/// Which macOS privacy switch is blocking voice input, so Settings can open
/// the right pane.
enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

/// What started the current recording.
private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

/// How a recording reports back to its owner.
private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {

    // MARK: - Tuning

    /// Used when a transcription session doesn't say how long to wait for its
    /// final text after the user stops.
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4

    /// The waveform keeps this many of the most recent loudness samples.
    private static let waveformSampleCount = 44
    private static let waveformSilentLevel: CGFloat = 0.02
    private static let waveformSampleSpacingSeconds: TimeInterval = 0.07

    // MARK: - Published state

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.waveformSilentLevel,
        count: BuddyDictationManager.waveformSampleCount
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    /// Anything from asking for permission through to delivering the final text.
    var isDictationInProgress: Bool {
        isPreparingToRecord || isActivelyRecordingAudio || isFinalizingTranscript
    }

    /// Whether the microphone is live right now.
    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    /// True until the user has answered the system permission prompts that
    /// this provider needs.
    var needsInitialPermissionPrompt: Bool {
        let microphoneUndecided = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return microphoneUndecided
        }
        return microphoneUndecided || SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    /// Called when a keyboard-shortcut hold ends and nothing was recognised.
    /// The shortcut's owner decides what that means: a short hold was most
    /// likely a tap that ran past the tap cutoff.
    var onKeyboardShortcutHoldEndedWithoutSpeech: (() -> Void)?

    /// Told when recording moved to another microphone, or when no microphone
    /// can hear anything, with a one-line explanation. `CompanionManager`
    /// shows it under the notch.
    var onMicrophoneNotice: ((String) -> Void)?

    // MARK: - Private state

    private let transcriptionProvider: any BuddyTranscriptionProvider
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?

    /// Replaced rather than reconfigured whenever recording moves to another
    /// microphone: an engine whose input device changed underneath it keeps the
    /// old device's format, and the tap then refuses to install.
    private var audioEngine = AVAudioEngine()

    /// The microphone `audioEngine` is pinned to; nil means the system default.
    private var pinnedInputDevice: MicrophoneInputDevice?

    /// Microphones that delivered no sound, by unique id, and when. They are
    /// passed over for `MicrophoneSignalPolicy.silentDeviceAvoidanceSeconds`
    /// and then given another chance.
    private var silentInputDeviceDatesByIdentifier: [String: Date] = [:]
    private let microphoneSignalMeter = MicrophoneSignalMeter()
    private var microphoneSignalCheckWorkItem: DispatchWorkItem?

    /// At most one microphone switch per hold, so two dead microphones can't
    /// keep handing the recording back and forth.
    private var hasSwitchedMicrophoneThisSession = false

    /// Incremented for every transcription session. A callback from a session
    /// that was replaced mid-hold (a microphone switch cancels it) carries an
    /// old number and is ignored instead of ending the new session.
    private var transcriptionSessionGeneration = 0

    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?

    /// Replaced on every start and stop; a start that finds a different value
    /// after its awaits knows it was superseded.
    private var pendingStartRequestIdentifier = UUID()

    private var contextualKeyterms: [String] = []
    private var lastWaveformSampleDate = Date.distantPast

    private var activePermissionRequestTask: Task<Bool, Never>?

    /// When the last permission request finished. macOS can briefly report
    /// "not determined" right after the user taps Allow, so a request that
    /// follows immediately trusts the earlier answer instead of asking again.
    private var lastPermissionRequestCompletedAt: Date?

    // MARK: - Setup

    override init() {
        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        transcriptionProvider = provider
        transcriptionProviderDisplayName = provider.displayName
        super.init()
    }

    /// Extra words (names from the screen, say) to bias recognition toward.
    func updateContextualKeyterms(_ contextualKeyterms: [String]) {
        self.contextualKeyterms = contextualKeyterms
    }

    // MARK: - Starting and stopping

    func startPersistentDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        // A shortcut hold into an empty draft is a question to send; into a
        // draft that already has text, it is dictation to append.
        let draftIsEmpty = currentDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: draftIsEmpty
        )
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    /// Ends any recording or pending start right now. With `preserveDraftText`
    /// the words heard so far are written into the draft first.
    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText {
            draftCallbacks?.updateDraftText(draftText(appending: latestRecognizedText))
        }

        shutDownRecognition()
        resetSessionState()
    }

    /// Asks for microphone and speech permission up front, so the first real
    /// push-to-talk isn't interrupted by a system dialog.
    func requestInitialPushToTalkPermissionsIfNeeded() async {
        guard needsInitialPermissionPrompt, !isDictationInProgress else { return }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        await bringAppForwardForPermissionDialog()

        if await requestPermissionsSharingAnyRequestInFlight() {
            lastErrorMessage = nil
        }
        isPreparingToRecord = false
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) async {
        guard !isDictationInProgress else { return }

        print("🎙️ BuddyDictationManager: start requested (\(startSource))")

        if needsInitialPermissionPrompt {
            print("🎙️ BuddyDictationManager: requesting initial permissions")
            await bringAppForwardForPermissionDialog()
        }

        let thisStartRequest = UUID()
        pendingStartRequestIdentifier = thisStartRequest

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestPermissionsSharingAnyRequestInFlight() else {
            print("🎙️ BuddyDictationManager: permissions missing or denied")
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released during permission check)")
            isPreparingToRecord = false
            return
        }
        guard pendingStartRequestIdentifier == thisStartRequest else {
            print("🎙️ BuddyDictationManager: start request superseded")
            isPreparingToRecord = false
            return
        }

        beginSessionState(
            startSource: startSource,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: shouldAutomaticallySubmitFinalDraftOnStop
        )

        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            resetSessionState()
            return
        }

        hasSwitchedMicrophoneThisSession = false

        do {
            try await startRecognitionSession()

            guard !Task.isCancelled else {
                print("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                shutDownRecognition()
                resetSessionState()
                return
            }

            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            print("🎙️ BuddyDictationManager: recognition session started")
            scheduleMicrophoneSignalCheck()
        } catch {
            isPreparingToRecord = false
            lastErrorMessage = message(for: error, fallback: "couldn't start voice input. try again.")
            print("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            resetSessionState()
        }
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true

        let secondsToWaitForFinalText = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        stopAudioCapture()
        activeTranscriptionSession?.requestFinalTranscript()

        // If the provider never delivers a final transcript, settle for the
        // last partial after the provider's own grace period.
        let submitsWhenFallbackFires = shouldAutomaticallySubmitFinalDraft
        finalizeFallbackWorkItem?.cancel()
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: submitsWhenFallbackFires)
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsToWaitForFinalText, execute: fallbackWorkItem)
    }

    /// Puts every field into its "recording has begun" value.
    private func beginSessionState(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) {
        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        microphoneButtonRecordingStartedAt = nil
        clearWaveform()
    }

    // MARK: - Recognition session

    private func startRecognitionSession() async throws {
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        transcriptionSessionGeneration += 1
        let thisGeneration = transcriptionSessionGeneration

        print("🎙️ BuddyDictationManager: opening transcription provider \(transcriptionProvider.displayName)")

        // Every callback re-checks the generation on the main actor before
        // touching state, since a replaced session can still call back late.
        let session = try await transcriptionProvider.startStreamingSession(
            keyterms: transcriptionKeyterms(),
            localeIdentifier: DictationSettingsStore.shared.selectedLanguageLocaleIdentifier,
            onTranscriptUpdate: { [weak self] partialText in
                Task { @MainActor in
                    guard let self, self.transcriptionSessionGeneration == thisGeneration else { return }
                    self.latestRecognizedText = partialText
                }
            },
            onFinalTranscriptReady: { [weak self] finalText in
                Task { @MainActor in
                    guard let self, self.transcriptionSessionGeneration == thisGeneration else { return }
                    self.latestRecognizedText = finalText

                    if self.isFinalizingTranscript {
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.transcriptionSessionGeneration == thisGeneration else { return }
                    self.handleRecognitionError(error)
                }
            }
        )

        activeTranscriptionSession = session
        print("🎙️ BuddyDictationManager: provider ready, starting audio engine")

        pinAudioEngineToUsableMicrophone()
        do {
            try installTapAndStartAudioEngine()
        } catch {
            // The microphone wouldn't start (unplugged mid-use, wedged driver).
            // Give another one a single chance.
            try startOnAnotherMicrophone(after: error)
        }
    }

    private func startOnAnotherMicrophone(after startError: Error) throws {
        guard let failedDevice = pinnedInputDevice ?? MicrophoneInputDevices.defaultInputDevice() else {
            throw startError
        }
        print("⚠️ BuddyDictationManager: \(failedDevice.name) failed to start (\(startError)); trying another microphone")

        silentInputDeviceDatesByIdentifier[failedDevice.uniqueIdentifier] = Date()
        let deviceBeforeRetry = pinnedInputDevice
        pinAudioEngineToUsableMicrophone(announcesChange: false)

        guard let replacementDevice = pinnedInputDevice, replacementDevice != deviceBeforeRetry else {
            throw startError
        }

        try installTapAndStartAudioEngine()
        onMicrophoneNotice?("\(failedDevice.name) couldn't start, so Wisp is listening on \(replacementDevice.name)")
    }

    private func installTapAndStartAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let signalMeter = microphoneSignalMeter
        signalMeter.reset()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            if let channels = buffer.floatChannelData {
                signalMeter.record(samples: channels[0], frameCount: Int(buffer.frameLength))
            }
            self?.activeTranscriptionSession?.appendAudioBuffer(buffer)
            self?.updateAudioPowerLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopAudioCapture() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Stops the microphone and abandons the recognition session.
    private func shutDownRecognition() {
        stopAudioCapture()
        activeTranscriptionSession?.cancel()
    }

    // MARK: - Microphone fallback

    private var currentlyAvoidedInputDeviceIdentifiers: Set<String> {
        let now = Date()
        silentInputDeviceDatesByIdentifier = silentInputDeviceDatesByIdentifier.filter { _, silentSince in
            now.timeIntervalSince(silentSince) < MicrophoneSignalPolicy.silentDeviceAvoidanceSeconds
        }
        return Set(silentInputDeviceDatesByIdentifier.keys)
    }

    /// Records from the system default unless it would hear nothing (the
    /// built-in mic with the lid closed, or a mic that just went silent); then
    /// another input is used.
    private func pinAudioEngineToUsableMicrophone(announcesChange: Bool = true) {
        let defaultDevice = MicrophoneInputDevices.defaultInputDevice()
        let lidIsClosed = MicrophoneInputDevices.isLidClosed()
        let replacementDevice = MicrophoneInputChoicePolicy.deviceToUseInsteadOfDefault(
            defaultDevice: defaultDevice,
            availableDevices: MicrophoneInputDevices.availableInputDevices(),
            isLidClosed: lidIsClosed,
            recentlySilentDeviceIdentifiers: currentlyAvoidedInputDeviceIdentifiers
        )
        guard replacementDevice?.uniqueIdentifier != pinnedInputDevice?.uniqueIdentifier else { return }

        stopAudioCapture()
        audioEngine = AVAudioEngine()
        pinnedInputDevice = replacementDevice

        guard let replacementDevice else {
            print("🎙️ BuddyDictationManager: back to the system default microphone")
            return
        }

        select(replacementDevice, on: audioEngine)
        print("🎙️ BuddyDictationManager: recording from \(replacementDevice.name) instead of \(defaultDevice?.name ?? "the default")")

        if announcesChange {
            let reasonText = (defaultDevice?.isBuiltIn == true && lidIsClosed)
                ? "The lid is closed"
                : "\(defaultDevice?.name ?? "Your microphone") wasn't picking up sound"
            onMicrophoneNotice?("\(reasonText), so Wisp is listening on \(replacementDevice.name)")
        }
    }

    private func select(_ device: MicrophoneInputDevice, on engine: AVAudioEngine) {
        guard let inputUnit = engine.inputNode.audioUnit else { return }

        var deviceID = device.deviceID
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("⚠️ BuddyDictationManager: couldn't switch to \(device.name) (status \(status))")
        }
    }

    /// A couple of seconds into a hold, checks that sound is really arriving.
    /// If not, the microphone is wedged or muted in hardware: move to another
    /// one and start over. Nothing usable was captured, so nothing is lost.
    private func scheduleMicrophoneSignalCheck() {
        microphoneSignalCheckWorkItem?.cancel()

        let generationWhenScheduled = transcriptionSessionGeneration
        let signalCheck = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.transcriptionSessionGeneration == generationWhenScheduled,
                      self.isActivelyRecordingAudio,
                      !self.hasSwitchedMicrophoneThisSession,
                      self.microphoneSignalMeter.looksDead else { return }
                await self.switchToAnotherMicrophoneAfterSilence()
            }
        }
        microphoneSignalCheckWorkItem = signalCheck
        DispatchQueue.main.asyncAfter(
            deadline: .now() + MicrophoneSignalPolicy.checkDelaySeconds,
            execute: signalCheck
        )
    }

    private func switchToAnotherMicrophoneAfterSilence() async {
        guard let silentDevice = pinnedInputDevice ?? MicrophoneInputDevices.defaultInputDevice() else { return }

        hasSwitchedMicrophoneThisSession = true
        silentInputDeviceDatesByIdentifier[silentDevice.uniqueIdentifier] = Date()
        print("⚠️ BuddyDictationManager: no sound from \(silentDevice.name) after \(MicrophoneSignalPolicy.checkDelaySeconds)s")

        let alternativeDevice = MicrophoneInputChoicePolicy.alternative(
            to: silentDevice,
            among: MicrophoneInputDevices.availableInputDevices(),
            isLidClosed: MicrophoneInputDevices.isLidClosed(),
            recentlySilentDeviceIdentifiers: currentlyAvoidedInputDeviceIdentifiers
        )

        guard alternativeDevice != nil else {
            // Nothing to switch to. Say so anyway: silence otherwise looks like
            // Wisp ignoring the user.
            silentInputDeviceDatesByIdentifier[silentDevice.uniqueIdentifier] = nil
            onMicrophoneNotice?("\(silentDevice.name) isn't picking up any sound. Check that it's on and not muted.")
            return
        }

        do {
            // The new session picks its device again and now skips the silent one.
            try await startRecognitionSession()

            if !isActivelyRecordingAudio {
                // Released during the switch; that release already asked for the final text.
                stopAudioCapture()
            }
        } catch {
            print("❌ BuddyDictationManager: couldn't restart on another microphone: \(error)")
            lastErrorMessage = message(for: error, fallback: "couldn't start voice input. try again.")
            cancelCurrentDictation(preserveDraftText: true)
        }
    }

    // MARK: - Finishing

    private func handleRecognitionError(_ error: Error) {
        guard !hasFinishedCurrentDictationSession else { return }

        let heardSomething = !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isFinalizingTranscript && heardSomething {
            // The engine errored on its way out, but it had already heard words.
            finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft)
            return
        }

        print("❌ Buddy dictation error (\(transcriptionProvider.displayName)): \(error)")
        lastErrorMessage = message(for: error, fallback: "couldn't transcribe that. try again.")
        cancelCurrentDictation(preserveDraftText: false)
    }

    private func finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: Bool) {
        guard !hasFinishedCurrentDictationSession else { return }
        hasFinishedCurrentDictationSession = true

        let wasKeyboardShortcutHold = activeStartSource == .keyboardShortcut

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalDraftText = draftText(appending: latestRecognizedText)
        let spokenText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let callbacks = draftCallbacks

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
            callbacks?.updateDraftText(finalDraftText)
        }

        shutDownRecognition()
        resetSessionState()

        guard shouldSubmitFinalDraft else { return }

        if spokenText.isEmpty {
            if wasKeyboardShortcutHold {
                onKeyboardShortcutHoldEndedWithoutSpeech?()
            }
            return
        }

        callbacks?.submitDraftText(finalDraftText)
    }

    /// The draft as it should read once `transcribedText` is added: the
    /// original draft, a separating space if it needs one, then the new words.
    private func draftText(appending transcribedText: String) -> String {
        let newWords = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newWords.isEmpty else { return draftTextBeforeCurrentDictation }

        let originalDraft = draftTextBeforeCurrentDictation
        guard !originalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return newWords
        }

        let alreadySeparated = originalDraft.hasSuffix(" ") || originalDraft.hasSuffix("\n")
        return alreadySeparated ? originalDraft + newWords : originalDraft + " " + newWords
    }

    private func resetSessionState() {
        pendingStartRequestIdentifier = UUID()
        microphoneSignalCheckWorkItem?.cancel()
        microphoneSignalCheckWorkItem = nil

        activeTranscriptionSession = nil
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false

        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        microphoneButtonRecordingStartedAt = nil
        clearWaveform()
    }

    // MARK: - Vocabulary

    /// Built-in terms, the screen's contextual terms and the user's dictionary,
    /// trimmed and de-duplicated ignoring case, in first-seen order.
    private func transcriptionKeyterms() -> [String] {
        let builtInKeyterms = [
            "Wisp", "Codex", "Claude", "Anthropic", "OpenAI",
            "SwiftUI", "Xcode", "Vercel", "Next.js", "localhost",
        ]
        let candidates = builtInKeyterms + contextualKeyterms + DictationSettingsStore.shared.customDictionaryWords

        var seenLowercased = Set<String>()
        var keyterms: [String] = []

        for candidate in candidates {
            let keyterm = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyterm.isEmpty, seenLowercased.insert(keyterm.lowercased()).inserted else { continue }
            keyterms.append(keyterm)
        }
        return keyterms
    }

    // MARK: - Waveform

    private func clearWaveform() {
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(repeating: Self.waveformSilentLevel, count: Self.waveformSampleCount)
        lastWaveformSampleDate = .distantPast
    }

    /// Measures a buffer's loudness (RMS, boosted to fill the 0...1 range) and
    /// publishes it, both as a smoothed live level and as periodic samples for
    /// the scrolling waveform.
    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channels = audioBuffer.floatChannelData else { return }

        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        let firstChannel = channels[0]
        var sumOfSquares: Float = 0
        for frameIndex in 0..<frameCount {
            sumOfSquares += firstChannel[frameIndex] * firstChannel[frameIndex]
        }

        let rootMeanSquare = (sumOfSquares / Float(frameCount)).squareRoot()
        let loudness = CGFloat(min(max(rootMeanSquare * 10.2, 0), 1))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Rise instantly, fall gradually.
            self.currentAudioPowerLevel = max(loudness, self.currentAudioPowerLevel * 0.72)

            let now = Date()
            guard now.timeIntervalSince(self.lastWaveformSampleDate) >= Self.waveformSampleSpacingSeconds else { return }
            self.lastWaveformSampleDate = now
            self.appendWaveformSample(max(loudness, Self.waveformSilentLevel))
        }
    }

    private func appendWaveformSample(_ loudness: CGFloat) {
        var samples = recordedAudioPowerHistory
        samples.append(loudness)
        if samples.count > Self.waveformSampleCount {
            samples.removeFirst(samples.count - Self.waveformSampleCount)
        }
        recordedAudioPowerHistory = samples
    }

    // MARK: - Permissions

    /// Gives macOS a moment to bring Wisp forward so its permission dialogs
    /// appear in front of the user.
    private func bringAppForwardForPermissionDialog() async {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // A cancelled sleep just means we carry on to the permission check sooner.
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Microphone first, then speech recognition if the provider needs it.
    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        guard await requestMicrophonePermissionIfNeeded() else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else { return true }

        guard await requestSpeechRecognitionPermissionIfNeeded() else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }
        return true
    }

    /// Fanning out several permission requests before the first finishes makes
    /// macOS show its sheet again, so at most one request task exists at a time
    /// and rapid repeat presses all wait on its result. For a short cooldown
    /// after it finishes, further calls skip asking and trust the earlier answer.
    private func requestPermissionsSharingAnyRequestInFlight() async -> Bool {
        if let requestInFlight = activePermissionRequestTask {
            return await requestInFlight.value
        }

        if let finishedAt = lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(finishedAt) < 1.0 {
            let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            return microphoneStatus != .denied && microphoneStatus != .restricted
        }

        let requestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }
        activePermissionRequestTask = requestTask

        let granted = await requestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return granted
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true

        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            currentPermissionProblem = granted ? nil : .microphoneAccessDenied
            return granted

        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false

        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true

        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            currentPermissionProblem = granted ? nil : .speechRecognitionDenied
            return granted

        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false

        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    /// Opens the System Settings pane for whichever permission is missing, or
    /// the general Privacy & Security page if none is singled out.
    func openRelevantPrivacySettings() {
        let privacyPane = "x-apple.systempreferences:com.apple.preference.security"

        let destination: String
        switch currentPermissionProblem {
        case .microphoneAccessDenied: destination = "\(privacyPane)?Privacy_Microphone"
        case .speechRecognitionDenied: destination = "\(privacyPane)?Privacy_SpeechRecognition"
        case nil: destination = privacyPane
        }

        guard let url = URL(string: destination) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Error text

    /// Prefers the error's own description, but not the generic system
    /// "operation couldn't be completed" line, which tells the user nothing.
    private func message(for error: Error, fallback: String) -> String {
        let genericSystemText = "The operation couldn’t be completed."

        let describedByError = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let describedByError, !describedByError.isEmpty {
            return describedByError
        }

        let systemDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemDescription.isEmpty, systemDescription != genericSystemText {
            return systemDescription
        }

        return fallback
    }
}
