//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Boxes, arrows and highlights the assistant has drawn, keyed by the
    /// frame of the display they belong to.
    ///
    /// Keyed by frame rather than by index because the order of
    /// `NSScreen.screens` need not match the order screenshots were captured
    /// in, and an off-by-one there would draw on the wrong monitor. The
    /// pointing code matches displays the same way.
    ///
    /// Cleared when the user speaks again — annotations describe one answer,
    /// and leaving them up during the next question would be misleading.
    @Published var activeAnnotationsByDisplayFrame: [CGRect: [ScreenAnnotation]] = [:]
    /// Pixel size of the screenshot each display's annotations came from,
    /// needed to scale them onto that display.
    @Published var annotationScreenshotSizeByDisplayFrame: [CGRect: CGSize] = [:]

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.


    /// Whether a request may run tools across several model calls.
    ///
    /// Off by default: tools make some answers possible that otherwise aren't,
    /// but every extra call adds latency to a pipeline that was deliberately
    /// tuned down to a few seconds, so this is opt-in via `AgentModeEnabled`
    /// in Info.plist rather than something everyone pays for.
    static var isAgentModeEnabled: Bool {
        AppBundleConfiguration.stringValue(forKey: "AgentModeEnabled")?.lowercased() == "true"
    }

    private lazy var visionChatClient: any BuddyVisionChatClient = {
        BuddyVisionChatClientFactory.makeDefaultProvider()
    }()

    private lazy var ttsProvider: any BuddyTTSProvider = {
        var provider = BuddyTTSProviderFactory.makeDefaultProvider()
        // Streaming providers keep speaking after speakText() is awaited, so
        // the spinner has to be dismissed on this callback rather than when
        // speakText returns.
        provider.onPlaybackStarted = { [weak self] in
            self?.voiceState = .responding
        }
        return provider
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    /// Periodically pokes the local model servers so their GPU graphs stay
    /// resident. See `startLocalModelKeepWarmLoopIfNeeded()`.
    private var localModelKeepWarmTask: Task<Void, Never>?

    /// Live only for the duration of a streaming turn.
    private var sentenceStreamer: SpokenSentenceStreamer?

    /// When the user last spoke to Wisp.
    ///
    /// The keep-warm heartbeat is gated on this. Without a gate it pings
    /// forever, which pins six gigabytes of model in RAM from launch until
    /// quit no matter how long ago the last conversation was — on a machine
    /// the user also needs for their own work, that is most of their headroom
    /// spent on a companion sitting idle.
    private var lastInteractionAt = Date()

    /// How long after the last utterance the model is kept resident.
    ///
    /// Adaptive, because the two goals genuinely conflict. Holding the model
    /// makes the next question instant and costs six gigabytes; releasing it
    /// returns the memory and makes the next question cost a reload of several
    /// seconds. A fixed window has to pick a side, and either choice is wrong
    /// half the time — a short one punishes someone with plenty of free RAM
    /// with constant reloads, a long one squats on a machine that has none.
    ///
    /// So the answer depends on whether the memory is actually wanted. With
    /// room to spare Wisp stays warm and fast; under pressure it gets out of
    /// the way quickly, which is the situation where the user notices and
    /// minds.
    private static var keepWarmActivityWindow: TimeInterval {
        let breakdown = SystemReadouts.memoryBreakdown()
        // Same threshold the dashboard turns its memory bar amber at: past
        // this, the model starts getting evicted between turns anyway.
        return breakdown.usedFraction > 0.85 ? 90 : 10 * 60
    }

    /// Whether the model has already been released for this idle stretch, so
    /// the unload is sent once rather than every heartbeat.
    private var hasReleasedModelWhileIdle = false
    /// Set while an agent turn is running.
    ///
    /// The heartbeat and an agent loop compete for the same thing: the model
    /// server keeps a cached prompt prefix for the most recent conversation,
    /// and a heartbeat firing mid-loop displaces it. The next step of the loop
    /// then re-encodes the screenshot, which costs about six seconds and looks
    /// to the user like the assistant randomly stalling.
    private var isAgentTurnInProgress = false
    /// Watches for monitors being connected, disconnected or rearranged.
    private var screenConfigurationObserver: NSObjectProtocol?

    /// The permission prompt currently on screen, if any.
    ///
    /// Mirrored from the coordinator because the overlay observes this object
    /// and not that one, and because the window has to become clickable
    /// exactly while a prompt is up.
    @Published private(set) var pendingToolConfirmation: ToolConfirmationCoordinator.PendingConfirmation?
    private var toolConfirmationCancellable: AnyCancellable?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// Whether the cursor stays on screen when Wisp has nothing to do.
    ///
    /// Off by default, which means the cursor is invisible at rest, fades in
    /// when you hold the hotkey, points at whatever it is describing, and
    /// fades out a second after it finishes speaking.
    ///
    /// The always-on behaviour used to be the default. For an app that sits in
    /// the menu bar all day that is a mark trailing the pointer through every
    /// unrelated task, which is noise the rest of the time — the cursor should
    /// earn its place on screen by having something to say.
    @Published var isCursorAlwaysVisible: Bool =
        UserDefaults.standard.bool(forKey: "isCursorAlwaysVisible")

    func setCursorAlwaysVisible(_ enabled: Bool) {
        isCursorAlwaysVisible = enabled
        UserDefaults.standard.set(enabled, forKey: "isCursorAlwaysVisible")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether every permission has been granted at some point.
    ///
    /// This is the one job the old onboarding flag did that still matters:
    /// distinguishing a first run, where the panel explains what the app wants
    /// and why, from a later run where a permission was revoked and the right
    /// message is simply to grant it back.
    var hasEverHadAllPermissions: Bool {
        get { UserDefaults.standard.bool(forKey: "hasEverHadAllPermissions") }
        set { UserDefaults.standard.set(newValue, forKey: "hasEverHadAllPermissions") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Wisp start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        startPermissionPolling()
        // The registry asks permission itself now, so the broker needs its own
        // way to speak rather than receiving one per call.
        ToolConfirmationCoordinator.shared.installSpeechHandler { [weak self] question in
            try? await self?.ttsProvider.speakText(question)
        }
        startLocalModelKeepWarmLoopIfNeeded()
        observeScreenConfigurationChanges()
        observeToolConfirmations()
        registerBackgroundWorkTool()
        connectMCPServersIfAgentModeEnabled()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the vision chat client so Claude's TLS warmup
        // handshake (if applicable) completes well before the first
        // demo fires at ~40s into the video.
        _ = visionChatClient

        // If all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if allPermissionsGranted {
            hasEverHadAllPermissions = true
        }

        if allPermissionsGranted && isCursorAlwaysVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        activeAnnotationsByDisplayFrame.removeAll()
        annotationScreenshotSizeByDisplayFrame.removeAll()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        localModelKeepWarmTask?.cancel()
        localModelKeepWarmTask = nil
        if let screenConfigurationObserver {
            NotificationCenter.default.removeObserver(screenConfigurationObserver)
            self.screenConfigurationObserver = nil
        }
        // Child processes must be terminated explicitly; nothing else will
        // reap them when the app goes away.
        MCPManager.shared.disconnectAll()
        ToolConfirmationCoordinator.shared.cancelPending()
        toolConfirmationCancellable?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            WispAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            WispAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            WispAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            WispAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    WispAnalytics.trackPermissionGranted(permission: "screen_content")

                    // Show the cursor overlay now
                    if allPermissionsGranted {
                        hasEverHadAllPermissions = true
                    }

                    if allPermissionsGranted && !isOverlayVisible && isCursorAlwaysVisible {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    /// Whether the hold in progress is dictation rather than a question.
    ///
    /// Captured at press time so the finished transcript is routed the way the
    /// user meant when they started speaking. Published because the overlay has
    /// to show which mode is active: the two look identical otherwise, and the
    /// whole design rests on one extra modifier changing what happens to your
    /// words — which is exactly the moment feedback matters.
    @Published private(set) var isDictatingIntoFocusedField = false

    /// Where dictated text will land, captured when the hold starts.
    ///
    /// Shown while listening because "I thought I was in Slack" is the other
    /// way this goes wrong, and it is only recoverable before you speak.
    @Published private(set) var dictationDestinationName = ""

    /// A screenshot taken while the user was speaking, waiting to be claimed.
    private var speculativeScreenCaptureTask: Task<[CompanionScreenCapture], Error>?

    /// Begins capturing during speech so the transcript does not have to wait.
    private func startSpeculativeScreenCapture() {
        speculativeScreenCaptureTask?.cancel()
        speculativeScreenCaptureTask = Task {
            try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        }
    }

    /// The speculative capture if one is ready, otherwise a fresh one.
    ///
    /// Falls back rather than failing: a cancelled or errored prefetch should
    /// cost the old latency, never the answer.
    private func claimScreenCaptures() async throws -> [CompanionScreenCapture] {
        if let task = speculativeScreenCaptureTask {
            speculativeScreenCaptureTask = nil
            if let captures = try? await task.value, !captures.isEmpty {
                return captures
            }
        }
        return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed(let mode):
            guard !buddyDictationManager.isDictationInProgress else { return }
            isDictatingIntoFocusedField = (mode == .dictation)
            if isDictatingIntoFocusedField {
                dictationDestinationName = DictatedTextInserter.frontmostApplicationName()
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isCursorAlwaysVisible && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .wispDismissPanel, object: nil)

            // Normally a new utterance replaces whatever was in flight. The
            // exception is a turn paused on a confirmation: that turn is
            // precisely what the user is about to answer, so cancelling it
            // would discard the thing their "yes" belongs to. Only the audio
            // is stopped, so the question isn't still playing while they talk.
            if ToolConfirmationCoordinator.shared.isAwaitingConfirmation {
                ttsProvider.stopPlayback()
            } else {
                currentResponseTask?.cancel()
                ttsProvider.stopPlayback()
                clearDetectedElementLocation()
            }

    

            WispAnalytics.trackPushToTalkStarted()
            PerfMetricsRecorder.shared.beginPhase(.transcription)

            // Capture while the user is still talking. A screenshot costs
            // 170-240ms, and taking it after they finish spends that where
            // they are waiting; taken now it overlaps speech and is already
            // sitting there when the transcript lands. Speculative, because
            // whether the question needs a screenshot is not known until the
            // words exist — but an unused capture costs nothing the user can
            // perceive, and the screen it records is the one they were looking
            // at when they started asking, which is the more faithful moment
            // anyway.
            startSpeculativeScreenCapture()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        PerfMetricsRecorder.shared.endPhase(.transcription)
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")

                        // If the assistant is waiting on a yes or no, this is
                        // the answer to that — not a new request. Routing it
                        // here is what makes the whole exchange work by voice.
                        if ToolConfirmationCoordinator.shared.handleSpokenResponse(finalTranscript) {
                            print("✅ Treated as answer to a pending confirmation")
                            return
                        }

                        WispAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .modeChanged(let mode):
            // Shift landed just after the chord. Only the routing of the final
            // transcript depends on this, and that decision has not been made
            // yet, so updating mid-hold is safe — and it is what makes holding
            // all three keys work at human speed.
            isDictatingIntoFocusedField = (mode == .dictation)
            if isDictatingIntoFocusedField, dictationDestinationName.isEmpty {
                dictationDestinationName = DictatedTextInserter.frontmostApplicationName()
            }

        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            WispAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're wisp, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Puts a dictated transcript into whatever field has focus.
    ///
    /// Recorded in the dashboard like any other turn, because "where did that
    /// text go" is a question people ask, and silent insertion into the wrong
    /// app is otherwise untraceable.
    private func insertDictatedTranscript(_ transcript: String) {
        let destination = DictatedTextInserter.frontmostApplicationName()
        let taskID = AgentTaskRegistry.shared.beginTask(title: "Dictation → \(destination)")

        let method = DictatedTextInserter.insert(transcript)

        switch method {
        case .accessibility, .paste:
            AgentTaskRegistry.shared.appendStep(
                AgentStepRecord(
                    kind: .tool(name: "dictation"),
                    summary: "Inserted \(transcript.count) characters into \(destination)"
                ),
                to: taskID
            )
            AgentTaskRegistry.shared.finishTask(taskID, status: .succeeded, finalText: transcript)

        case .failed:
            // Said aloud rather than only logged: the user is looking at the
            // field they expected text to appear in, and silence there is
            // indistinguishable from the app having missed the whole utterance.
            AgentTaskRegistry.shared.finishTask(
                taskID, status: .failed("No editable field had focus.")
            )
            currentResponseTask = Task { [weak self] in
                guard let self else { return }
                try? await self.ttsProvider.speakText("i couldn't find a text field to type into.")
                if !Task.isCancelled { self.voiceState = .idle }
            }
            return
        }

        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        ttsProvider.stopPlayback()

        // Dictation never reaches the model. The user asked for their words in
        // a text field, not for an answer, so there is nothing to think about
        // and nothing to say back — the text appearing is the whole response.
        if isDictatingIntoFocusedField {
            isDictatingIntoFocusedField = false
            insertDictatedTranscript(transcript)
            return
        }

        // Record this interaction for the dashboard. Today a turn is a single
        // model call, so it's a one-step task; the shape already matches what
        // multi-step tool calling will need.
        // Marks the conversation live, which is what keeps the model resident.
        lastInteractionAt = Date()
        hasReleasedModelWhileIdle = false

        // Requests that need no model at all are answered here, before anything
        // expensive starts. "Open Safari" is not a question, and routing it
        // through a 7B model costs seconds to produce a sentence nobody asked
        // for. The router declines anything it is not certain about, so the
        // cost of it being wrong is one ordinary model round-trip.
        if let fastOutcome = FastCommandRouter.handle(transcript) {
            let fastTaskID = AgentTaskRegistry.shared.beginTask(title: transcript)
            AgentTaskRegistry.shared.appendStep(
                AgentStepRecord(kind: .modelCall, summary: "Handled natively — no model call"),
                to: fastTaskID
            )
            AgentTaskRegistry.shared.finishTask(
                fastTaskID, status: .succeeded, finalText: fastOutcome.spokenConfirmation
            )
            PerfMetricsRecorder.shared.abandonTurn()

            conversationHistory.append((userTranscript: transcript,
                                        assistantResponse: fastOutcome.spokenConfirmation))
            voiceState = .responding
            currentResponseTask = Task { [weak self] in
                guard let self else { return }
                try? await self.ttsProvider.speakText(fastOutcome.spokenConfirmation)
                if !Task.isCancelled {
                    self.voiceState = .idle
                    self.scheduleTransientHideIfNeeded()
                }
            }
            return
        }

        let taskID = AgentTaskRegistry.shared.beginTask(title: transcript)
        PerfMetricsRecorder.shared.beginTurn(transcript: transcript, modelName: ActiveStackReadout.shared.chatModelName)
        // Whether the screenshot gets attached is the single biggest factor in
        // how long a turn takes, so timings are only comparable between turns
        // that made the same choice. Reuses the client's own predicate rather
        // than restating the rule.
        let isUsingLocalChat = AppBundleConfiguration
            .stringValue(forKey: "ChatProvider")?.lowercased() == "ollama"
        PerfMetricsRecorder.shared.recordScreenshotDecision(
            didAttach: !isUsingLocalChat || LocalOllamaAPI.promptLikelyRefersToScreen(transcript)
        )

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                PerfMetricsRecorder.shared.beginPhase(.screenCapture)
                let screenCaptures = try await claimScreenCaptures()
                PerfMetricsRecorder.shared.endPhase(.screenCapture)

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                PerfMetricsRecorder.shared.beginPhase(.chat)
                PerfMetricsRecorder.shared.beginPhase(.firstToken)

                let fullResponseText: String
                if Self.isAgentModeEnabled {
                    // Tools are in play, so the reply may take several model
                    // calls. Hold off the keep-warm heartbeat for the duration
                    // — see `isAgentTurnInProgress`.
                    isAgentTurnInProgress = true
                    defer { isAgentTurnInProgress = false }

                    let runner = AgentTurnRunner(
                        chatClient: visionChatClient,
                        speakConfirmation: { [weak self] question in
                            guard let self else { return }
                            try? await self.ttsProvider.speakText(question)
                        }
                    )
                    let outcome = try await runner.run(
                        userText: transcript,
                        images: labeledImages,
                        systemPrompt: Self.companionVoiceResponseSystemPrompt
                            + ScreenAnnotationParser.promptInstructions,
                        conversationHistory: historyForAPI,
                        onNarration: { narration in
                            print("💭 \(narration)")
                        },
                        onStep: { step in
                            AgentTaskRegistry.shared.appendStep(step, to: taskID)
                        }
                    )
                    fullResponseText = outcome.terminalText
                } else {
                    AgentTaskRegistry.shared.appendStep(
                        AgentStepRecord(kind: .modelCall, summary: "Asking \(ActiveStackReadout.shared.chatModelName)"),
                        to: taskID
                    )

                    // Speech begins mid-generation when the provider can
                    // queue fragments. Pointing and annotation tags are still
                    // parsed from the complete reply afterwards — the streamer
                    // only decides what is spoken, never what is understood.
                    let isSpeakingIncrementally = ttsProvider.supportsIncrementalSpeech
                    if isSpeakingIncrementally {
                        var hasStartedSpeaking = false
                        sentenceStreamer = SpokenSentenceStreamer { [weak self] sentence in
                            guard let self else { return }
                            if !hasStartedSpeaking {
                                hasStartedSpeaking = true
                                self.voiceState = .responding
                                PerfMetricsRecorder.shared.endPhase(.textToSpeechFirstSentence)
                            }
                            self.ttsProvider.speakIncremental(sentence)
                        }
                    }

                    // Through the gate even for a single call, so background
                    // work can never land between this request and the reply
                    // the user is waiting for.
                    let (responseText, chatDuration) = try await ModelAccessGate.shared.withAccess(
                        priority: .interactive
                    ) {
                        try await visionChatClient.analyzeImageStreaming(
                            images: labeledImages,
                            systemPrompt: Self.companionVoiceResponseSystemPrompt
                                + ScreenAnnotationParser.promptInstructions,
                            conversationHistory: historyForAPI,
                            userPrompt: transcript,
                            onTextChunk: { [weak self] chunk in
                                // First token ends the wait the user actually
                                // perceives, whatever generation does after.
                                PerfMetricsRecorder.shared.endPhaseOnce(.firstToken)
                                // Speak each sentence the moment it is complete
                                // rather than waiting for the whole reply. This
                                // is the difference between the first word
                                // arriving in about a second and in about
                                // seven.
                                self?.sentenceStreamer?.append(chunk)
                            }
                        )
                    }
                    AgentTaskRegistry.shared.updateLastStep(of: taskID) { step in
                        step.durationSeconds = chatDuration
                    }
                    fullResponseText = responseText
                }

                PerfMetricsRecorder.shared.endPhase(.chat)

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                // Annotations are pulled out first so their tags are gone
                // before the pointing parser looks for a trailing tag.
                let annotationResult = ScreenAnnotationParser.parse(fullResponseText)
                if !annotationResult.annotations.isEmpty {
                    applyAnnotations(annotationResult.annotations, from: screenCaptures)
                }

                let parseResult = Self.parsePointingCoordinates(from: annotationResult.spokenText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    WispAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                WispAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        // Measures time to the FIRST audible sentence, not the
                        // whole reply — that's the latency the user feels.
                        PerfMetricsRecorder.shared.beginPhase(.textToSpeechFirstSentence)
                        var hasRecordedFirstAudio = false
                        ttsProvider.onPlaybackStarted = { [weak self] in
                            self?.voiceState = .responding
                            if !hasRecordedFirstAudio {
                                hasRecordedFirstAudio = true
                                PerfMetricsRecorder.shared.endPhase(.textToSpeechFirstSentence)
                            }
                        }

                        if let streamer = sentenceStreamer {
                            // Already speaking. Flush the trailing fragment and
                            // wait for the queue rather than re-speaking a reply
                            // the user has mostly heard.
                            streamer.finish()
                            sentenceStreamer = nil
                            await ttsProvider.waitForPlaybackToFinish()
                        } else {
                            // voiceState flips to .responding via
                            // onPlaybackStarted as soon as the first audio is
                            // audible; this await covers the full reply.
                            try await ttsProvider.speakText(spokenText)
                        }
                    } catch {
                        WispAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error: \(error)")
                        speakLocalFailureFallback()
                    }
                }

                AgentTaskRegistry.shared.finishTask(taskID, status: .succeeded, finalText: spokenText)
                PerfMetricsRecorder.shared.completeTurn()
            } catch is CancellationError {
                sentenceStreamer = nil
                // User spoke again — response was interrupted. Any prompt this
                // turn was waiting on goes with it, so nothing is left asking
                // about a request that no longer exists.
                ToolConfirmationCoordinator.shared.cancelPending()
                AgentTaskRegistry.shared.finishTask(taskID, status: .cancelled)
                PerfMetricsRecorder.shared.abandonTurn()
            } catch {
                sentenceStreamer = nil
                WispAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                AgentTaskRegistry.shared.finishTask(taskID, status: .failed(error.localizedDescription))
                PerfMetricsRecorder.shared.completeTurn()
                speakLocalFailureFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Keeps the local Ollama and Chatterbox servers warm while Wisp is
    /// running.
    ///
    /// Both back ends lose their compiled GPU graphs after a few idle
    /// minutes, and rebuilding them is the single largest source of latency
    /// the user actually feels: measured on an M3 Pro, one short sentence
    /// costs about 9 seconds to synthesize cold versus about 1.5 seconds
    /// warm. Because the penalty lands on the first request after a pause,
    /// it hits real conversations constantly while never showing up in
    /// back-to-back testing.
    ///
    /// The heartbeat is deliberately cheap: Ollama is refreshed with a
    /// zero-token request that only resets its keep-alive timer, and
    /// Chatterbox synthesizes a single word. Failures are ignored — a
    /// server that isn't running simply gets warmed once it is.
    private func startLocalModelKeepWarmLoopIfNeeded() {
        let isUsingLocalChat = AppBundleConfiguration
            .stringValue(forKey: "ChatProvider")?.lowercased() == "ollama"
        let isUsingLocalTTS = AppBundleConfiguration
            .stringValue(forKey: "VoiceTTSProvider")?.lowercased() == "chatterbox"
        guard isUsingLocalChat || isUsingLocalTTS else { return }

        let ollamaBaseURL = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL")
            ?? "http://localhost:11434"
        let ollamaModel = AppBundleConfiguration.stringValue(forKey: "OllamaModel")
            ?? "qwen2.5vl:7b"
        let chatterboxBaseURL = AppBundleConfiguration.stringValue(forKey: "ChatterboxTTSServerURL")
            ?? "http://localhost:8004"
        let chatterboxVoiceID = AppBundleConfiguration.stringValue(forKey: "ChatterboxVoiceID")
            ?? "Emily.wav"

        // Comfortably shorter than the idle window that causes eviction.
        let keepWarmIntervalSeconds: UInt64 = 90

        localModelKeepWarmTask?.cancel()
        localModelKeepWarmTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: keepWarmIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }

                // Skip entirely while a turn is in flight. A heartbeat sent
                // mid-conversation evicts that conversation's cached prompt
                // prefix, and the next step pays to re-encode the screenshot.
                // A turn is itself the best possible keep-warm anyway.
                let shouldSkipThisBeat = await MainActor.run { () -> Bool in
                    guard let manager = self else { return true }
                    // Mid-turn: a heartbeat would evict the prompt prefix this
                    // conversation is relying on, and a turn keeps the model
                    // warm by itself anyway.
                    if manager.isAgentTurnInProgress { return true }
                    let idleFor = Date().timeIntervalSince(manager.lastInteractionAt)
                    return idleFor > CompanionManager.keepWarmActivityWindow
                }

                if shouldSkipThisBeat {
                    // Idle. Simply not pinging would leave the model resident
                    // until Ollama's own timer expires, which is minutes of
                    // holding six gigabytes after the user has plainly stopped
                    // using it. Ask for it to be dropped now instead — once
                    // per idle stretch, not every beat.
                    let releaseDecision = await MainActor.run { () -> (shouldRelease: Bool, afterMinutes: Int) in
                        let window = CompanionManager.keepWarmActivityWindow
                        guard let manager = self, isUsingLocalChat else { return (false, 0) }
                        guard !manager.isAgentTurnInProgress else { return (false, 0) }
                        let idleFor = Date().timeIntervalSince(manager.lastInteractionAt)
                        guard idleFor > window, !manager.hasReleasedModelWhileIdle else { return (false, 0) }
                        manager.hasReleasedModelWhileIdle = true
                        return (true, Int(window / 60))
                    }
                    let shouldRelease = releaseDecision.shouldRelease

                    if shouldRelease {
                        await Self.sendKeepWarmRequest(
                            to: "\(ollamaBaseURL)/api/chat",
                            body: [
                                "model": ollamaModel,
                                "stream": false,
                                // Zero means unload now.
                                "keep_alive": 0,
                                "options": ["num_predict": 0],
                                "messages": [["role": "user", "content": "."]]
                            ]
                        )
                        print("💤 Released the model — idle for over \(releaseDecision.afterMinutes) min")
                    }
                    continue
                }

                if isUsingLocalChat {
                    await Self.sendKeepWarmRequest(
                        to: "\(ollamaBaseURL)/api/chat",
                        body: [
                            "model": ollamaModel,
                            "stream": false,
                            // Both of these must match what a real turn sends.
                            // keep_alive because the shortest value wins, and
                            // num_ctx because Ollama reloads the model — about
                            // six seconds — whenever it changes. Omitting
                            // num_ctx here meant the heartbeat ran at the model
                            // default and evicted the very model it was meant
                            // to hold resident, so the next turn paid one
                            // reload for the heartbeat and another for itself.
                            "keep_alive": LocalOllamaAPI.modelResidencyWindow,
                            "options": [
                                "num_ctx": LocalOllamaAPI.activeContextWindowTokens,
                                "num_predict": 0
                            ],
                            "messages": [["role": "user", "content": "."]]
                        ]
                    )
                }

                if isUsingLocalTTS {
                    await Self.sendKeepWarmRequest(
                        to: "\(chatterboxBaseURL)/v1/audio/speech",
                        body: [
                            "model": "tts-1",
                            "input": "ok",
                            "voice": chatterboxVoiceID,
                            "response_format": "wav"
                        ]
                    )
                }
            }
        }
    }

    private static func sendKeepWarmRequest(to urlString: String, body: [String: Any]) async {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// If the cursor is in transient mode (user toggled "Show Wisp" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isCursorAlwaysVisible && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while ttsProvider.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a spoken diagnostic when a turn fails.
    ///
    /// This used to announce that it was out of API credits and ask the user
    /// to message the original author. There are no credits in a local build,
    /// so the one time it actually fired — a disk full enough to break audio
    /// synthesis — it sent the user looking for a billing problem that could
    /// not exist, and at a person with no connection to this machine.
    ///
    /// What is worth saying instead is the thing that is almost always true
    /// when a local turn fails: one of the two services is not running. This
    /// checks which, rather than guessing, because "Ollama isn't running" and
    /// "something went wrong" are very different amounts of help.
    ///
    /// Deliberately NSSpeechSynthesizer rather than the configured provider —
    /// this path exists precisely for when that provider is the thing that
    /// failed.
    private func speakLocalFailureFallback() {
        Task { [weak self] in
            let isModelReachable = await Self.isLocalServiceReachable(
                AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL")
                    ?? "http://localhost:11434"
            )

            let utterance = isModelReachable
                ? "Something went wrong answering that. Check the dashboard for details."
                : "I can't reach the local model. Make sure Ollama is running."

            await MainActor.run {
                guard let self else { return }
                let synthesizer = NSSpeechSynthesizer()
                synthesizer.startSpeaking(utterance)
                self.voiceState = .responding
            }
        }
    }

    /// Whether a local service answers at all. Short timeout: this runs while
    /// the user is already waiting on a turn that failed.
    private static func isLocalServiceReachable(_ baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// Mirrors permission prompts into this object and makes the overlay
    /// clickable while one is showing.
    ///
    /// The overlay is click-through by default and has to stay that way — it
    /// covers the screen above almost everything, so any moment it accepts
    /// mouse events is a moment the desktop underneath does not. Interactivity
    /// is therefore switched on for exactly as long as there is something to
    /// click, and off again immediately after.
    private func observeToolConfirmations() {
        toolConfirmationCancellable = ToolConfirmationCoordinator.shared
            .$pendingConfirmation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] confirmation in
                guard let self else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    self.pendingToolConfirmation = confirmation
                }
                self.overlayWindowManager.setAcceptsMouseEvents(confirmation != nil)

                // A prompt is worth seeing even when the cursor is set to stay
                // hidden, since otherwise there is nothing to click.
                if confirmation != nil, !self.isOverlayVisible {
                    self.overlayWindowManager.hasShownOverlayBefore = true
                    self.overlayWindowManager.showOverlay(
                        onScreens: NSScreen.screens,
                        companionManager: self
                    )
                    self.isOverlayVisible = true
                    // The windows were just rebuilt, so re-apply.
                    self.overlayWindowManager.setAcceptsMouseEvents(true)
                }
            }
    }

    /// Registers the tool that lets the assistant hand slow work to the
    /// background.
    ///
    /// Registered here rather than alongside the other built-in tools because
    /// running one needs the chat client and the speech provider this object
    /// owns.
    private func registerBackgroundWorkTool() {
        guard Self.isAgentModeEnabled else { return }

        AgentToolRegistry.shared.register(
            BuddyToolDefinition(
                name: "do_in_background",
                description: "Hand a slow request off to run in the background and notify the user when it's done, instead of making them wait. Use for anything that needs several steps.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "request": .object([
                            "type": .string("string"),
                            "description": .string("What to work on, written so it stands alone.")
                        ])
                    ]),
                    "required": .array([.string("request")])
                ]),
                // The only tool here that starts work which then runs
                // unattended: it survives the next utterance, keeps calling the
                // model on its own, and reports back by notification. The three
                // read-only tools answer a question and stop, which is why they
                // do not ask. This one should.
                requiresConfirmation: true
            )
        ) { [weak self] input in
            guard let self else { return "couldn't start that." }
            guard case .object(let arguments) = input,
                  case .string(let request)? = arguments["request"],
                  !request.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "i need to know what to work on."
            }

            guard BackgroundTaskLauncher.canStartAnotherTask else {
                return "there are already too many background tasks running. tell the user to wait for one to finish."
            }

            BackgroundTaskLauncher.start(
                request: request,
                chatClient: self.visionChatClient,
                systemPrompt: Self.companionVoiceResponseSystemPrompt,
                speakConfirmation: { [weak self] question in
                    guard let self else { return }
                    try? await self.ttsProvider.speakText(question)
                }
            )

            return "started working on that in the background. tell the user briefly that you'll let them know when it's done."
        }
    }

    /// Starts any configured MCP servers.
    ///
    /// Only when agent mode is on: their tools are unusable otherwise, and
    /// each server is a child process, so starting them for nothing would cost
    /// memory on a machine that has little to spare.
    ///
    /// Runs detached from startup because a server can take seconds to come
    /// up — often downloading itself through npx first — and none of that
    /// should delay the assistant becoming usable.
    private func connectMCPServersIfAgentModeEnabled() {
        guard Self.isAgentModeEnabled else { return }

        Task {
            MCPManager.shared.createExampleConfigurationIfMissing()
            await MCPManager.shared.connectConfiguredServers()
        }
    }

    /// Rebuilds the overlays when the display setup changes.
    ///
    /// One overlay window is created per screen at the moment the overlay is
    /// shown, and nothing rebuilt them afterwards — so plugging in, unplugging
    /// or rearranging a monitor left the cursor and any annotations stranded
    /// on a layout that no longer exists. Annotations are dropped rather than
    /// remapped, since they describe positions on a screen arrangement that
    /// has just changed.
    private func observeScreenConfigurationChanges() {
        screenConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Frames captured from a display that has since changed
                // resolution are not comparable to anything, so the reuse
                // cache is dropped regardless of overlay state.
                ScreenshotReuseCache.invalidateAll()

                guard let self, self.isOverlayVisible else { return }

                self.clearDetectedElementLocation()
                self.overlayWindowManager.hasShownOverlayBefore = true
                self.overlayWindowManager.showOverlay(
                    onScreens: NSScreen.screens,
                    companionManager: self
                )
                print("🖥️ Screen layout changed — overlays rebuilt for \(NSScreen.screens.count) screen(s)")
            }
        }
    }

    // MARK: - Annotations

    /// Routes parsed annotations to the screens they belong to.
    ///
    /// The model refers to screens the same way it does for pointing — by the
    /// 1-based number in each image's label — and omits the number when it
    /// means the screen the cursor is on.
    private func applyAnnotations(
        _ annotations: [ScreenAnnotation],
        from screenCaptures: [CompanionScreenCapture]
    ) {
        guard !screenCaptures.isEmpty else { return }

        let cursorScreenIndex = screenCaptures.firstIndex(where: \.isCursorScreen) ?? 0

        var annotationsByDisplay: [CGRect: [ScreenAnnotation]] = [:]
        var screenshotSizes: [CGRect: CGSize] = [:]

        for annotation in annotations {
            let captureIndex: Int
            if let screenNumber = annotation.screenNumber,
               screenNumber >= 1, screenNumber <= screenCaptures.count {
                captureIndex = screenNumber - 1
            } else {
                captureIndex = cursorScreenIndex
            }

            let capture = screenCaptures[captureIndex]

            annotationsByDisplay[capture.displayFrame, default: []].append(annotation)
            screenshotSizes[capture.displayFrame] = CGSize(
                width: CGFloat(capture.screenshotWidthInPixels),
                height: CGFloat(capture.screenshotHeightInPixels)
            )
        }

        annotationScreenshotSizeByDisplayFrame = screenshotSizes
        activeAnnotationsByDisplayFrame = annotationsByDisplay

        let summary = annotations.map { "\($0.style.rawValue)(\($0.label ?? "—"))" }.joined(separator: ", ")
        print("🖍️ Annotations: \(summary)")
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }
}
