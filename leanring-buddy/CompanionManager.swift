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

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

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
        return BuddyVisionChatClientFactory.makeDefaultProvider(
            claudeProxyURL: "\(Self.workerBaseURL)/chat",
            claudeModel: selectedModel
        )
    }()

    private lazy var ttsProvider: any BuddyTTSProvider = {
        var provider = BuddyTTSProviderFactory.makeDefaultProvider(elevenLabsProxyURL: "\(Self.workerBaseURL)/tts")
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

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    /// The Claude model id, used only by the cloud chat path that nothing
    /// currently selects. This is **not** the model in use — ask
    /// `ActiveStackReadout.shared.chatModelName` for that. Keeping the two
    /// apart matters because this value was previously what the dashboard
    /// labelled its timings with, captioning local measurements with the name
    /// of a model that never ran.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        visionChatClient.model = model
    }

    /// User preference for whether the Wisp cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    /// Storage key predates the rename and is deliberately left alone: it is
    /// invisible to the user, and changing it would silently reset the toggle
    /// for anyone who had already turned the cursor off.
    @Published var isWispCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setWispCursorEnabled(_ enabled: Bool) {
        isWispCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
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

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Records that onboarding's email step is done.
    ///
    /// This used to send the address to the original author's form and
    /// identify the user in their analytics project. Both destinations belong
    /// to whoever published the source rather than to whoever is running this
    /// build, so neither happens now: the address is only used to mark the
    /// onboarding step complete and is not stored or transmitted.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Wisp start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        startLocalModelKeepWarmLoopIfNeeded()
        observeScreenConfigurationChanges()
        observeToolConfirmations()
        registerBackgroundWorkTool()
        connectMCPServersIfAgentModeEnabled()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the vision chat client so Claude's TLS warmup
        // handshake (if applicable) completes well before the onboarding
        // demo fires at ~40s into the video.
        _ = visionChatClient

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isWispCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .wispDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        WispAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .wispDismissPanel, object: nil)
        WispAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Wisp: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Wisp: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
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
    /// so they're never asked again during onboarding.
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

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isWispCursorEnabled {
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

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isWispCursorEnabled && !isOverlayVisible {
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

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            WispAnalytics.trackPushToTalkStarted()
            PerfMetricsRecorder.shared.beginPhase(.transcription)

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

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        ttsProvider.stopPlayback()

        // Record this interaction for the dashboard. Today a turn is a single
        // model call, so it's a one-step task; the shape already matches what
        // multi-step tool calling will need.
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
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
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
                            onTextChunk: { _ in
                                // No streaming text display — spinner stays until TTS plays
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

                        // voiceState flips to .responding via onPlaybackStarted
                        // as soon as the first audio is audible; this await
                        // covers the full reply, which for streaming providers
                        // continues well past that point.
                        try await ttsProvider.speakText(spokenText)
                    } catch {
                        WispAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }

                AgentTaskRegistry.shared.finishTask(taskID, status: .succeeded, finalText: spokenText)
                PerfMetricsRecorder.shared.completeTurn()
            } catch is CancellationError {
                // User spoke again — response was interrupted. Any prompt this
                // turn was waiting on goes with it, so nothing is left asking
                // about a request that no longer exists.
                ToolConfirmationCoordinator.shared.cancelPending()
                AgentTaskRegistry.shared.finishTask(taskID, status: .cancelled)
                PerfMetricsRecorder.shared.abandonTurn()
            } catch {
                WispAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                AgentTaskRegistry.shared.finishTask(taskID, status: .failed(error.localizedDescription))
                PerfMetricsRecorder.shared.completeTurn()
                speakCreditsErrorFallback()
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
                let shouldSkipThisBeat = await MainActor.run { self?.isAgentTurnInProgress ?? false }
                if shouldSkipThisBeat { continue }

                if isUsingLocalChat {
                    await Self.sendKeepWarmRequest(
                        to: "\(ollamaBaseURL)/api/chat",
                        body: [
                            "model": ollamaModel,
                            "stream": false,
                            "keep_alive": "10m",
                            "options": ["num_predict": 0],
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
        guard !isWispCursorEnabled && isOverlayVisible else { return }

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

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
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

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Wisp flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            WispAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            WispAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
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

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're wisp, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await visionChatClient.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    conversationHistory: [],
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
