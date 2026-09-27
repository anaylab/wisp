//
//  ModelProvider.swift
//  leanring-buddy
//
//  The seam between the agent loop and whatever actually runs inference.
//
//  Until now there was only one model, so the chat client and the agent loop
//  could be the same conversation: `BuddyVisionChatClient` takes a screenshot
//  and some strings and hands back a string. That shape cannot describe a
//  model that returns structured tool calls, and it cannot describe two
//  providers with different abilities — a local model that reads images but
//  fakes tool calls through text tags, and a cloud model that returns native
//  ones.
//
//  This protocol is deliberately passive. A provider translates a request into
//  a wire format, translates the reply back into `BuddyChatTurn`, and stops.
//  It never runs a tool, never reaches the registry, and never touches the
//  browser, the filesystem, or MCP. Tool execution stays where permission is
//  enforced — `AgentToolRegistry.invoke` — so a new provider cannot become a
//  new way around the approval boundary.
//
//  `OllamaProvider` is the first conformer. A second provider returning native
//  structured tool calls is what this shape exists to accommodate, so anything
//  here that only makes sense for a text-tag model is a bug in the abstraction
//  rather than a detail to work around.
//

import Foundation

// MARK: - Request

/// One inference request, independent of any provider's wire format.
///
/// Images ride inside `messages` as `BuddyContentBlock.image` rather than in a
/// separate parameter. Keeping them in the message list is what lets a
/// provider see *where* in the conversation an image belongs — the agent loop
/// attaches a screenshot to the first pass only, and a flat `images` argument
/// alongside the messages loses that placement and invites re-attaching it on
/// every later pass. A screenshot costs roughly six seconds of prompt
/// evaluation, so that is not a small mistake.
struct ModelRequest: Sendable {
    let systemPrompt: String
    let messages: [BuddyChatMessage]
    /// Tools the model may call this turn. Already scoped by the caller —
    /// a provider must not widen it.
    let tools: [BuddyToolDefinition]
    /// Ceiling on generated tokens, or `nil` to accept the provider's own.
    ///
    /// Optional because the sensible ceiling is a property of the model, not
    /// of the request: a local 7B reply is capped short because synthesis time
    /// scales with characters, while a cloud model's limit is a billing
    /// decision. `nil` means "you know better", and a provider must then apply
    /// its own default; a supplied value must be honoured.
    ///
    /// Note what is deliberately absent: the *context window*. Ollama reloads
    /// the model whenever `num_ctx` changes between requests — measured at
    /// 8.85 seconds even with the model already resident — so that value keeps
    /// a single owner inside the client, and this type offers no second way to
    /// set it.
    let maxOutputTokens: Int?
    /// `nil` leaves the provider's own default alone.
    let temperature: Double?

    init(
        systemPrompt: String,
        messages: [BuddyChatMessage],
        tools: [BuddyToolDefinition] = [],
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }

    /// Whether any message carries an image.
    ///
    /// Exists so a provider can refuse a request it cannot see rather than
    /// answering it blind — see `validateAgainstCapabilities`.
    var containsImages: Bool {
        messages.contains { message in
            message.blocks.contains { block in
                if case .image = block { return true }
                return false
            }
        }
    }

    var containsToolResults: Bool {
        messages.contains { message in
            message.blocks.contains { block in
                if case .toolResult = block { return true }
                return false
            }
        }
    }
}

// MARK: - Capabilities

/// What a model can do — and nothing about where it runs or how fast.
///
/// Deployment and speed are deliberately not here. Whether a model is local is
/// a fact about hosting, not ability: a local model may well handle vision
/// while a cloud one does not, and code that reaches for `isLocal` when it
/// means `supportsVision` is the reason such flags spread. Keeping them apart
/// means routing on capability and routing on privacy stay separable.
/// Several fields here are not yet read by any caller. They are declared
/// because a router choosing between providers needs to compare them, and
/// discovering halfway through adding a provider that the vocabulary is
/// missing is worse than carrying a few unused facts. Each is marked below
/// with what will consume it.
struct ModelCapabilities: Sendable {
    /// Reserved: distinguishes a chat model from an embedding-only endpoint.
    let supportsText: Bool
    let supportsVision: Bool
    /// The model can be *offered* tools in some form.
    let supportsTools: Bool
    /// The model returns structured tool calls of its own.
    ///
    /// Distinct from `supportsTools` because the local path fakes them: the
    /// model emits `[TOOL:name:{…}]` text that the provider parses back into
    /// `BuddyContentBlock.toolUse`. Both end up as tool calls at this layer;
    /// only one of them is reliable enough to skip an anti-echo guard.
    let supportsNativeToolCalls: Bool
    let supportsStreaming: Bool
    /// Reserved: JSON-schema-constrained decoding, for callers that need a
    /// parseable answer rather than prose.
    let supportsStructuredOutput: Bool
    /// Reserved: lets a router shed history, or refuse a request, before
    /// spending a round trip to discover it does not fit.
    let contextWindowTokens: Int

