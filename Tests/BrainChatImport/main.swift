//
//  AI chat import suite: ChatGPT and Claude export parsing, transcripts, file
//  names and import planning.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

// MARK: - ChatGPT

// A tree with an abandoned branch (the first answer was regenerated), a
// system message, a hidden message and a code-run node.
let chatGPTExport = """
[{
  "title": "Sourdough starter help",
  "conversation_id": "abc-123-def",
  "create_time": 1709337600.0,
  "update_time": 1709341200.0,
  "current_node": "n5",
  "mapping": {
    "root": {"id": "root", "message": null, "parent": null, "children": ["n1"]},
    "n1": {"id": "n1", "parent": "root", "children": ["n2"], "message": {"author": {"role": "system"}, "content": {"content_type": "text", "parts": ["You are ChatGPT"]}}},
    "n2": {"id": "n2", "parent": "n1", "children": ["old", "n3"], "message": {"author": {"role": "user"}, "content": {"content_type": "text", "parts": ["My starter smells like nail polish after I moved flats, what is going on?"]}}},
    "old": {"id": "old", "parent": "n2", "children": [], "message": {"author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["ABANDONED ANSWER"]}}},
    "n3": {"id": "n3", "parent": "n2", "children": ["n4"], "message": {"author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["That acetone smell means it is hungry."]}}},
    "n4": {"id": "n4", "parent": "n3", "children": ["n5"], "message": {"author": {"role": "tool"}, "content": {"content_type": "code", "text": "print(1)"}}},
    "n5": {"id": "n5", "parent": "n4", "children": [], "message": {"author": {"role": "user"}, "metadata": {"is_visually_hidden_from_conversation": true}, "content": {"content_type": "text", "parts": ["HIDDEN"]}}}
  }
}]
"""

let parsedChatGPT = try! BrainChatExportParser.parse(Data(chatGPTExport.utf8))
check(parsedChatGPT.provider == .chatGPT, "ChatGPT export recognised by its mapping")
check(parsedChatGPT.chats.count == 1, "one ChatGPT conversation")
let sourdoughChat = parsedChatGPT.chats[0]
check(sourdoughChat.title == "Sourdough starter help", "ChatGPT title")
check(sourdoughChat.conversationID == "abc-123-def", "ChatGPT conversation id")
check(sourdoughChat.messages.count == 2, "only the visible user and assistant turns on the current branch")
check(sourdoughChat.messages.first?.speaker == .user, "user speaks first")
check(sourdoughChat.messages.last?.text == "That acetone smell means it is hungry.", "regenerated answer kept")
check(!sourdoughChat.messages.contains { $0.text.contains("ABANDONED") }, "abandoned branch dropped")
check(!sourdoughChat.messages.contains { $0.text.contains("HIDDEN") }, "hidden message dropped")
check(sourdoughChat.createdDate == Date(timeIntervalSince1970: 1709337600), "ChatGPT created date")

// MARK: - Claude

let claudeExport = """
[{
  "uuid": "9f8e7d6c-0000-1111",
  "name": "Grant budget",
  "created_at": "2025-05-01T10:00:00.123456Z",
  "updated_at": "2025-05-01T11:00:00Z",
  "chat_messages": [
    {"sender": "human", "text": "Help me trim the equipment line of my grant budget by fifteen percent.", "created_at": "2025-05-01T10:00:00Z"},
    {"sender": "assistant", "text": "", "content": [{"type": "text", "text": "Start with the microscope lease."}, {"type": "tool_use", "name": "x"}]},
    {"sender": "human", "text": "   "}
  ]
}, {
  "uuid": "short-one",
  "name": "",
  "created_at": "2025-06-01T10:00:00Z",
  "chat_messages": [{"sender": "human", "text": "hi"}]
}]
"""

