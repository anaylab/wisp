// A compile-time stand-in for the FluidAudio package, so this suite can keep
// compiling every app source with plain swiftc (no SwiftPM checkout, no
// xcodebuild). It declares only the API surface Wisp's speech files use
// (FluidAudioSpeechModels.swift), with the same signatures as FluidAudio
// 0.15.6. Model loading throws, so anything that reaches it falls back to
// Apple's speech exactly as the app does when the models aren't ready.
//
// When those files start using more of FluidAudio, add the new declarations
// here (matching the real signatures) or the suite stops compiling.

import AVFoundation
import Foundation

public struct FluidAudioStubUnavailableError: Error, LocalizedError {
    public var errorDescription: String? { "FluidAudio is stubbed in this test build" }
}

// MARK: - Downloads

public struct DownloadProgress: Sendable {
    public let fractionCompleted: Double
    public init(fractionCompleted: Double) { self.fractionCompleted = fractionCompleted }
}

public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void

// MARK: - Parakeet ASR

public enum AsrModelVersion: Sendable {
    case v2
    case v3
}

public struct AsrModels: Sendable {
    public static func downloadAndLoad(
        to directory: URL? = nil,
        version: AsrModelVersion = .v3,
        progressHandler: ProgressHandler? = nil
    ) async throws -> AsrModels {
        throw FluidAudioStubUnavailableError()
    }
}

public struct ASRConfig: Sendable {
    public static let `default` = ASRConfig()
}

public struct TokenTiming: Sendable {}

public struct ASRResult: Sendable {
    public let text: String
    public let tokenTimings: [TokenTiming]?
}

public struct TdtDecoderState: Sendable {
    public static func make(decoderLayers: Int = 2) -> TdtDecoderState { TdtDecoderState() }
}

public enum Language: String, Sendable, CaseIterable {
    case english = "en"
}

public actor AsrManager {
    public init(config: ASRConfig = .default, models: AsrModels? = nil) {}

    public var decoderLayerCount: Int { 2 }

    public func transcribe(
        _ audioSamples: [Float],
        decoderState: inout TdtDecoderState,
        language: Language? = nil
    ) async throws -> ASRResult {
        throw FluidAudioStubUnavailableError()
    }
}

public final class AudioConverter: Sendable {
    public init() {}
    public func resample(_ samples: [Float], from inputRate: Double) throws -> [Float] { samples }
}

// MARK: - Vocabulary boosting

public enum CtcModelVariant: String, CaseIterable, Sendable {
    case ctc110m
}

public struct CtcModels: Sendable {
    public static func downloadAndLoad(
        to directory: URL? = nil,
        variant: CtcModelVariant = .ctc110m
    ) async throws -> CtcModels {
        throw FluidAudioStubUnavailableError()
    }

    public static func defaultCacheDirectory(for variant: CtcModelVariant) -> URL {
        FileManager.default.temporaryDirectory
    }
}

public final class CtcTokenizer: Sendable {
    public static func load(from modelDirectory: URL) async throws -> CtcTokenizer {
        throw FluidAudioStubUnavailableError()
    }

    public func encode(_ text: String) -> [Int] { [] }
}

public struct CustomVocabularyTerm: Sendable {
    public init(
        text: String,
        weight: Float? = nil,
        aliases: [String]? = nil,
        tokenIds: [Int]? = nil,
        ctcTokenIds: [Int]? = nil,
        minSimilarity: Float? = nil
    ) {}
}

public struct CustomVocabularyContext: Sendable {
    public init(terms: [CustomVocabularyTerm]) {}
}

public struct VocabularyRescorer: Sendable {
    public struct Config: Sendable {
        public init(
            useAdaptiveThresholds: Bool = true,
            referenceTokenCount: Int = 3,
            shortTermCbwTaperPivot: Int = 1,
            shortTermCbwTaperExponent: Float = 2.0,
            spotterRescueMinSimilarity: Float = 0,
            spotterRescueMultiWordMinSimilarity: Float = 0,
            spotterRescueEnabled: Bool = true
        ) {}
    }

    public struct RescoreOutput: Sendable {
        public let text: String
        public let wasModified: Bool
    }
}

public struct VocabularyBoostingSession: Sendable {
    public init(
        vocabulary: CustomVocabularyContext,
        ctcModels: CtcModels,
        config: VocabularyRescorer.Config? = nil
    ) async throws {
        throw FluidAudioStubUnavailableError()
    }

    public func rescore(
        text: String,
        tokenTimings: [TokenTiming],
        audioSamples: [Float]
    ) async -> VocabularyRescorer.RescoreOutput? {
        nil
    }
}

// MARK: - Kokoro TTS

public struct KokoroAneSynthesisResult: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
}

public actor KokoroAneManager {
    public init(defaultVoice: String? = nil, directory: URL? = nil) {}

    public func initialize(preloadVoices: Set<String>? = nil) async throws {
        throw FluidAudioStubUnavailableError()
    }

    public func synthesizeDetailed(
        text: String,
        voice: String? = nil,
        speed: Float = 1.0
    ) async throws -> KokoroAneSynthesisResult {
        throw FluidAudioStubUnavailableError()
    }
}
