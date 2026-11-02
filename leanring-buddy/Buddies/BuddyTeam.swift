//
//  BuddyTeam.swift
//  leanring-buddy
//
//  What a buddy can do about its teammates (phase 4 of
//  docs/openbot-buddies-plan.md), modelled on OpenBot's `list_agents`,
//  `start_task`, `create_agent` and its delegation policy:
//
//  - `list_buddies` — who the other buddies are, what each one does and
//    whether it is free, so a buddy can pick the right one to ask.
//  - `ask_buddy` with several names — the same question to a few buddies at
//    once, their answers gathered into one result (OpenBot's multi-recipient
//    requests, whose answers start together in one turn).
//  - `start_thread` — a buddy splits a piece of work into a side thread of its
//    own, which runs in its own lane and answers there.
//  - `create_buddy` — a new teammate, only after the user approves the card.
//    It gets the creating buddy's model, runtime and tool limits, never more,
//    so a buddy can't make itself a less limited copy.
//
//  And the report rules OpenBot's teammates follow (`BuddyThreadPolicy.blockedReportRules`): a buddy that is blocked
//  says so in four lines (Status, Result, Evidence, Unblock), and the buddy
//  that asked passes the blocker to the user instead of asking again.
//
//  Everything here is pure and tested by `Tests/AgentRuntimeIntegration`
//  (BuddyTeamTests); the tools themselves are in `BuddyDelegation.swift`.
//

import Foundation

enum BuddyTeamToolNames {
    static let listBuddies = "list_buddies"
    static let startThread = "start_thread"
    static let createBuddy = "create_buddy"

    /// Every run-only teammate tool, all in the "Other buddies" tool group.
    static let all: Set<String> = [BuddyDelegationToolNames.askBuddy, listBuddies, startThread, createBuddy]
}

/// What `list_buddies` says about one peer.
struct BuddyPeerStatus: Equatable {
    enum State: Equatable {
        case free
        case working
        case waitingForApproval
    }

    var state: State = .free
    /// Messages in its line, waiting for it.
    var waitingMessageCount = 0
    /// When it last started something, if ever.
    var lastActivityAt: Date?
}

enum BuddyTeamPolicy {
    /// Peers asked in one `ask_buddy` call. More is a broadcast, not a question.
    static let maximumBuddiesPerAsk = 4
    /// Side threads a buddy may have open before `start_thread` says no
    /// (OpenBot allows an agent 8 open tasks it started itself).
    static let maximumOpenSideThreads = 8
    /// New buddies one run may create, each after its own approval.
    static let maximumBuddiesCreatedPerRun = 2
    static let maximumJobCharactersInListing = 300
    static let maximumNewBuddyNameCharacters = 40
    static let maximumNewBuddyJobCharacters = 600
    static let maximumThreadTaskCharacters = 1500

    // MARK: list_buddies

    static func peerListing(
        _ peers: [(buddy: WispBuddy, status: BuddyPeerStatus)],
        now: Date = Date()
    ) -> String {
        guard !peers.isEmpty else { return "you have no other buddies." }
        return peers.map { peer in
            let job = String(peer.buddy.instruction.prefix(maximumJobCharactersInListing))
                + (peer.buddy.instruction.count > maximumJobCharactersInListing ? "…" : "")
            var stateText: String
            switch peer.status.state {
            case .free: stateText = "free"
            case .working: stateText = "working"
            case .waitingForApproval: stateText = "waiting for the user's ok"
            }
            if peer.status.waitingMessageCount > 0 {
                stateText += ", \(peer.status.waitingMessageCount) message\(peer.status.waitingMessageCount == 1 ? "" : "s") waiting"
            }
            var line = "- \(peer.buddy.name): \(job) [\(stateText)"
            if let lastActivityAt = peer.status.lastActivityAt {
                line += ", last active \(relativeTimeText(from: lastActivityAt, to: now))"
            }
            return line + "]"
        }.joined(separator: "\n")
    }

    static func relativeTimeText(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    // MARK: ask_buddy with several names

    /// The names one call asks, from its `buddy` and `buddies` arguments:
    /// trimmed, blanks dropped, repeats (ignoring case) dropped, capped.
    static func requestedNames(single: String?, several: [String]) -> [String] {
        var names: [String] = []
        for name in ([single].compactMap { $0 } + several) {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !names.contains(where: { $0.lowercased() == trimmedName.lowercased() }) else { continue }
            names.append(trimmedName)
        }
        return Array(names.prefix(maximumBuddiesPerAsk))
    }

    /// How several answers come back: each teammate's own paragraph, in the
    /// order asked, so the caller can attribute each one.
    static func gatheredAnswers(_ answerTexts: [String]) -> String {
        answerTexts.joined(separator: "\n\n")
    }

    // MARK: Report rules

    /// In the description of the teammate tools: what to do with a peer's answer.
    static let answerHandlingRules = """
    Start what you tell the user about a buddy's result with that buddy's name. \
    If a buddy reports it is blocked, don't ask it or another buddy the same thing again: \
    tell the user what is blocking and the Unblock step.
    """

    // MARK: start_thread

    enum ThreadStart: Equatable {
        case started
        case queued
        case tooManyOpenThreads
        case failed
    }

    static func threadStartReply(_ threadStart: ThreadStart, taskText: String) -> String {
        switch threadStart {
        case .started:
            return "started a new thread for \"\(taskText.prefix(60))\". it runs on its own and its answer shows in that thread, not here; carry on with your own work."
        case .queued:
            return "made a new thread for \"\(taskText.prefix(60))\". it starts as soon as one of your other threads finishes, and answers there."
        case .tooManyOpenThreads:
            return "you already have \(maximumOpenSideThreads) side threads. finish this here instead."
        case .failed:
            return "couldn't start a new thread. do it here instead."
        }
    }

    // MARK: create_buddy

    struct NewBuddyDraft: Equatable {
        let name: String?
        let job: String
        let schedule: BuddySchedule
    }

    /// The new buddy the model asked for, or the reason it can't be made.
    static func newBuddyDraft(name rawName: String?, job rawJob: String?) -> Result<NewBuddyDraft, NewBuddyRefusal> {
        let job = (rawJob ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !job.isEmpty else { return .failure(.noJob) }
        guard job.count <= maximumNewBuddyJobCharacters else { return .failure(.jobTooLong) }
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(NewBuddyDraft(
            name: name.flatMap { $0.isEmpty ? nil : String($0.prefix(maximumNewBuddyNameCharacters)) },
            job: job,
            schedule: BuddySchedule.inferred(fromInstruction: job)
        ))
    }

    enum NewBuddyRefusal: Error, Equatable {
        case noJob
        case jobTooLong

        var replyText: String {
            switch self {
            case .noJob: return "i need the new buddy's job."
            case .jobTooLong: return "that job is too long; describe it in a few sentences."
            }
        }
    }

    /// When the new buddy first runs, for the approval card: a one-off job runs
    /// as soon as it is made, a repeating one at its first slot.
    static func firstRunText(for schedule: BuddySchedule) -> String {
        schedule.isRepeating ? schedule.summary() : "Starts on its job as soon as it's made"
    }
}
