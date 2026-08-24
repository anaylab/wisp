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

    private init() {}

    // MARK: - Configured stack

    /// The chat model actually in use.
    ///
    /// Read from configuration rather than from the old `selectedModel`
    /// property, which holds a Claude model id used only by the cloud path
    /// nothing selects.
    var chatModelName: String {
        if isUsingOllama {
            return AppBundleConfiguration.stringValue(forKey: "OllamaModel") ?? "unknown"
        }
        return AppBundleConfiguration.stringValue(forKey: "ClaudeModel") ?? "claude"
    }

    var chatProviderName: String {
        isUsingOllama ? "Ollama · local" : "Claude · cloud"
    }

    var speechProviderName: String {
        switch AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider")?.lowercased() {
        case "apple": return "Apple Speech · on-device"
        case "fluidaudio", "parakeet": return "Parakeet · on-device"
        case "openai": return "OpenAI · cloud"
        case "assemblyai": return "AssemblyAI · cloud"
        case let other?: return other
        case nil: return "unknown"
        }
    }

    var voiceProviderName: String {
        switch AppBundleConfiguration.stringValue(forKey: "VoiceTTSProvider")?.lowercased() {
        case "chatterbox": return "Chatterbox · local"
        case "apple": return "Apple voice · on-device"
        case "elevenlabs": return "ElevenLabs · cloud"
        case let other?: return other
        case nil: return "unknown"
        }
    }

    /// Whether every stage runs on this machine.
    ///
    /// Drives the panel's assurance line, which should reflect what is
    /// configured rather than assert something that a changed Info.plist could
    /// quietly make untrue.
    var isEntirelyLocal: Bool {
        isUsingOllama
            && !speechProviderName.contains("cloud")
            && !voiceProviderName.contains("cloud")
    }

    private var isUsingOllama: Bool {
        AppBundleConfiguration.stringValue(forKey: "ChatProvider")?.lowercased() == "ollama"
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
