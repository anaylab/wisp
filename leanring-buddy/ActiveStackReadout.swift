//
//  ActiveStackReadout.swift
//  leanring-buddy
//
//  What Wisp is actually running, for the menu bar panel.
//
//  The panel used to offer a Sonnet/Opus picker. Nothing was behind it — the
//  app talks to a local model regardless of which was selected — so it asked
//  the user to make a choice that had no effect, and named two models that are
//  not involved. Worse, the selection leaked outward: it was what the
//  dashboard labelled its timings with and what the agent timeline printed as
//  "Asking …", so the one number-bearing surface in the app was captioned with
//  the name of a model that never ran.
//
//  A local app does not need a model picker. Changing models means editing
//  Info.plist and rebuilding, and offering a runtime switch would imply an
//  ability that does not exist. What is genuinely useful in that space is the
//  opposite: a statement of what is loaded right now, and whether it is warm.
//  Residency is the single best predictor of how long the next question takes.
//

import Combine
import Foundation

@MainActor
final class ActiveStackReadout: ObservableObject {
    static let shared = ActiveStackReadout()

    @Published private(set) var residency: SystemReadouts.ModelResidency = .notLoaded

    private var pollingTask: Task<Void, Never>?
    private var speechModelStateSubscription: AnyCancellable?

    private init() {
        // The Speech and Voice rows read the FluidAudio models' load state, so
        // a download finishing (or failing) re-renders them.
        speechModelStateSubscription = FluidAudioSpeechModels.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // The provider (and the Claude model) are chosen at runtime in
        // Settings → Model and live in UserDefaults, so the readout re-renders
        // when they change rather than showing the model that was selected at
        // launch.
        // UserDefaults posts this for every write in the process, so only a
        // change to what the readout shows re-renders it.
        providerSelectionSubscription = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let currentSelectionSummary = "\(self.selectedChatProviderKind.rawValue)|\(self.chatModelName)"
                    guard currentSelectionSummary != self.lastShownSelectionSummary else { return }
                    self.lastShownSelectionSummary = currentSelectionSummary
                    self.objectWillChange.send()
                }
            }
    }

    private var lastShownSelectionSummary = ""

    private var providerSelectionSubscription: AnyCancellable?

    // MARK: - Configured stack

    /// The backend answering turns right now — the runtime selection, not the
    /// shipped Info.plist default.
    var selectedChatProviderKind: BuddyChatProviderKind { BuddyChatProviderSelection.current }

    /// The chat model actually in use. This used to be the Info.plist Ollama
    /// model whatever was selected, so the window's status pill, the History
    /// "Asking …" step and the timing labels all named a local model while a
    /// Claude turn ran.
    var chatModelName: String {
        switch selectedChatProviderKind {
        case .localOllama:
            return AppBundleConfiguration.stringValue(forKey: "OllamaModel") ?? "unknown"
        case .appleOnDevice:
            return "Apple system model"
        case .anthropic, .claudeSubscription:
            return AnthropicModelSettings.selectedModel.displayName
        case .openAI:
            return OpenAIProvider.defaultModelName
        case .gemini:
            return GeminiProvider.defaultModelName
        }
    }

    var chatProviderName: String {
        switch selectedChatProviderKind {
        case .localOllama: return "Ollama · local"
        case .appleOnDevice: return "Apple · on-device"
        default: return selectedChatProviderKind.displayName
        }
    }

    /// Whether the chat model lives on this Mac. Ollama residency (loaded,
    /// cold, unreachable) says nothing about a cloud model, so the readouts
    /// show it only when this is true.
    var isChatModelLocal: Bool { !selectedChatProviderKind.sendsScreenshotsOffThisMachine }

    var speechProviderName: String {
        guard BuddyTranscriptionProviderFactory.isParakeetConfigured else {
            return "Apple Speech · on-device"
        }
        return Self.fluidAudioModelDescription(
            modelName: "Parakeet",
            fallbackName: "Apple Speech",
            loadState: FluidAudioSpeechModels.shared.speechRecognitionLoadState
        )
    }

    var voiceProviderName: String {
        if BuddyTTSProviderFactory.isKokoroConfigured {
            return Self.fluidAudioModelDescription(
                modelName: "Kokoro",
                fallbackName: "Apple voice",
                loadState: FluidAudioSpeechModels.shared.speechSynthesisLoadState
            )
        }
        switch AppBundleConfiguration.stringValue(forKey: "VoiceTTSProvider")?.lowercased() {
        case "chatterbox": return "Chatterbox · local"
        case "apple": return "Apple voice · on-device"
        case let other?: return other
        case nil: return "unknown"
        }
    }

    /// "Parakeet · on-device" once the model is loaded; until then (or if it
    /// failed) names the Apple engine actually doing the work, so the row
    /// never claims a model that isn't running.
    private static func fluidAudioModelDescription(
        modelName: String,
        fallbackName: String,
        loadState: FluidAudioModelLoadState
    ) -> String {
        switch loadState {
        case .ready:
            return "\(modelName) · on-device"
        case .failed:
            return "\(fallbackName) · on-device (\(modelName) failed to load)"
        case .notStarted, .downloading, .loading:
            return "\(fallbackName) · on-device (\(modelName) \(loadState.shortStatusDescription))"
        }
    }

    /// Whether every stage runs on this machine.
    ///
    /// Drives the panel's assurance line, which should reflect what is
    /// configured rather than assert something that a changed Info.plist could
    /// quietly make untrue.
    /// False while a cloud chat provider is selected — screenshots and the
    /// transcript then leave the Mac, and the assurance line must say so.
    var isEntirelyLocal: Bool {
        isChatModelLocal && !speechProviderName.contains("cloud") && !voiceProviderName.contains("cloud")
    }

    // MARK: - Live residency

    /// Polls only while the panel is open.
    ///
    /// The panel is momentary and the answer changes on the order of minutes,
    /// so a background poll running for the app's whole lifetime would be
    /// requests nobody reads.
    func startPolling() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let reading = await SystemReadouts.ollamaResidency()
                guard !Task.isCancelled else { return }
                self?.residency = reading
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
