//
//  BuddyChatTypes.swift
//  leanring-buddy
//
//  Shared value types for chat turns, tool calling, and agent task records.
//
//  These exist because the app's original chat surface was "text in, text
//  out": a request carried a screenshot plus a prompt, and the reply was a
//  single string. Tool calling needs richer shapes — an assistant turn can
//  contain tool invocations, and the following user turn carries their
//  results — so the types below model a conversation as messages of typed
//  content blocks rather than pairs of strings.
//

import Foundation

// MARK: - JSON

/// A `Sendable` JSON value.
///
/// Tool inputs and results cross task and actor boundaries, and the
/// `[String: Any]` dictionaries the networking code builds by hand are not
/// `Sendable`, so they can't safely make that trip. This is the smallest
/// type that can round-trip arbitrary tool JSON while staying concurrency-safe.
indirect enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let numberValue = try? container.decode(Double.self) {
            self = .number(numberValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Converts to the untyped representation `JSONSerialization` expects,
    /// since every network client in this project builds bodies by hand.
    var untypedValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            // Preserve integer-ness — some APIs reject 1.0 where 1 is expected.
            return value == value.rounded() && abs(value) < 9_007_199_254_740_992
                ? Int(value)
                : value
        case .string(let value): return value
        case .array(let value): return value.map(\.untypedValue)
        case .object(let value): return value.mapValues(\.untypedValue)
        }
    }

    /// Builds a `JSONValue` from the untyped output of `JSONSerialization`.
    ///
    /// The boolean check cannot be a plain `as? Bool`. `JSONSerialization`
    /// returns every number as `NSNumber`, and `NSNumber` bridges to `Bool` as
    /// readily as to `Int` — so `1` casts to `true` and a JSON-RPC message id
    /// silently becomes a boolean, after which every reply looks unroutable.
    /// Comparing the underlying CoreFoundation type is the only way to tell a
    /// real boolean from a number that happens to be 0 or 1.
    init(untypedValue: Any) {
        if let number = untypedValue as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
            return
        }

        switch untypedValue {
        case is NSNull:
            self = .null
        case let intValue as Int:
            self = .number(Double(intValue))
        case let doubleValue as Double:
            self = .number(doubleValue)
        case let stringValue as String:
            self = .string(stringValue)
        case let arrayValue as [Any]:
            self = .array(arrayValue.map(JSONValue.init(untypedValue:)))
        case let objectValue as [String: Any]:
            self = .object(objectValue.mapValues(JSONValue.init(untypedValue:)))
        default:
            self = .null
        }
    }

    /// Compact single-line rendering, for logs and dashboard rows.
    var compactDescription: String {
        guard let data = try? JSONSerialization.data(withJSONObject: untypedValue),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: untypedValue)
        }
        return text
    }
}

// MARK: - Conversation content

/// One piece of a chat message. A single assistant message can mix spoken
/// text with tool invocations, which a plain `String` cannot represent.
enum BuddyContentBlock: Sendable {
    case text(String)
    case image(data: Data, label: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, toolName: String, content: String, isError: Bool)
}

/// Views onto a run of blocks.
///
/// These live on the array rather than on any one owner because a message and
/// a model turn ask exactly the same questions of their content, and two
/// copies of "join the text blocks" is how the two would drift apart.
extension Array where Element == BuddyContentBlock {
    /// Every text block joined — what gets spoken or stored as the reply.
    var combinedText: String {
        compactMap { block in
            if case .text(let value) = block { return value }
            return nil
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The tool calls, in the order they appear.
    var toolUses: [(id: String, name: String, input: JSONValue)] {
        compactMap { block in
            if case .toolUse(let id, let name, let input) = block {
                return (id: id, name: name, input: input)
            }
            return nil
        }
    }

    var containsImage: Bool {
        contains { block in
            if case .image = block { return true }
            return false
        }
    }

    /// The same blocks with every image removed.
    ///
    /// A projection rather than an edit in place: a screenshot is worth about
    /// 1095 prompt tokens and roughly six seconds of evaluation, so it is sent
    /// on exactly one pass — but the conversation still needs to record that
    /// it was sent, so the dropping happens on the way to a provider and never
    /// to the stored history.
    var withoutImages: [BuddyContentBlock] {
        filter { block in
            if case .image = block { return false }
            return true
        }
    }
}

struct BuddyChatMessage: Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    let role: Role
    var blocks: [BuddyContentBlock]

    init(role: Role, blocks: [BuddyContentBlock]) {
        self.role = role
        self.blocks = blocks
    }

    /// Convenience for the common plain-text case.
    init(role: Role, text: String) {
        self.init(role: role, blocks: [.text(text)])
    }

    /// All text blocks joined — what gets spoken or stored as the reply.
    var combinedText: String { blocks.combinedText }

    var toolUses: [(id: String, name: String, input: JSONValue)] { blocks.toolUses }

    /// The same message with every image dropped.
    var withoutImages: BuddyChatMessage {
        BuddyChatMessage(role: role, blocks: blocks.withoutImages)
    }
}

// MARK: - Tools

struct BuddyToolDefinition: Sendable {
    let name: String
    let description: String
    /// A JSON Schema object describing the tool's arguments.
    let inputSchema: JSONValue

