//
//  BuddyGroup.swift
//  leanring-buddy
//
//  Shared group chats, after OpenBot's channels: several buddies in one chat
//  with one shared history. Each message from the user is answered by exactly
//  one buddy, the task owner, chosen by the rules here; the owner may hand the
//  task to a teammate with an explicit tag, and a hop cap stops two buddies
//  passing it back and forth. Everything below is pure so `Tests/BuddyGroup`
//  checks it without the app. Running the buddies is `BuddyGroupEngine`.
//
//  Routing is deterministic on purpose. OpenBot asks a lead model to pick the
//  owner; Wisp's default model is a 3B that cannot be trusted to route, and a
//  wrong guess would cost a full run, so the order is: the buddy the user
//  addressed with @Name, else whoever answered last, else the lead, else the
//  first member.
//

import Foundation

struct BuddyGroup: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Member buddy ids, in the order shown.
    var memberIDs: [UUID]
    /// Answers first when nobody is addressed and nobody has answered yet.
    var leadID: UUID?
    let createdAt: Date
    var isArchived: Bool?

    var isArchivedInList: Bool { isArchived ?? false }
}

struct BuddyGroupMessage: Codable, Identifiable, Equatable {
    enum Author: Codable, Equatable {
        case user
        case buddy(UUID)
        /// Wisp itself: a failure, a stop, a handoff notice.
        case notice
    }

    let id: UUID
    let author: Author
    var text: String
    let createdAt: Date
    /// The run that produced it, for a buddy's message.
    var taskID: UUID?
}

/// A name and id, so the pure rules never see a whole buddy.
struct BuddyGroupMember: Equatable {
    let id: UUID
    let name: String
}

enum BuddyGroupPolicy {
    /// How many times one user message may be handed on. Two buddies that keep
    /// delegating to each other stop here.
    static let maximumHandoffsPerMessage = 3
    static let maximumStoredMessages = 200
    /// Past messages put in front of the model. Each costs prompt tokens.
    static let maximumMessagesInPrompt = 12
    static let maximumCharactersPerMessageInPrompt = 800

    // MARK: Routing

    struct Routing: Equatable {
        let ownerID: UUID
        /// The user's words with a leading @Name removed (it was addressing, not content).
        let text: String
        let reason: Reason

        enum Reason: Equatable { case addressed, continuedConversation, lead, firstMember }
    }

    /// Who answers `userText`. Nil only when the group has no members.
    static func route(
        userText: String,
        members: [BuddyGroupMember],
        leadID: UUID?,
        lastOwnerID: UUID?
    ) -> Routing? {
        guard !members.isEmpty else { return nil }
        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let addressed = leadingAddress(in: trimmedText, members: members) {
            let remainingText = addressed.remainingText.isEmpty ? trimmedText : addressed.remainingText
            return Routing(ownerID: addressed.member.id, text: remainingText, reason: .addressed)
        }
        if let lastOwnerID, members.contains(where: { $0.id == lastOwnerID }) {
            return Routing(ownerID: lastOwnerID, text: trimmedText, reason: .continuedConversation)
        }
        if let leadID, members.contains(where: { $0.id == leadID }) {
            return Routing(ownerID: leadID, text: trimmedText, reason: .lead)
        }
        return Routing(ownerID: members[0].id, text: trimmedText, reason: .firstMember)
    }

    /// "@Mia what's new" → Mia and "what's new". The longest name wins, so
    /// "@Gmail Digest" is not read as a buddy called "Gmail". The name must end
    /// at a word boundary: "@Miami" is not Mia.
    static func leadingAddress(in text: String, members: [BuddyGroupMember]) -> (member: BuddyGroupMember, remainingText: String)? {
        guard text.hasPrefix("@") else { return nil }
        let afterAt = String(text.dropFirst())
        for member in members.sorted(by: { $0.name.count > $1.name.count }) {
            guard afterAt.range(of: member.name, options: [.anchored, .caseInsensitive]) != nil else { continue }
            let remainder = afterAt.dropFirst(member.name.count)
            if let next = remainder.first, next.isLetter || next.isNumber { continue }
            let remaining = remainder
                .trimmingCharacters(in: CharacterSet(charactersIn: ",:;— -").union(.whitespacesAndNewlines))
            return (member, remaining)
        }
        return nil
    }

