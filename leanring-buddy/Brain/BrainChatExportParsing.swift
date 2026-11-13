//
//  BrainChatExportParsing.swift
//  leanring-buddy
//
//  The pure half of importing the user's AI chats: reading a ChatGPT or
//  Claude data export's `conversations.json` into plain conversations,
//  rendering each one as a markdown transcript for `raw/chats/`, and deciding
//  which conversations an import brings (new or grown since the last one).
//
//  Both exports are a JSON array of conversations, told apart by shape:
//  - ChatGPT: each conversation has a `mapping` of message nodes forming a
//    tree (edits and regenerations branch it). The conversation as the user
//    last saw it is the path from `current_node` up through `parent` links.
//  - Claude: each conversation has a flat `chat_messages` array with
//    `sender` "human" / "assistant" and either `text` or `content` blocks.
//    Edits and retries branch it too (`parent_message_uuid`), so only the
//    path back from the newest message is kept.
//
//  Only the user's and the assistant's visible text is kept — system
//  prompts, tool calls and hidden messages are dropped. The transcript says
//  plainly which lines are the user's own words, because the ingest prompt
//  must not file what the AI said as facts about the user.
//
//  Foundation only, so `Tests/BrainChatImport` compiles it standalone.
//

import Foundation

nonisolated enum BrainChatExportProvider: String, Codable, Equatable, Sendable {
    case chatGPT
    case claude

    var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        }
    }
}

nonisolated struct BrainImportedChatMessage: Equatable, Sendable {
    enum Speaker: Equatable, Sendable {
        case user
        case assistant
    }

    var speaker: Speaker
    var text: String
}

nonisolated struct BrainImportedChat: Equatable, Sendable {
    var provider: BrainChatExportProvider
    /// The export's own id for the conversation, so a re-import of a newer
    /// export replaces the file instead of adding a second copy.
    var conversationID: String
    var title: String
    var createdDate: Date?
    var updatedDate: Date?
    var messages: [BrainImportedChatMessage]

    /// Characters the user typed across the conversation.
    var userCharacterCount: Int {
        messages.filter { $0.speaker == .user }.reduce(0) { $0 + $1.text.count }
    }
}

nonisolated enum BrainChatExportParseError: Error, Equatable, LocalizedError {
    case notJSON
    case unrecognisedFormat

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return "that file isn't JSON — choose conversations.json from an unzipped ChatGPT or Claude export."
        case .unrecognisedFormat:
            return "that doesn't look like a ChatGPT or Claude export — choose the conversations.json inside it."
        }
    }
}