    /// What this tool does to the world. The permission layer reasons about
    /// these facts rather than about a pre-computed decision.
    let metadata: ToolMetadata

    /// Whether the user must approve this before it runs.
    ///
    /// Derived from `metadata` rather than stored, so a tool cannot describe
    /// itself as destructive and separately as not needing approval.
    var requiresConfirmation: Bool { metadata.requiresConfirmation }

    init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        metadata: ToolMetadata
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.metadata = metadata
    }

    /// Retained so existing registrations keep compiling unchanged.
    ///
    /// A bare boolean cannot say *why* a tool needs approval, so this infers
    /// the most conservative facts consistent with it: anything that asks is
    /// treated as writing with external effects until it says otherwise. Tools
    /// are migrated to explicit metadata one at a time rather than in a single
    /// sweep that would touch every registration at once.
    init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        requiresConfirmation: Bool = false
    ) {
        self.init(
            name: name,
            description: description,
            inputSchema: inputSchema,
            metadata: requiresConfirmation
                ? ToolMetadata(readOnly: false, externalSideEffect: true, dataSource: .localMachine)
                : ToolMetadata.reading()
        )
    }
}

enum BuddyStopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case other(String)
}

/// The result of one assistant turn — possibly a final answer, possibly a
/// request to run tools and come back.
///
/// `content` is the canonical record: every block the model produced, in the
/// order it produced them. It is stored rather than derived because that order
/// is information no other field carries. A model that says something, calls a
/// tool, and then says something else produced three blocks; the shape this
/// type used to have — a joined string plus a separate list of calls — cannot
/// say which sentence came before the call and which after, so replaying the
/// turn to a provider that cares about interleaving reconstructs a
/// conversation that never happened. `text` and `toolUses` remain available as
/// views onto `content`, so a caller wanting only the prose or only the calls
/// still reads the same single source.
struct BuddyChatTurn: Sendable {
    let content: [BuddyContentBlock]
    let stopReason: BuddyStopReason
    let duration: TimeInterval
    /// What the provider reported this turn cost, when it reports anything.
    ///
    /// Optional because it is the provider's own accounting, not an estimate:
    /// `nil` means the number was not supplied, which is different from zero.
    /// Recomputing it locally would mean re-tokenising the prompt with a
    /// different tokeniser than the one that actually ran, so a missing value
    /// is left missing.
    let promptTokens: Int?
    let outputTokens: Int?
    /// Text that looked like a tool call but could not be read.
    ///
    /// Surfaced rather than dropped for two reasons. The model can be told its
    /// call was malformed and correct itself, instead of silently getting
    /// nothing back. And a reply containing one is *ambiguous* — the model was
    /// trying to call a tool, so whatever else it said is very likely
    /// narration rather than an answer, and must not be spoken on the
    /// assumption that the turn is finished.
    let malformedToolCallDescriptions: [String]

    /// Every text block joined — what is spoken when the turn is final.
    var text: String { content.combinedText }

    /// The calls the model asked for, in the order it wrote them.
    var toolUses: [(id: String, name: String, input: JSONValue)] { content.toolUses }

    /// Whether this turn is unambiguously a finished answer.
    ///
    /// A turn qualifies only when the model asked for nothing and mangled
    /// nothing. This is the single condition under which the text is safe to
    /// speak; anything else is either a request for a tool or an attempt at
    /// one, and speaking either reads a half-answer aloud.
    var isUnambiguousFinalAnswer: Bool {
        toolUses.isEmpty && malformedToolCallDescriptions.isEmpty
    }

    init(
        content: [BuddyContentBlock],
        stopReason: BuddyStopReason = .endTurn,
        duration: TimeInterval = 0,
        promptTokens: Int? = nil,
        outputTokens: Int? = nil,
        malformedToolCallDescriptions: [String] = []
    ) {
        self.content = content
        self.stopReason = stopReason
        self.duration = duration
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.malformedToolCallDescriptions = malformedToolCallDescriptions
    }

