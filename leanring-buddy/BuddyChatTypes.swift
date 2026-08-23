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
    var combinedText: String {
        blocks.compactMap { block in
            if case .text(let value) = block { return value }
            return nil
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var toolUses: [(id: String, name: String, input: JSONValue)] {
        blocks.compactMap { block in
            if case .toolUse(let id, let name, let input) = block {
                return (id: id, name: name, input: input)
            }
            return nil
        }
    }
}

// MARK: - Tools

struct BuddyToolDefinition: Sendable {
    let name: String
    let description: String
    /// A JSON Schema object describing the tool's arguments.
    let inputSchema: JSONValue
    /// Tools that change state (rather than only reading it) must be
    /// confirmed by the user before they run. Everything ships read-only
    /// until that confirmation flow exists.
    let requiresConfirmation: Bool

    init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.requiresConfirmation = requiresConfirmation
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
struct BuddyChatTurn: Sendable {
    let text: String
    let toolUses: [(id: String, name: String, input: JSONValue)]
    let stopReason: BuddyStopReason
    let duration: TimeInterval

    init(
        text: String,
        toolUses: [(id: String, name: String, input: JSONValue)] = [],
        stopReason: BuddyStopReason = .endTurn,
        duration: TimeInterval = 0
    ) {
        self.text = text
        self.toolUses = toolUses
        self.stopReason = stopReason
        self.duration = duration
    }
}

enum BuddyChatError: LocalizedError {
    case toolsUnsupported(providerName: String)

    var errorDescription: String? {
        switch self {
        case .toolsUnsupported(let providerName):
            return "\(providerName) does not support tool calling."
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

    /// Flattened messages, for sending to a model.
    var messages: [BuddyChatMessage] {
        turns.flatMap(\.messages)
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