let parsedClaude = try! BrainChatExportParser.parse(Data(claudeExport.utf8))
check(parsedClaude.provider == .claude, "Claude export recognised by chat_messages")
check(parsedClaude.chats.count == 2, "two Claude conversations")
let grantChat = parsedClaude.chats[0]
check(grantChat.messages.count == 2, "blank message dropped")
check(grantChat.messages.last?.text == "Start with the microscope lease.", "text read from content blocks when text is empty")
check(grantChat.createdDate != nil, "fractional-second ISO date parsed")
check(parsedClaude.chats[1].title == "Untitled chat", "empty title gets a fallback")

// Branches: an edited first message left an abandoned branch behind.
let branchedClaudeExport = """
[{"uuid": "branchy", "name": "Branched", "created_at": "2025-07-01T10:00:00Z", "chat_messages": [
  {"uuid": "m1", "parent_message_uuid": "00000000-0000-4000-8000-000000000000", "sender": "human", "text": "OLD QUESTION that I later edited away"},
  {"uuid": "m2", "parent_message_uuid": "m1", "sender": "assistant", "text": "OLD ANSWER"},
  {"uuid": "m3", "parent_message_uuid": "00000000-0000-4000-8000-000000000000", "sender": "human", "text": "The question I actually kept asking about turbines"},
  {"uuid": "m4", "parent_message_uuid": "m3", "sender": "assistant", "text": "Kept answer."}
]}]
"""
let branchedChat = try! BrainChatExportParser.parse(Data(branchedClaudeExport.utf8)).chats[0]
check(branchedChat.messages.map(\.text) == ["The question I actually kept asking about turbines", "Kept answer."], "only the current branch of a Claude chat is kept")

let placeholderText = "I'll check.\n```\nThis block is not supported on your current device yet.\n```\n\n\n\n```\nThis block is not supported on your current device yet.\n```\nNothing came through."
check(BrainChatExportParser.withoutClaudePlaceholderBlocks(placeholderText) == "I'll check.\n\nNothing came through.", "Claude's tool placeholder blocks are dropped")
check(BrainChatExportParser.withoutClaudePlaceholderBlocks("```\nThis block is not supported on your current device yet.\n```") == "", "a reply that was only placeholders becomes empty")

check(BrainChatExportParser.withoutClaudePlaceholderBlocks("Here:\n```\nBuild path for a leaderboard site\nThis block is not supported on your current device yet.\n```\nDone.") == "Here:\n[Build path for a leaderboard site]\nDone.", "a titled placeholder keeps its title")

// MARK: - Errors

check((try? BrainChatExportParser.parse(Data("not json".utf8))) == nil, "non-JSON refused")
do {
    _ = try BrainChatExportParser.parse(Data("[{\"foo\": 1}]".utf8))
    check(false, "unknown shape refused")
} catch {
    check(error as? BrainChatExportParseError == .unrecognisedFormat, "unknown shape gives unrecognisedFormat")
}
check((try? BrainChatExportParser.parse(Data("[]".utf8)))?.chats.isEmpty == true, "empty export is fine")

// MARK: - Transcript and file name

let sourdoughTranscript = BrainChatExportParser.transcriptMarkdown(for: sourdoughChat)
check(sourdoughTranscript.hasPrefix("# Sourdough starter help\n"), "transcript starts with the title")
check(sourdoughTranscript.contains("only the user's lines say anything about the user"), "transcript tells the model whose words are whose")
check(sourdoughTranscript.contains("about the user.\n\n**You:** My starter smells"), "a blank line separates the header from the first message")
check(sourdoughTranscript.contains("**ChatGPT:** That acetone"), "assistant line marked with the provider")

var longChat = grantChat
longChat.messages = [BrainImportedChatMessage(speaker: .user, text: String(repeating: "a", count: 70_000) + "THE END")]
let longTranscript = BrainChatExportParser.transcriptMarkdown(for: longChat)
check(longTranscript.contains("THE END") && longTranscript.count < 61_000, "long transcript keeps its end and is capped")