nonisolated enum BrainChatExportParser {
    /// Conversations whose user side is shorter than this carry nothing worth
    /// remembering ("hi", a single pasted word) and are skipped.
    static let minimumUserCharacterCount = 40
    /// A transcript longer than this is cut (the end kept) before ingest — the
    /// chunker samples evenly anyway, and the raw file shouldn't be huge.
    static let maximumTranscriptCharacterCount = 60_000

    static func parse(_ exportData: Data) throws -> (provider: BrainChatExportProvider, chats: [BrainImportedChat]) {
        guard let jsonValue = try? JSONSerialization.jsonObject(with: exportData) else {
            throw BrainChatExportParseError.notJSON
        }
        guard let conversationObjects = jsonValue as? [[String: Any]] else {
            throw BrainChatExportParseError.unrecognisedFormat
        }
        guard let firstConversation = conversationObjects.first else {
            // An empty export is valid; call it ChatGPT, it doesn't matter.
            return (.chatGPT, [])
        }
        if firstConversation["mapping"] != nil {
            return (.chatGPT, conversationObjects.compactMap(parseChatGPTConversation))
        }
        if firstConversation["chat_messages"] != nil {
            return (.claude, conversationObjects.compactMap(parseClaudeConversation))
        }
        throw BrainChatExportParseError.unrecognisedFormat
    }

    // MARK: - ChatGPT

    static func parseChatGPTConversation(_ conversationObject: [String: Any]) -> BrainImportedChat? {
        guard let mapping = conversationObject["mapping"] as? [String: [String: Any]] else { return nil }
        let conversationID = (conversationObject["conversation_id"] as? String)
            ?? (conversationObject["id"] as? String)
            ?? ""

        // Walk from the last node the user saw up to the root, then reverse.
        // Without a current_node, follow the newest child from the root.
        var orderedNodeIDs: [String] = []
        if let currentNodeID = conversationObject["current_node"] as? String, mapping[currentNodeID] != nil {
            var visitedNodeIDs = Set<String>()
            var walkingNodeID: String? = currentNodeID
            while let nodeID = walkingNodeID, !visitedNodeIDs.contains(nodeID), let node = mapping[nodeID] {
                visitedNodeIDs.insert(nodeID)
                orderedNodeIDs.append(nodeID)
                walkingNodeID = node["parent"] as? String
            }
            orderedNodeIDs.reverse()
        } else if let rootNodeID = mapping.first(where: { ($0.value["parent"] as? String) == nil })?.key {
            var visitedNodeIDs = Set<String>()
            var walkingNodeID: String? = rootNodeID
            while let nodeID = walkingNodeID, !visitedNodeIDs.contains(nodeID), let node = mapping[nodeID] {
                visitedNodeIDs.insert(nodeID)
                orderedNodeIDs.append(nodeID)
                walkingNodeID = (node["children"] as? [String])?.last
            }
        }

        var messages: [BrainImportedChatMessage] = []
        for nodeID in orderedNodeIDs {
            guard let messageObject = mapping[nodeID]?["message"] as? [String: Any] else { continue }
            let role = (messageObject["author"] as? [String: Any])?["role"] as? String
            let speaker: BrainImportedChatMessage.Speaker
            switch role {
            case "user": speaker = .user
            case "assistant": speaker = .assistant
            default: continue
            }
            if let metadata = messageObject["metadata"] as? [String: Any],
               (metadata["is_visually_hidden_from_conversation"] as? Bool) == true {
                continue
            }
            guard let content = messageObject["content"] as? [String: Any] else { continue }
            let contentType = content["content_type"] as? String
            // "text" and "multimodal_text" hold what was said; code runs,
            // browsing results and the like are left out.
            guard contentType == "text" || contentType == "multimodal_text" else { continue }
            let textParts = (content["parts"] as? [Any] ?? []).compactMap { $0 as? String }
            let messageText = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !messageText.isEmpty else { continue }
            messages.append(BrainImportedChatMessage(speaker: speaker, text: messageText))
        }

        return BrainImportedChat(
            provider: .chatGPT,
            conversationID: conversationID,
            title: cleanedTitle(conversationObject["title"] as? String),
            createdDate: dateFromSeconds(conversationObject["create_time"]),
            updatedDate: dateFromSeconds(conversationObject["update_time"]),
            messages: messages
        )
    }

    // MARK: - Claude

    static func parseClaudeConversation(_ conversationObject: [String: Any]) -> BrainImportedChat? {
        guard let allMessageObjects = conversationObject["chat_messages"] as? [[String: Any]] else { return nil }
        let messageObjects = claudeMessagesOnCurrentBranch(allMessageObjects)
        var messages: [BrainImportedChatMessage] = []
        for messageObject in messageObjects {
            let speaker: BrainImportedChatMessage.Speaker
            switch messageObject["sender"] as? String {
            case "human": speaker = .user
            case "assistant": speaker = .assistant
            default: continue
            }
            var messageText = (messageObject["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if messageText.isEmpty, let contentBlocks = messageObject["content"] as? [[String: Any]] {
                messageText = contentBlocks
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            messageText = withoutClaudePlaceholderBlocks(messageText)
            guard !messageText.isEmpty else { continue }
            messages.append(BrainImportedChatMessage(speaker: speaker, text: messageText))
        }
        return BrainImportedChat(
            provider: .claude,
            conversationID: conversationObject["uuid"] as? String ?? "",
            title: cleanedTitle(conversationObject["name"] as? String),
            createdDate: dateFromISO8601(conversationObject["created_at"]),
            updatedDate: dateFromISO8601(conversationObject["updated_at"]),
            messages: messages
        )
    }

    /// Where a tool ran, Claude's `text` holds a fenced stand-in ("This block
    /// is not supported on your current device yet.") instead of the call.
    /// It says nothing, so it is dropped (keeping the title of anything it
    /// stood in for), and the blank lines it leaves are closed up.
    static let claudePlaceholderBlockText = "This block is not supported on your current device yet."

    static func withoutClaudePlaceholderBlocks(_ messageText: String) -> String {
        let escapedPlaceholder = NSRegularExpression.escapedPattern(for: claudePlaceholderBlockText)
        // A block made for the user (a widget, a document) carries its title on
        // the line above the stand-in; the title is kept as "[title]".
        let titledPlaceholderBlockPattern = "```[a-zA-Z]*[ \\t]*\\n[ \\t]*([^\\n`]+?)[ \\t]*\\n[ \\t]*" + escapedPlaceholder + "\\s*```"
        let barePlaceholderBlockPattern = "```[a-zA-Z]*\\s*" + escapedPlaceholder + "\\s*```"
        var cleanedText = messageText.replacingOccurrences(of: titledPlaceholderBlockPattern, with: "[$1]", options: .regularExpression)
        cleanedText = cleanedText.replacingOccurrences(of: barePlaceholderBlockPattern, with: "", options: .regularExpression)
        cleanedText = cleanedText.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude keeps every branch of a chat (an edited message or a retried
    /// answer starts a new one) in one flat list, linked by
    /// `parent_message_uuid`. The chat as the user last saw it is the path
    /// from the newest message back to the root; anything off it was
    /// abandoned. An export without the links is taken as it is.
    static func claudeMessagesOnCurrentBranch(_ messageObjects: [[String: Any]]) -> [[String: Any]] {
        var messageObjectsByID: [String: [String: Any]] = [:]
        for messageObject in messageObjects {
            if let messageID = messageObject["uuid"] as? String { messageObjectsByID[messageID] = messageObject }
        }
        guard let newestMessageID = messageObjects.last?["uuid"] as? String,
              messageObjectsByID.count == messageObjects.count,
              messageObjects.contains(where: { $0["parent_message_uuid"] is String }) else {
            return messageObjects
        }
        var branchMessageObjects: [[String: Any]] = []
        var visitedMessageIDs = Set<String>()
        var walkingMessageID: String? = newestMessageID
        while let messageID = walkingMessageID, !visitedMessageIDs.contains(messageID), let messageObject = messageObjectsByID[messageID] {
            visitedMessageIDs.insert(messageID)
            branchMessageObjects.append(messageObject)
            walkingMessageID = messageObject["parent_message_uuid"] as? String
        }
        return branchMessageObjects.reversed()
    }

    // MARK: - Choosing and rendering

    static func isWorthImporting(_ chat: BrainImportedChat) -> Bool {
        chat.userCharacterCount >= minimumUserCharacterCount
    }

    /// The transcript saved under `raw/chats/<provider>/`. The header tells the
    /// reading model whose words are whose.
    static func transcriptMarkdown(for chat: BrainImportedChat) -> String {
        let assistantName = chat.provider.displayName
        var lines: [String] = []
        lines.append("# \(chat.title)")
        lines.append("")
        var headerLine = "The user's conversation with \(assistantName), imported from their \(assistantName) export"
        if let chatDate = chat.createdDate ?? chat.updatedDate {
            headerLine += " (started \(dayFormatter.string(from: chatDate)))"
        }
        headerLine += ". Lines marked \"You\" are the user's own words; lines marked \"\(assistantName)\" are the AI's replies — only the user's lines say anything about the user."
        lines.append(headerLine)
        lines.append("")

        var bodyLines: [String] = []
        for message in chat.messages {
            let speakerName = message.speaker == .user ? "You" : assistantName
            bodyLines.append("**\(speakerName):** \(message.text)")
            bodyLines.append("")
        }
        var bodyText = bodyLines.joined(separator: "\n")
        if bodyText.count > maximumTranscriptCharacterCount {
            // The end of a long chat is usually where it landed.
            bodyText = "…\n\n" + String(bodyText.suffix(maximumTranscriptCharacterCount))
        }
        return lines.joined(separator: "\n") + "\n" + bodyText
    }

    /// `2024-03-02 Sourdough starter help.md` — dated so the folder sorts by
    /// time, with the export's id folded in so two chats with one title don't
    /// collide and a re-import lands on the same name.
    static func fileName(for chat: BrainImportedChat) -> String {
        let datePrefix = (chat.createdDate ?? chat.updatedDate).map { dayFormatter.string(from: $0) } ?? "undated"
        let safeTitle = BrainNotesImportPlanner.safePathComponent(String(chat.title.prefix(70)), fallback: "Untitled chat")
        let idSuffix = String(chat.conversationID.filter { $0.isLetter || $0.isNumber }.prefix(8))
        let idPart = idSuffix.isEmpty ? "" : " \(idSuffix)"
        return "\(datePrefix) \(safeTitle)\(idPart).md"
    }

    // MARK: - Helpers

    private static func cleanedTitle(_ rawTitle: String?) -> String {
        let trimmedTitle = (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Untitled chat" : trimmedTitle
    }

    private static func dateFromSeconds(_ rawValue: Any?) -> Date? {
        guard let seconds = rawValue as? Double, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func dateFromISO8601(_ rawValue: Any?) -> Date? {
        guard let dateText = rawValue as? String else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsedDate = fractionalFormatter.date(from: dateText) { return parsedDate }
        return ISO8601DateFormatter().date(from: dateText)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Import planning

nonisolated struct BrainChatImportState: Codable, Equatable, Sendable {
    /// A chat handed to the ingest queue but not yet read into pages.
    struct PendingChat: Codable, Equatable, Sendable {
        var conversationKey: String
        var transcriptHash: String
    }

    /// "chatGPT:<id>" / "claude:<id>" → hash of the transcript last *read*
    /// into the brain. A chat counts as imported only once its ingest job
    /// finished, so one that failed (the model was rate limited) is queued
    /// again by the next import instead of being skipped as "unchanged".
    var transcriptHashesByConversationKey: [String: String] = [:]
    /// Transcript file path → the chat it holds, while its job is queued.
    /// Optional so state files from before it existed still decode.
    var pendingChatsByTranscriptPath: [String: PendingChat]? = nil

    /// The queue finished reading this transcript: the chat is imported.
    mutating func confirmRead(transcriptPath: String) -> Bool {
        guard let pendingChat = pendingChatsByTranscriptPath?[transcriptPath] else { return false }
        transcriptHashesByConversationKey[pendingChat.conversationKey] = pendingChat.transcriptHash
        pendingChatsByTranscriptPath?[transcriptPath] = nil
        return true
    }

    static func conversationKey(for chat: BrainImportedChat) -> String {
        "\(chat.provider.rawValue):\(chat.conversationID.isEmpty ? chat.title : chat.conversationID)"
    }
}

nonisolated struct BrainChatImportPlan: Equatable, Sendable {
    struct ChatToImport: Equatable, Sendable {
        var conversationKey: String
        var fileName: String
        var transcriptMarkdown: String
        var transcriptHash: String
    }

    var chatsToImport: [ChatToImport]
    var unchangedChatCount: Int
    var tooShortChatCount: Int
    /// Left for the next import by the per-run cap.
    var deferredChatCount: Int
}

nonisolated enum BrainChatImportPlanner {
    static func plan(
        chats: [BrainImportedChat],
        state: BrainChatImportState,
        maximumChatCount: Int = BrainNotesImportPlanner.maximumFilesPerRun
    ) -> BrainChatImportPlan {
        var newOrChangedChats: [BrainChatImportPlan.ChatToImport] = []
        var unchangedChatCount = 0
        var tooShortChatCount = 0
        // Newest first, so a capped run brings the recent ones.
        let chatsNewestFirst = chats.sorted { lhs, rhs in
            (lhs.updatedDate ?? lhs.createdDate ?? .distantPast) > (rhs.updatedDate ?? rhs.createdDate ?? .distantPast)
        }
        for chat in chatsNewestFirst {
            guard BrainChatExportParser.isWorthImporting(chat) else {
                tooShortChatCount += 1
                continue
            }
            let conversationKey = BrainChatImportState.conversationKey(for: chat)
            let transcriptMarkdown = BrainChatExportParser.transcriptMarkdown(for: chat)
            let transcriptHash = BrainNotesImportPlanner.contentHash(of: transcriptMarkdown)
            if state.transcriptHashesByConversationKey[conversationKey] == transcriptHash {
                unchangedChatCount += 1
                continue
            }
            newOrChangedChats.append(BrainChatImportPlan.ChatToImport(
                conversationKey: conversationKey,
                fileName: BrainChatExportParser.fileName(for: chat),
                transcriptMarkdown: transcriptMarkdown,
                transcriptHash: transcriptHash
            ))
        }
        let keptChats = Array(newOrChangedChats.prefix(max(0, maximumChatCount)))
        return BrainChatImportPlan(
            chatsToImport: keptChats,
            unchangedChatCount: unchangedChatCount,
            tooShortChatCount: tooShortChatCount,
            deferredChatCount: newOrChangedChats.count - keptChats.count
        )
    }

    static func statusMessage(for importPlan: BrainChatImportPlan, providerName: String, queuedChatCount: Int) -> String {
        if queuedChatCount == 0 && importPlan.deferredChatCount == 0 {
            if importPlan.unchangedChatCount > 0 {
                return "nothing new — all \(importPlan.unchangedChatCount) \(providerName) chats were imported before."
            }
            return "no \(providerName) chats long enough to keep."
        }
        var message = "queued \(queuedChatCount) \(providerName) \(queuedChatCount == 1 ? "chat" : "chats") for reading"
        var asides: [String] = []
        if importPlan.unchangedChatCount > 0 { asides.append("\(importPlan.unchangedChatCount) already imported") }
        if importPlan.tooShortChatCount > 0 { asides.append("\(importPlan.tooShortChatCount) too short") }
        if !asides.isEmpty { message += " (\(asides.joined(separator: ", ")))" }
        message += "."
        if importPlan.deferredChatCount > 0 {
            message += " \(importPlan.deferredChatCount) more wait for the next import — the limit is \(BrainNotesImportPlanner.maximumFilesPerRun) per run."
        }
        return message
    }
}