    /// Convenience for the common shape: some prose, then any tool calls.
    ///
    /// Kept because that is genuinely all some providers can report — a wire
    /// format that returns a `content` string and a `tool_calls` array has no
    /// interleaving to preserve, and forcing every one of them to assemble a
    /// block list by hand would invite them to assemble it differently. Empty
    /// text produces no text block at all rather than a blank one, so a turn
    /// that is nothing but a tool call carries no empty prose into the history.
    init(
        text: String,
        toolUses: [(id: String, name: String, input: JSONValue)] = [],
        stopReason: BuddyStopReason = .endTurn,
        duration: TimeInterval = 0,
        promptTokens: Int? = nil,
        outputTokens: Int? = nil,
        malformedToolCallDescriptions: [String] = []
    ) {
        var content: [BuddyContentBlock] = text.isEmpty ? [] : [.text(text)]
        content.append(contentsOf: toolUses.map {
            .toolUse(id: $0.id, name: $0.name, input: $0.input)
        })
        self.init(
            content: content,
            stopReason: stopReason,
            duration: duration,
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            malformedToolCallDescriptions: malformedToolCallDescriptions
        )
    }
}

/// A failure expressed in terms the caller can act on, whichever provider
/// produced it.
///
/// The point is that routing logic should not have to read HTTP status codes
/// or match on error strings to answer "should I retry, fall back to another
/// model, or tell the user?". Cancellation is deliberately absent: it stays a
/// `CancellationError` all the way up, because the response pipeline treats an
/// abandoned turn differently from a failed one — it withdraws any pending
/// permission prompt and reports nothing to the user.
enum BuddyChatError: LocalizedError {
    case toolsUnsupported(providerName: String)
    /// The request carried an image the provider cannot see. Raised rather
    /// than dropping the image, so a model never answers confidently about a
    /// screen it was never shown.
    case visionUnsupported(providerName: String)
    /// The conversation no longer fits. Carries both numbers so a caller can
    /// decide how much history to shed rather than guessing.
    case contextWindowExceeded(providerName: String, requestedTokens: Int?, limitTokens: Int)
    /// Throttled upstream. `retryAfter` is the server's own hint when it gives
    /// one; `nil` means it did not, not that retrying is free.
    case rateLimited(providerName: String, retryAfter: TimeInterval?)
    /// Credentials missing, expired, or rejected. Never retry this one.
    case authenticationFailed(providerName: String)
    /// The provider could not be reached or is not running — a local server
    /// that is down, or a host that will not answer.
    case providerUnavailable(providerName: String, underlyingDescription: String?)

    var errorDescription: String? {
        switch self {
        case .toolsUnsupported(let providerName):
            return "\(providerName) does not support tool calling."
        case .visionUnsupported(let providerName):
            return "\(providerName) cannot look at images."
        case .contextWindowExceeded(let providerName, let requestedTokens, let limitTokens):
            if let requestedTokens {
                return "the conversation is too long for \(providerName) (\(requestedTokens) tokens, limit \(limitTokens))."
            }
            return "the conversation is too long for \(providerName) (limit \(limitTokens) tokens)."
        case .rateLimited(let providerName, let retryAfter):
            if let retryAfter {
                return "\(providerName) is rate limited — try again in \(Int(retryAfter.rounded()))s."
            }
            return "\(providerName) is rate limited."
        case .authenticationFailed(let providerName):
            return "\(providerName) rejected the credentials."
        case .providerUnavailable(let providerName, let underlyingDescription):
            if let underlyingDescription {
                return "\(providerName) is unavailable: \(underlyingDescription)"
            }
            return "\(providerName) is unavailable."
        }
    }

    /// Whether trying the same request again could plausibly succeed.
    ///
    /// Exists so callers stop encoding this per-case at each site, which is
    /// where retry storms against an unauthenticated endpoint come from.
    var isWorthRetrying: Bool {
        switch self {
        case .rateLimited, .providerUnavailable:
            return true
        case .toolsUnsupported, .visionUnsupported, .contextWindowExceeded, .authenticationFailed:
            return false
        }
    }
}

// MARK: - Conversation transcript

/// The conversation, grouped into turns.
///
/// Grouping matters for trimming: a tool result is only valid alongside the
/// tool call it answers, so dropping individual messages to stay under a
/// limit can orphan one from the other, which the model APIs reject. Whole
/// turns are therefore the unit of both storage and eviction.
struct ConversationTranscript: Sendable {
    struct Turn: Sendable, Identifiable {
        let id: UUID
        let startedAt: Date
        /// The user message plus every assistant/tool message through the
        /// final assistant reply.
        var messages: [BuddyChatMessage]

        init(id: UUID = UUID(), startedAt: Date = Date(), messages: [BuddyChatMessage]) {
            self.id = id
            self.startedAt = startedAt
            self.messages = messages
        }

        var userText: String {
            messages.first(where: { $0.role == .user })?.combinedText ?? ""
        }