let sourdoughFileName = BrainChatExportParser.fileName(for: sourdoughChat)
check(sourdoughFileName.hasSuffix(" Sourdough starter help abc123de.md"), "file name has the title and an id suffix (got \(sourdoughFileName))")
check(sourdoughFileName.hasPrefix("2024-03-0"), "file name starts with the date")
check(!BrainChatExportParser.fileName(for: BrainImportedChat(provider: .claude, conversationID: "", title: "a/b:c", createdDate: nil, updatedDate: nil, messages: [])).contains("/"), "no slash in a file name")

// MARK: - Planning

let allChats = parsedChatGPT.chats + parsedClaude.chats
let firstPlan = BrainChatImportPlanner.plan(chats: allChats, state: BrainChatImportState())
check(firstPlan.chatsToImport.count == 2, "both substantial chats planned")
check(firstPlan.tooShortChatCount == 1, "the 'hi' chat is too short")
check(firstPlan.chatsToImport.first?.conversationKey == "claude:9f8e7d6c-0000-1111", "newest chat first")

var stateAfterFirstImport = BrainChatImportState()
for plannedChat in firstPlan.chatsToImport {
    stateAfterFirstImport.transcriptHashesByConversationKey[plannedChat.conversationKey] = plannedChat.transcriptHash
}
// Queued but not yet read: still planned next time (a failed job comes back).
var stateWithPendingChats = BrainChatImportState()
stateWithPendingChats.pendingChatsByTranscriptPath = [:]
for plannedChat in firstPlan.chatsToImport {
    stateWithPendingChats.pendingChatsByTranscriptPath?["/raw/chats/\(plannedChat.fileName)"] = .init(conversationKey: plannedChat.conversationKey, transcriptHash: plannedChat.transcriptHash)
}
check(BrainChatImportPlanner.plan(chats: allChats, state: stateWithPendingChats).chatsToImport.count == 2, "a chat that was only queued is planned again")
let confirmedPath = "/raw/chats/\(firstPlan.chatsToImport[0].fileName)"
check(stateWithPendingChats.confirmRead(transcriptPath: confirmedPath), "a finished job confirms its chat")
check(!stateWithPendingChats.confirmRead(transcriptPath: confirmedPath), "a chat is confirmed once")
check(BrainChatImportPlanner.plan(chats: allChats, state: stateWithPendingChats).chatsToImport.count == 1, "a confirmed chat is skipped next time")
let oldStateData = Data(#"{"transcriptHashesByConversationKey":{"claude:x":"abc"}}"#.utf8)
check((try? JSONDecoder().decode(BrainChatImportState.self, from: oldStateData))?.transcriptHashesByConversationKey["claude:x"] == "abc", "a state file from before pending chats still loads")

let secondPlan = BrainChatImportPlanner.plan(chats: allChats, state: stateAfterFirstImport)
check(secondPlan.chatsToImport.isEmpty && secondPlan.unchangedChatCount == 2, "re-importing the same export brings nothing")

var grownGrantChat = grantChat
grownGrantChat.messages.append(BrainImportedChatMessage(speaker: .user, text: "And the travel line?"))
let grownPlan = BrainChatImportPlanner.plan(chats: [grownGrantChat, sourdoughChat], state: stateAfterFirstImport)
check(grownPlan.chatsToImport.map(\.conversationKey) == ["claude:9f8e7d6c-0000-1111"], "a chat that grew is imported again")
check(grownPlan.chatsToImport.first?.fileName == firstPlan.chatsToImport.first?.fileName, "a grown chat replaces its own file")

let cappedPlan = BrainChatImportPlanner.plan(chats: allChats, state: BrainChatImportState(), maximumChatCount: 1)
check(cappedPlan.chatsToImport.count == 1 && cappedPlan.deferredChatCount == 1, "per-run cap defers the rest")

check(BrainChatImportPlanner.statusMessage(for: firstPlan, providerName: "Claude", queuedChatCount: 2) == "queued 2 Claude chats for reading (1 too short).", "status message")
check(BrainChatImportPlanner.statusMessage(for: secondPlan, providerName: "Claude", queuedChatCount: 0).hasPrefix("nothing new"), "nothing-new message")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
if failureCount > 0 { exit(1) }
