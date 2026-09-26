//
//  NotchConversationSessions.swift
//  leanring-buddy
//
//  Groups the exchanges in `AgentTaskRegistry` into conversations for the notch
//  chat's sidebar. Wisp has one ongoing conversation rather than separate
//  threads, but a pause of half an hour or more reads as a new conversation
//  to a person, so that is where the sidebar splits them. The newest session is
//  the live one — follow-ups continue it; older ones are for reading back.
//

import Foundation

struct NotchConversationSession: Identifiable, Equatable {
    /// The first exchange's id, stable while the session grows.
    let id: UUID
    /// Oldest first, the order the thread reads in.
    let exchanges: [AgentTaskRecord]

    var startedAt: Date { exchanges.first?.startedAt ?? .distantPast }
    var lastActivityAt: Date { exchanges.last?.startedAt ?? .distantPast }

    /// What the sidebar calls it: the first thing asked.
    var title: String { exchanges.first?.title ?? "Conversation" }

    /// The sidebar's second line: the latest answer, or its status while running.
    var latestAnswerPreview: String {
        guard let latestExchange = exchanges.last else { return "" }
        switch latestExchange.status {
        case .running, .waitingForApproval:
            return "Working on it…"
        case .failed:
            return "Didn't go through"
        case .cancelled:
            return "Stopped"
        case .interrupted:
            return "Interrupted"
        case .succeeded:
            let answerText = (latestExchange.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return answerText.isEmpty ? "Done" : answerText
        }
    }

    static func == (lhs: NotchConversationSession, rhs: NotchConversationSession) -> Bool {
        lhs.id == rhs.id
            && lhs.exchanges.map(\.id) == rhs.exchanges.map(\.id)
            && lhs.exchanges.map(\.status) == rhs.exchanges.map(\.status)
    }
}

enum NotchConversationSessionGrouper {
    /// A gap at least this long between exchanges starts a new conversation.
    static let newConversationGapSeconds: TimeInterval = 30 * 60
    /// The most sessions the sidebar lists.
    static let maximumSessions = 40

    /// Sessions newest first. Only the user's conversation counts: dictation
    /// isn't a question and background tasks have their own place in the notch.
    static func sessions(from records: [AgentTaskRecord]) -> [NotchConversationSession] {
        let exchangesOldestFirst = records
            .filter { record in
                record.kind == .interactive
                    && !record.title.hasPrefix(AgentTaskRecord.dictationTitlePrefix)
            }
            .sorted { $0.startedAt < $1.startedAt }

        var sessionsOldestFirst: [[AgentTaskRecord]] = []
        for exchange in exchangesOldestFirst {
            if let previousExchange = sessionsOldestFirst.last?.last,
               exchange.startedAt.timeIntervalSince(previousExchange.startedAt) < newConversationGapSeconds {
                sessionsOldestFirst[sessionsOldestFirst.count - 1].append(exchange)
            } else {
                sessionsOldestFirst.append([exchange])
            }
        }

        return sessionsOldestFirst
            .reversed()
            .prefix(maximumSessions)
            .compactMap { sessionExchanges in
                guard let firstExchange = sessionExchanges.first else { return nil }
                return NotchConversationSession(id: firstExchange.id, exchanges: sessionExchanges)
            }
    }

    /// Sessions containing `searchText` in any question or answer, case- and
    /// diacritic-insensitive. Blank search keeps them all.
    static func sessions(
        _ sessions: [NotchConversationSession],
        matching searchText: String
    ) -> [NotchConversationSession] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return sessions }
        return sessions.filter { session in
            session.exchanges.contains { exchange in
                exchange.title.range(of: trimmedSearchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || (exchange.finalText ?? "").range(of: trimmedSearchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
