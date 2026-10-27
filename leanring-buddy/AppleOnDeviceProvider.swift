//
//  AppleOnDeviceProvider.swift
//  leanring-buddy
//
//  Presents Apple's on-device system language model (the FoundationModels
//  framework) as a `ModelProvider`.
//
//  Like `OllamaProvider` this is a translator and nothing else. It does not use
//  the framework's own `Tool` protocol: a `LanguageModelSession` runs the tools
//  it is given by itself, in the middle of a response, which would let a call
//  skip `AgentToolRegistry.invoke` and its approval prompts. Tools are instead
//  offered as the same `[TOOL:name:{…}]` prompt text the local model uses and
//  recovered by parsing the reply, so the runtime above sees ordinary `toolUse`
//  blocks and the confirmation boundary is unchanged.
//
//  Everything stays on this Mac. `PrivateCloudComputeLanguageModel` (macOS 27's
//  off-device model) is deliberately not used here: it would send screenshots
//  and transcripts off the machine and would need its own provider kind,
//  labelled as such.
//
//  Measured on an M3 Pro (macOS 27): a new 896px screenshot answers in about
//  1-2s warm, a short question about it in under a second. The context window
//  is small (8192 tokens including the reply), so a long system prompt, memory
//  and brain context can overflow it; that surfaces as `contextWindowExceeded`.
//

import Foundation
import FoundationModels
import ImageIO

final class AppleOnDeviceProvider: ModelProvider, Sendable {
    /// The framework's published window for the on-device model, used when the
    /// running OS cannot report it. The real value is read live where possible.
    static let fallbackContextWindowTokens = 8192

    /// How many earlier messages are replayed as text. The window is small, so
    /// history is capped here rather than discovered to be too long by a thrown
    /// error halfway through a turn.
    private static let maximumReplayedHistoryMessages = 6

    var identifier: String { "apple/system-language-model" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: Self.modelSupportsVision,
            supportsTools: true,
            // Tools ride as `[TOOL:]` text for the reason in the file header.
            supportsNativeToolCalls: false,
            supportsStreaming: true,
            supportsStructuredOutput: false,
            contextWindowTokens: Self.fallbackContextWindowTokens
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(location: .onThisMachine, approximateOutputTokensPerSecond: nil)
    }