    init(
        supportsText: Bool = true,
        supportsVision: Bool,
        supportsTools: Bool,
        supportsNativeToolCalls: Bool,
        supportsStreaming: Bool,
        supportsStructuredOutput: Bool = false,
        contextWindowTokens: Int
    ) {
        self.supportsText = supportsText
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsNativeToolCalls = supportsNativeToolCalls
        self.supportsStreaming = supportsStreaming
        self.supportsStructuredOutput = supportsStructuredOutput
        self.contextWindowTokens = contextWindowTokens
    }
}

/// Where a model runs, and roughly how fast — kept apart from what it can do.
struct ModelDeployment: Sendable {
    enum Location: Sendable, Equatable {
        /// Inference happens on this machine; nothing leaves it.
        case onThisMachine
        /// Inference happens over the network, at the named host or service.
        case remote(serviceName: String)
    }

    let location: Location
    /// Rough generation speed, for deciding whether a turn is worth waiting on.
    /// `nil` when unmeasured — callers must treat that as "unknown", not "fast".
    let approximateOutputTokensPerSecond: Double?

    init(location: Location, approximateOutputTokensPerSecond: Double? = nil) {
        self.location = location
        self.approximateOutputTokensPerSecond = approximateOutputTokensPerSecond
    }

    /// True when a request would leave this machine. Named for the question
    /// callers actually ask, which is about privacy rather than topology.
    var sendsDataOffThisMachine: Bool {
        if case .remote = location { return true }
        return false
    }
}

// MARK: - Provider

/// Translates a `ModelRequest` into a `BuddyChatTurn`. Nothing more.
///
/// Not isolated to an actor on purpose. `analyzeImageStreaming` today runs its
/// response loop off the main actor and hops on only to deliver text, which is
/// what keeps the UI responsive while a reply streams. Pinning this protocol
/// to `@MainActor` would drag NDJSON parsing onto the main thread; the
/// isolation lives on the callback instead, where it is actually needed.
protocol ModelProvider: Sendable {
    /// Stable name for logs, metrics, and routing. Not shown to the user.
    var identifier: String { get }
    var capabilities: ModelCapabilities { get }
    var deployment: ModelDeployment { get }

    /// Runs one turn, reporting text as it arrives.
    ///
    /// This is the only required operation. A separate non-streaming method
    /// would mean two translation paths per provider, and two paths drift —
    /// which is exactly how the agent loop ended up discarding its stream
    /// while the direct path kept it.
    ///
    /// - Parameter onTextDelta: Called with **newly generated text only**,
    ///   never the accumulated reply so far. `SpokenSentenceStreamer` appends
    ///   what it is given, so a provider that re-sends the whole reply each
    ///   time produces duplicated, garbled speech. Providers whose upstream
    ///   reports cumulative text must diff before calling this.
    ///
    ///   Isolated to the main actor because every consumer already is, and
    ///   because the alternative is an actor hop per token on the one path
    ///   where latency is measured in how soon the user hears a voice.
    ///
    /// - Throws: `BuddyChatError` for provider-independent failures, or
    ///   `CancellationError` for cancellation — which must be rethrown as
    ///   itself, never folded into `BuddyChatError`. The response pipeline
    ///   distinguishes the two: cancellation abandons the turn and withdraws
    ///   any pending permission prompt, while an error is reported to the user.
    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn
}

extension ModelProvider {
    /// Runs a turn without observing intermediate text.
    ///
    /// A convenience over `streamTurn`, not a second path to implement, so a
    /// provider cannot support one and quietly neglect the other.
    func completeTurn(_ request: ModelRequest) async throws -> BuddyChatTurn {
        try await streamTurn(request, onTextDelta: { _ in })
    }

    /// Rejects a request the provider cannot honestly serve.
    ///
    /// Vision is the case that matters. Dropping an image and answering from
    /// the text alone produces a confident reply about a screen the model
    /// never saw, which is worse than an error because nothing looks wrong.
    /// Providers should call this before translating.
    func validateAgainstCapabilities(_ request: ModelRequest) throws {
        if request.containsImages && !capabilities.supportsVision {
            throw BuddyChatError.visionUnsupported(providerName: identifier)
        }
        if !request.tools.isEmpty && !capabilities.supportsTools {
            throw BuddyChatError.toolsUnsupported(providerName: identifier)
        }
    }
}
