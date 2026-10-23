//
//  Just enough of the app for `ChromeTabOrganizer.swift` to compile on its own,
//  so this suite can use its pure planners (`ChromeTabGroupingPlanner`,
//  `ChromeDuplicateTabFinder`) without building the whole app. Nothing here
//  runs: the suite never calls `ChromeTabOrganizer`, which is the only code
//  that reaches these.
//

import Foundation

enum JSONValue: Decodable {
    case null
    init(from decoder: Decoder) throws { self = .null }
}

struct BuddyChatMessage {
    enum Role { case user, assistant }
    init(role: Role, text: String) {}
}

struct ModelRequest {
    init(systemPrompt: String, messages: [BuddyChatMessage], maxOutputTokens: Int, temperature: Double) {}
}

struct StubModelTurn { let text: String }

protocol ModelProvider {
    func completeTurn(_ request: ModelRequest) async throws -> StubModelTurn
}

final class ModelAccessGate {
    enum Priority { case interactive }
    static let shared = ModelAccessGate()
    func withAccess<Result>(priority: Priority, _ work: () async throws -> Result) async throws -> Result { try await work() }
}

enum ChromeTabLife {
    static func perform(_ command: ChromeTabLifeCommand, modelProvider: any ModelProvider) async throws -> String { "" }
}

final class ChromeExtensionBridge {
    static let shared = ChromeExtensionBridge()
    func sendRequest<Parameters: Encodable, Result: Decodable>(
        method: String, parameters: Parameters, resultType: Result.Type
    ) async throws -> Result {
        fatalError("not used by the suite")
    }
}

// Focus mode (phase 09) is one more `ChromeTabCommand` case that
// `ChromeTabOrganizer.perform` hands to the session; the real session reaches
// the timer store and the notch, so it is stubbed like the rest of the app.
@MainActor
final class ChromeFocusSession {
    static let shared = ChromeFocusSession()

    func perform(_ command: ChromeFocusCommand) async -> (replyText: String, didSucceed: Bool) {
        ("", true)
    }
}

// Site helpers (phase 10) are one more `ChromeTabCommand` case handed to their
// own coordinator, which reaches the bridge, Jobs and the model; stubbed too.
@MainActor
final class ChromeSiteHelpers {
    static let shared = ChromeSiteHelpers()

    func perform(_ command: ChromeSiteHelperCommand, modelProvider: any ModelProvider) async -> (replyText: String, didSucceed: Bool) {
        ("", true)
    }
}