    /// Image input arrived with macOS 27; on 26 the model is text-only.
    private static var modelSupportsVision: Bool {
        if #available(macOS 27.0, *) {
            return SystemLanguageModel.default.capabilities.contains(.vision)
        }
        return false
    }

    /// Why the model cannot run right now, or nil when it can. Public so the
    /// settings page can say "turn on Apple Intelligence" instead of showing a
    /// generic failure.
    static var unavailabilityDescription: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "this Mac doesn't support Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off in System Settings"
            case .modelNotReady:
                return "the on-device model is still downloading"
            @unknown default:
                return "the on-device model isn't available"
            }
        }
    }

    // MARK: - Running a turn

    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        try validateAgainstCapabilities(request)

        if let unavailabilityDescription = Self.unavailabilityDescription {
            throw BuddyChatError.providerUnavailable(
                providerName: identifier,
                underlyingDescription: unavailabilityDescription
            )
        }

        // Same reasoning as the Ollama provider: the skill index is only useful
        // when `load_skill` survived tool scoping.
        let skills = request.tools.contains(where: { $0.name == "load_skill" })
            ? await SkillManager.shared.skills
            : []
        let instructionsText = request.systemPrompt
            + StructuredTextToolProtocol.promptInstructions(for: request.tools)
            + SkillIndex.promptInstructions(for: skills)

        let conversation = Self.translate(request)
        let session = LanguageModelSession(
            model: .default,
            instructions: instructionsText
        )
        let generationOptions = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.maxOutputTokens
        )

        let turnStartDate = Date()
        var fullReplyText = ""

        do {
            let responseStream = try Self.responseStream(
                for: conversation,
                in: session,
                options: generationOptions
            )
            for try await snapshot in responseStream {
                try Task.checkCancellation()
                // Snapshots carry the whole reply so far; the protocol promises
                // new text only, so only the unseen tail is forwarded.
                let cumulativeText = snapshot.content
                guard cumulativeText.count > fullReplyText.count,
                      cumulativeText.hasPrefix(fullReplyText) else { continue }
                let newText = String(cumulativeText.dropFirst(fullReplyText.count))
                fullReplyText = cumulativeText
                await onTextDelta(newText)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.chatError(from: error, providerName: identifier)
        }

        return Self.turn(
            fromReplyText: fullReplyText,
            duration: Date().timeIntervalSince(turnStartDate),
            knownToolNames: Set(request.tools.map(\.name)),
            exampleToolName: request.tools.first?.name
        )
    }

    /// Opens the response stream for the final user message, attaching its
    /// screenshot when there is one. Split out because attachments are a
    /// macOS 27 API and the availability check belongs in one place.
    private static func responseStream(
        for conversation: AppleConversation,
        in session: LanguageModelSession,
        options: GenerationOptions
    ) throws -> LanguageModelSession.ResponseStream<String> {
        if #available(macOS 27.0, *), !conversation.images.isEmpty {
            let attachments = conversation.images.compactMap { image -> Attachment<ImageAttachmentContent>? in
                guard let imageSource = CGImageSourceCreateWithData(image.data as CFData, nil),
                      let decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    return nil
                }
                return Attachment(decodedImage)
            }
            let promptText = conversation.promptText
            let prompt = Prompt {
                promptText
                for attachment in attachments {
                    attachment
                }
            }
            return session.streamResponse(to: prompt, options: options)
        }
        return session.streamResponse(to: conversation.promptText, options: options)
    }

    // MARK: - Request translation

    private struct AppleConversation {
        /// Earlier turns and the final user message as one prompt, because the
        /// framework session is created fresh for each request.
        let promptText: String
        let images: [(data: Data, label: String)]
    }

    private static func translate(_ request: ModelRequest) -> AppleConversation {
        let messages = request.messages
        let finalUserIndex = messages.lastIndex { $0.role == .user }

        var replayedLines: [String] = []
        for (index, message) in messages.enumerated() where index != finalUserIndex {
            let text = renderedText(of: message)
            guard !text.isEmpty else { continue }
            let speaker = message.role == .user ? "User" : "Assistant"
            replayedLines.append("\(speaker): \(text)")
        }
        let recentReplayedLines = replayedLines.suffix(maximumReplayedHistoryMessages)

        let finalMessage = finalUserIndex.map { messages[$0] }
        let finalText = finalMessage.map(renderedText(of:)) ?? ""
        let finalImages: [(data: Data, label: String)] = finalMessage?.blocks.compactMap { block in
            if case .image(let data, let label) = block { return (data: data, label: label) }
            return nil
        } ?? []

        var promptSections: [String] = []
        if !recentReplayedLines.isEmpty {
            promptSections.append("Earlier in this conversation:\n" + recentReplayedLines.joined(separator: "\n"))
        }
        promptSections.append(finalText)
        return AppleConversation(
            promptText: promptSections.joined(separator: "\n\n"),
            images: finalImages
        )
    }

    private static func renderedText(of message: BuddyChatMessage) -> String {
        var parts: [String] = []
        for block in message.blocks {
            switch block {
            case .text(let value):
                parts.append(value)
            case .toolResult(_, let toolName, let content, let isError):
                parts.append(
                    StructuredTextToolProtocol.resultMessageText(
                        toolName: toolName, content: content, isError: isError
                    )
                )
            case .toolUse(_, let name, let input):
                parts.append("[TOOL:\(name):\(input.compactDescription)]")
            case .image, .providerReplay:
                continue
            }
        }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response translation

    /// Same parse-and-drop-echoes step as `OllamaProvider.turn(from:)`: both
    /// recover `[TOOL:]` tags from plain text, so both need the anti-echo guard.
    private static func turn(
        fromReplyText replyText: String,
        duration: TimeInterval,
        knownToolNames: Set<String>,
        exampleToolName: String?
    ) -> BuddyChatTurn {
        let parsed = StructuredTextToolProtocol.parse(replyText, knownToolNames: knownToolNames)

        let echoedCallIDs = Set(
            parsed.toolCalls
                .filter { StructuredTextToolProtocol.isEchoOfPromptExample($0, exampleToolName: exampleToolName) }
                .map(\.id)
        )
        let content = parsed.contentBlocks.filter { block in
            if case .toolUse(let id, _, _) = block { return !echoedCallIDs.contains(id) }
            return true
        }

        return BuddyChatTurn(
            content: content,
            stopReason: content.toolUses.isEmpty ? .endTurn : .toolUse,
            duration: duration,
            promptTokens: nil,
            outputTokens: nil,
            malformedToolCallDescriptions: parsed.malformedTags
        )
    }

    // MARK: - Error translation

    /// Maps the framework's failures onto the provider-independent errors the
    /// pipeline already knows how to retry or report.
    private static func chatError(
        from error: LanguageModelSession.GenerationError,
        providerName: String
    ) -> BuddyChatError {
        switch error {
        case .exceededContextWindowSize:
            return .contextWindowExceeded(
                providerName: providerName,
                requestedTokens: nil,
                limitTokens: fallbackContextWindowTokens
            )
        case .rateLimited:
            return .rateLimited(providerName: providerName, retryAfter: nil)
        case .assetsUnavailable:
            return .providerUnavailable(
                providerName: providerName,
                underlyingDescription: "the on-device model isn't ready yet"
            )
        case .guardrailViolation, .refusal:
            return .providerUnavailable(
                providerName: providerName,
                underlyingDescription: "Apple's on-device model declined that request"
            )
        default:
            return .providerUnavailable(
                providerName: providerName,
                underlyingDescription: error.localizedDescription
            )
        }
    }
}