    // MARK: Handoff

    struct Handoff: Equatable {
        /// The answer with the tag removed.
        let visibleText: String
        let target: BuddyGroupMember
        /// What to ask the teammate; the visible text when the tag has none.
        let request: String
    }

    /// Finds a `[HANDOFF:Name]` or `[HANDOFF:Name: what to ask]` tag. Only a
    /// teammate other than the sender counts, and only the first tag is used.
    /// Unknown names are ignored: the tag is stripped but nothing is handed on.
    static func parseHandoff(
        in answerText: String,
        members: [BuddyGroupMember],
        senderID: UUID
    ) -> (visibleText: String, handoff: Handoff?) {
        guard let tagRange = answerText.range(of: #"\[HANDOFF:[^\]]*\]"#, options: .regularExpression) else {
            return (answerText, nil)
        }
        let tagBody = answerText[tagRange].dropFirst("[HANDOFF:".count).dropLast()
        let visibleText = answerText
            .replacingOccurrences(of: #"\s*\[HANDOFF:[^\]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nameAndRequest = tagBody.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let nameText = nameAndRequest.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let requestText = nameAndRequest.count > 1 ? nameAndRequest[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard let target = members.first(where: { $0.id != senderID && $0.name.caseInsensitiveCompare(nameText) == .orderedSame }) else {
            return (visibleText, nil)
        }
        return (visibleText, Handoff(visibleText: visibleText, target: target, request: requestText.isEmpty ? visibleText : requestText))
    }

    // MARK: Prompt

    /// The shared history as one buddy sees it: its own earlier answers are
    /// its (assistant) turns; the user and every teammate are the other side,
    /// labelled so it knows who spoke. Consecutive messages on one side are
    /// merged so the roles alternate, and the list starts with the other side.
    static func historyMessages(
        for buddyID: UUID,
        in messages: [BuddyGroupMessage],
        members: [BuddyGroupMember],
        userName: String = "User"
    ) -> [BuddyChatMessage] {
        mergedHistory(for: buddyID, in: messages, members: members, userName: userName)
    }

    /// The same history, but ending on the buddy's own turn: whatever the user
    /// and teammates said after it comes back as `leadIn` text for the new
    /// request, because a request that follows a user-side message would put
    /// two user turns in a row.
    static func historyAndLeadIn(
        for buddyID: UUID,
        in messages: [BuddyGroupMessage],
        members: [BuddyGroupMember],
        userName: String = "User"
    ) -> (history: [BuddyChatMessage], leadIn: String?) {
        var history = mergedHistory(for: buddyID, in: messages, members: members, userName: userName)
        guard let last = history.last, last.role == .user else { return (history, nil) }
        history.removeLast()
        return (history, last.combinedText)
    }

    private static func mergedHistory(
        for buddyID: UUID,
        in messages: [BuddyGroupMessage],
        members: [BuddyGroupMember],
        userName: String
    ) -> [BuddyChatMessage] {
        func memberName(_ id: UUID) -> String { members.first { $0.id == id }?.name ?? "A teammate" }
        var merged: [(isOwn: Bool, text: String)] = []
        for message in messages.suffix(maximumMessagesInPrompt) {
            let clipped = String(message.text.prefix(maximumCharactersPerMessageInPrompt))
            guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let isOwn: Bool
            let text: String
            switch message.author {
            case .user: (isOwn, text) = (false, "\(userName): \(clipped)")
            case .buddy(let authorID) where authorID == buddyID: (isOwn, text) = (true, clipped)
            case .buddy(let authorID): (isOwn, text) = (false, "\(memberName(authorID)): \(clipped)")
            case .notice: continue
            }
            if let last = merged.last, last.isOwn == isOwn {
                merged[merged.count - 1].text += "\n\n" + text
            } else {
                merged.append((isOwn, text))
            }
        }
        while merged.first?.isOwn == true { merged.removeFirst() }
        return merged.map { BuddyChatMessage(role: $0.isOwn ? .assistant : .user, text: $0.text) }
    }