        var assistantText: String {
            messages.last(where: { $0.role == .assistant })?.combinedText ?? ""
        }
    }

    private(set) var turns: [Turn] = []

    /// Flattened messages — the whole record, exactly as it was appended.
    var messages: [BuddyChatMessage] {
        turns.flatMap(\.messages)
    }

    /// The history to put in front of the model on the *next* request.
    ///
    /// One user message and one assistant message per past turn: what the user
    /// asked, and the answer they got. Intra-turn tool traffic is deliberately
    /// left behind. A tool result is written for a model that is mid-turn and
    /// routinely runs to thousands of characters, and replaying ten turns of it
    /// into a context window that also carries a screenshot buys context the
    /// model has already acted on at a price paid on every subsequent turn.
    ///
    /// This is a projection, not a trim: the full record stays in `turns`, so
    /// a provider with room to spare — or a dashboard, or a bug report — can
    /// still see every call that was made. Deciding what a particular request
    /// can afford is the caller's business, and it is why the transcript is
    /// never edited to fit one.
    func messagesForFollowUpRequest() -> [BuddyChatMessage] {
        turns.flatMap { turn in
            [
                BuddyChatMessage(role: .user, text: turn.userText),
                BuddyChatMessage(role: .assistant, text: turn.assistantText),
            ]
        }
    }

    /// The alternating string pairs the pre-agent chat client still takes.
    ///
    /// Lossy, and deliberately the only place that loss happens: the legacy
    /// `analyzeImageStreaming` parameter cannot express a tool call or an
    /// image, so the flattening is written once here rather than open-coded at
    /// each call site where it would quietly acquire variations.
    static func legacyStringPairs(
        from messages: [BuddyChatMessage]
    ) -> [(userPlaceholder: String, assistantResponse: String)] {
        var pairs: [(userPlaceholder: String, assistantResponse: String)] = []
        var pendingUserText: String?

        for message in messages {
            switch message.role {
            case .user:
                // Two user messages in a row would otherwise drop the first.
                if let unanswered = pendingUserText {
                    pairs.append((userPlaceholder: unanswered, assistantResponse: ""))
                }
                pendingUserText = message.combinedText
            case .assistant:
                pairs.append((
                    userPlaceholder: pendingUserText ?? "",
                    assistantResponse: message.combinedText
                ))
                pendingUserText = nil
            }
        }

        if let trailing = pendingUserText, !trailing.isEmpty {
            pairs.append((userPlaceholder: trailing, assistantResponse: ""))
        }
        return pairs
    }

    mutating func append(_ turn: Turn) {
        turns.append(turn)
    }

    /// Keeps the most recent `limit` turns. Always trims whole turns.
    mutating func trimToRecentTurns(_ limit: Int) {
        guard turns.count > limit else { return }
        turns.removeFirst(turns.count - limit)
    }

    mutating func removeAll() {
        turns.removeAll()
    }
}

// MARK: - Agent task records

/// One step an agent task took — today that's a single model call; with the
/// agent loop it becomes one entry per tool invocation.
struct AgentStepRecord: Sendable, Identifiable {
    enum Kind: Sendable {
        case modelCall
        case tool(name: String)
    }

    let id: UUID
    let kind: Kind
    let summary: String
    let detail: String?
    let startedAt: Date
    var durationSeconds: TimeInterval
    var isError: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        summary: String,
        detail: String? = nil,
        startedAt: Date = Date(),
        durationSeconds: TimeInterval = 0,
        isError: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.isError = isError
    }

    var kindLabel: String {
        switch kind {
        case .modelCall: return "model"
        case .tool(let name): return name
        }
    }
}

struct AgentTaskRecord: Sendable, Identifiable {
    enum Kind: String, Sendable {
        case interactive
        case background
    }

    enum Status: Sendable, Equatable {
        case running
        case waitingForApproval
        case succeeded
        case failed(String)
        case cancelled
        /// The app quit while this task was still running.
        case interrupted

        var displayName: String {
            switch self {
            case .running: return "Running"
            case .waitingForApproval: return "Needs approval"
            case .succeeded: return "Done"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            case .interrupted: return "Interrupted"
            }
        }

        var isTerminal: Bool {
            switch self {
            case .running, .waitingForApproval: return false
            case .succeeded, .failed, .cancelled, .interrupted: return true
            }
        }
    }

    let id: UUID
    var title: String
    var kind: Kind
    var status: Status
    var steps: [AgentStepRecord]
    let startedAt: Date
    var finishedAt: Date?
    var finalText: String?

    init(
        id: UUID = UUID(),
        title: String,
        kind: Kind = .interactive,
        status: Status = .running,
        steps: [AgentStepRecord] = [],
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        finalText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.finalText = finalText
    }

    var elapsedSeconds: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}
