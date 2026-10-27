//
//  ShortcutRecordedToolCall.swift
//  leanring-buddy
//
//  One tool call from a finished turn, as `AgentTurnRunner` reports it. Its own file, depending
//  only on `JSONValue`, so the agent loop can carry it without depending on the rest of the
//  learned-shortcuts code.
//

import Foundation

struct ShortcutRecordedToolCall: Equatable, Sendable {
    let toolName: String
    /// The input the tool actually ran with (after input preparation and the user's card edits).
    let toolInput: JSONValue
    /// False for an error and for a declined call.
    let succeeded: Bool
}