    /// Added to the buddy's system prompt for a group run.
    static func systemPromptAddendum(groupName: String, members: [BuddyGroupMember], buddyID: UUID) -> String {
        let teammates = members.filter { $0.id != buddyID }.map(\.name)
        let handoffLine = teammates.isEmpty
            ? ""
            : """

            If a teammate is better placed to take this, answer briefly and end with \
            [HANDOFF:Name: what to ask them] using one of: \(teammates.joined(separator: ", ")). \
            Only hand off when it truly helps; otherwise just answer.
            """
        return """


        You are in a group chat called "\(groupName)" with the user and your teammates \
        (\(teammates.isEmpty ? "none" : teammates.joined(separator: ", "))). The conversation above is shared; \
        lines start with who spoke. You were chosen to answer the latest message, so answer it \
        directly and briefly, in your own voice, without repeating what a teammate already said.\(handoffLine)
        """
    }

    /// The transcript split around the user's latest message: what came before
    /// it (the model's history), that message, and what teammates said after it
    /// (a buddy that takes over needs to see those).
    struct TurnContext: Equatable {
        let prior: [BuddyGroupMessage]
        let latestUserText: String?
        let teammateLines: [String]
    }

    static func turnContext(in messages: [BuddyGroupMessage], members: [BuddyGroupMember]) -> TurnContext {
        guard let lastUserIndex = messages.lastIndex(where: { $0.author == .user }) else {
            return TurnContext(prior: messages, latestUserText: nil, teammateLines: [])
        }
        let teammateLines = messages[(lastUserIndex + 1)...].compactMap { message -> String? in
            guard case .buddy(let authorID) = message.author else { return nil }
            let name = members.first { $0.id == authorID }?.name ?? "A teammate"
            return "\(name): " + String(message.text.prefix(maximumCharactersPerMessageInPrompt))
        }
        return TurnContext(
            prior: Array(messages[..<lastUserIndex]),
            latestUserText: messages[lastUserIndex].text,
            teammateLines: teammateLines
        )
    }

    /// The request a run receives. For the first answer it is the user's words;
    /// after a handoff it also carries what teammates have said since and what
    /// the teammate asked, so the new owner is not working blind.
    static func runRequestText(
        requestText: String,
        context: TurnContext,
        handedOffBy handerName: String?,
        leadIn: String? = nil
    ) -> String {
        var parts: [String] = []
        if let leadIn { parts.append("Earlier in the group:\n" + leadIn) }
        guard let handerName else { return (parts + [requestText]).joined(separator: "\n\n") }
        if let latestUserText = context.latestUserText { parts.append("The user wrote: \(latestUserText)") }
        if !context.teammateLines.isEmpty { parts.append("Said since:\n" + context.teammateLines.joined(separator: "\n")) }
        parts.append("\(handerName) handed this to you: \(requestText)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: Transcript

    static func appending(_ message: BuddyGroupMessage, to messages: [BuddyGroupMessage]) -> [BuddyGroupMessage] {
        let combined = messages + [message]
        return combined.count > maximumStoredMessages ? Array(combined.suffix(maximumStoredMessages)) : combined
    }

    /// The buddy who answered last, for "continue with whoever was talking".
    static func lastOwnerID(in messages: [BuddyGroupMessage]) -> UUID? {
        for message in messages.reversed() {
            if case .buddy(let buddyID) = message.author { return buddyID }
        }
        return nil
    }

    /// Group name suggestion from its members: "Mia, Sam & Kit".
    static func suggestedName(memberNames: [String]) -> String {
        switch memberNames.count {
        case 0: return "New group"
        case 1: return memberNames[0]
        case 2: return "\(memberNames[0]) & \(memberNames[1])"
        default: return memberNames.dropLast().joined(separator: ", ") + " & " + memberNames.last!
        }
    }
}
