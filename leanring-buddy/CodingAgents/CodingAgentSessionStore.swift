//
//  CodingAgentSessionStore.swift
//  leanring-buddy
//
//  The live picture of the user's coding agents — every Claude Code, Gemini
//  CLI or Antigravity session that has sent a hook event — and the permission
//  requests waiting on the user. Fed by `CodingAgentHookServer`; read by the
//  notch (CODING section, approval card, flank count) and the Wisp window's
//  Connections → Coding Agents page.
//
//  Nothing here is persisted: a session is only interesting while it runs.
//  An approval that isn't answered within `approvalTimeoutSeconds` is handed
//  back to the terminal ("no decision"), never denied or allowed on its own.
//

import Combine
import Foundation

enum CodingAgentSessionState: Equatable {
    case idle
    case thinking
    case working
    case waitingForInput
    case waitingForApproval
    case rateLimited
    case finished
    case failed

    var isBusy: Bool {
        self == .thinking || self == .working
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .waitingForInput: return "Waiting for you"
        case .waitingForApproval: return "Needs your ok"
        case .rateLimited: return "Rate limited"
        case .finished: return "Done"
        case .failed: return "Stopped with an error"
        }
    }
}

struct CodingAgentSession: Identifiable, Equatable {
    /// Agent + session id, so two agents can't collide on an id.
    let id: String
    let agentKind: CodingAgentKind
    var projectName: String
    var workingDirectoryPath: String
    var terminalContext: CodingAgentTerminalContext
    var state: CodingAgentSessionState
    /// Recent steps, oldest first, capped at `CodingAgentSessionStore.maximumStepCount`.
    var steps: [String]
    var lastPrompt: String?
    let startedDate: Date
    var lastActivityDate: Date
    var runningSubagentCount: Int

    var latestStep: String? { steps.last }
}

struct CodingAgentApprovalRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let agentKind: CodingAgentKind
    let projectName: String
    let details: CodingAgentPermissionRequestDetails
    let receivedDate: Date
    let responder: CodingAgentPermissionResponder
}

/// A session that just finished or failed — the notch shows it briefly.
struct CodingAgentCompletion: Equatable {
    let sessionID: String
    let agentName: String
    let projectName: String
    let didFail: Bool
    let summary: String
    let date: Date
}

/// The user's switches for coding agents (Connections → Coding Agents).
@MainActor
final class CodingAgentPreferences: ObservableObject {
    static let shared = CodingAgentPreferences()

    private static let notchApprovalsKey = "codingAgentNotchApprovalsEnabled"
    private static let announceFinishedKey = "codingAgentAnnounceFinishedEnabled"

    /// On, Claude Code's permission prompts appear in the notch with Allow /
    /// Deny. Off, they're handed straight back to the terminal.
    @Published var areNotchApprovalsEnabled: Bool {
        didSet { UserDefaults.standard.set(areNotchApprovalsEnabled, forKey: Self.notchApprovalsKey) }
    }

    /// On, the notch drops a short "done" card when a session finishes.
    @Published var isAnnouncingFinishedSessions: Bool {
        didSet { UserDefaults.standard.set(isAnnouncingFinishedSessions, forKey: Self.announceFinishedKey) }
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.notchApprovalsKey: true,
            Self.announceFinishedKey: true,
        ])
        areNotchApprovalsEnabled = UserDefaults.standard.bool(forKey: Self.notchApprovalsKey)
        isAnnouncingFinishedSessions = UserDefaults.standard.bool(forKey: Self.announceFinishedKey)
    }
}

@MainActor
final class CodingAgentSessionStore: ObservableObject {
    static let shared = CodingAgentSessionStore()

    static let maximumStepCount = 20
    /// Claude Code waits 120s for the hook; answering "no decision" a little
    /// before that lets it fall back to its own prompt cleanly.
    static let approvalTimeoutSeconds: TimeInterval = 112
    /// A session with no events for this long is dropped from the list.
    static let inactiveSessionRemovalSeconds: TimeInterval = 30 * 60
    /// How long a finished session keeps its ✓ before going back to idle.
    static let finishedStateDisplaySeconds: TimeInterval = 5 * 60

    /// Most recently active first.
    @Published private(set) var sessions: [CodingAgentSession] = []
    /// Oldest first — the notch answers them in order.
    @Published private(set) var pendingApprovals: [CodingAgentApprovalRequest] = []
    @Published private(set) var latestCompletion: CodingAgentCompletion?
    /// When the last event of any kind arrived, for the Connections page.
    @Published private(set) var lastEventDate: Date?

    private var housekeepingTimer: Timer?

    private init() {}

    var busySessions: [CodingAgentSession] {
        sessions.filter { $0.state.isBusy }
    }

    var oldestPendingApproval: CodingAgentApprovalRequest? {
        pendingApprovals.first
    }

    /// Starts the socket server and the minute housekeeping.
    func start() {
        CodingAgentHookServer.shared.start { hookEvent, permissionResponder in
            CodingAgentSessionStore.shared.handle(hookEvent, permissionResponder: permissionResponder)
        }
        guard housekeepingTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                CodingAgentSessionStore.shared.performHousekeeping()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
    }

    // MARK: - Events

    func handle(_ hookEvent: CodingAgentHookEvent, permissionResponder: CodingAgentPermissionResponder?) {
        lastEventDate = Date()
        let sessionID = Self.sessionID(for: hookEvent)
        var session = sessions.first { $0.id == sessionID } ?? CodingAgentSession(
            id: sessionID,
            agentKind: hookEvent.agentKind,
            projectName: hookEvent.projectName,
            workingDirectoryPath: hookEvent.workingDirectoryPath,
            terminalContext: hookEvent.terminalContext,
            state: .idle,
            steps: [],
            lastPrompt: nil,
            startedDate: Date(),
            lastActivityDate: Date(),
            runningSubagentCount: 0
        )
        session.lastActivityDate = Date()
        if !hookEvent.workingDirectoryPath.isEmpty {
            session.workingDirectoryPath = hookEvent.workingDirectoryPath
            session.projectName = hookEvent.projectName
        }
        mergeTerminalContext(hookEvent.terminalContext, into: &session)

        // The session moved past its permission question (the user answered
        // it in the terminal, or the agent gave up on it), so a card still
        // showing for it is stale.
        switch hookEvent.kind {
        case .toolFinished, .toolFailed, .promptSubmitted, .stopped, .stoppedWithFailure:
            withdrawPendingApprovals(forSessionID: sessionID)
            if session.state == .waitingForApproval { session.state = .working }
        default:
            break
        }

        switch hookEvent.kind {
        case .sessionStarted:
            session.state = .idle
        case .promptSubmitted(let promptText):
            session.state = .thinking
            session.lastPrompt = promptText.isEmpty ? nil : promptText
            session.steps = []
        case .toolStarting(let stepDescription):
            session.state = .working
            appendStep(stepDescription, to: &session)
        case .toolFinished:
            if session.state != .waitingForApproval { session.state = .working }
        case .toolFailed:
            session.state = .working
            appendStep("⚠︎ That step failed", to: &session)
        case .notification(let message, let category):
            switch category {
            case .rateLimited:
                session.state = .rateLimited
                appendStep(message, to: &session)
            case .waitingForInput:
                // Claude Code also sends "needs your permission" while a
                // permission card is up; that card already says so.
                if session.state != .waitingForApproval {
                    session.state = .waitingForInput
                }
            case .informational:
                if !message.isEmpty { appendStep(message, to: &session) }
            }
        case .stopped(let finalMessage):
            session.state = .finished
            session.runningSubagentCount = 0
            if !finalMessage.isEmpty { appendStep(finalMessage, to: &session) }
            announceCompletion(of: session, didFail: false, summary: finalMessage)
        case .stoppedWithFailure:
            session.state = .failed
            session.runningSubagentCount = 0
            announceCompletion(of: session, didFail: true, summary: "Stopped with an error")
        case .sessionEnded:
            removeSession(withID: sessionID)
            return
        case .subagentStarted:
            session.runningSubagentCount += 1
            appendStep("Started a subagent", to: &session)
        case .subagentStopped:
            session.runningSubagentCount = max(0, session.runningSubagentCount - 1)
        case .permissionRequested(let permissionDetails):
            session.state = .waitingForApproval
            upsert(session)
            receivePermissionRequest(permissionDetails, session: session, permissionResponder: permissionResponder)
            return
        case .unrecognized:
            break
        }
        upsert(session)
    }

    // MARK: - Approvals

    private func receivePermissionRequest(
        _ permissionDetails: CodingAgentPermissionRequestDetails,
        session: CodingAgentSession,
        permissionResponder: CodingAgentPermissionResponder?
    ) {
        guard let permissionResponder else { return }
        guard session.agentKind.supportsNotchApprovals,
              CodingAgentPreferences.shared.areNotchApprovalsEnabled else {
            permissionResponder.answer(.noDecision)
            return
        }
        // One question per session at a time: an older one still showing has
        // already been abandoned by the agent.
        withdrawPendingApprovals(forSessionID: session.id)

        let approvalRequest = CodingAgentApprovalRequest(
            sessionID: session.id,
            agentKind: session.agentKind,
            projectName: session.projectName,
            details: permissionDetails,
            receivedDate: Date(),
            responder: permissionResponder
        )
        pendingApprovals.append(approvalRequest)
        WispSoundPlayer.shared.play(.reply)

        let approvalID = approvalRequest.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.approvalTimeoutSeconds) {
            MainActor.assumeIsolated {
                CodingAgentSessionStore.shared.answer(approvalWithID: approvalID, decision: .noDecision)
            }
        }
    }

    /// Answers a pending approval (from the notch card, or the timeout).
    func answer(approvalWithID approvalID: UUID, decision: CodingAgentPermissionDecision) {
        guard let approvalIndex = pendingApprovals.firstIndex(where: { $0.id == approvalID }) else { return }
        let approvalRequest = pendingApprovals.remove(at: approvalIndex)
        approvalRequest.responder.answer(decision)

        guard var session = sessions.first(where: { $0.id == approvalRequest.sessionID }) else { return }
        switch decision {
        case .allow, .alwaysAllow:
            session.state = .working
        case .deny:
            session.state = .working
            appendStep("You declined: \(approvalRequest.details.toolName)", to: &session)
        case .noDecision:
            session.state = .waitingForInput
            appendStep("Asked in the terminal instead", to: &session)
        }
        upsert(session)
    }

    // MARK: - Session list

    private func upsert(_ session: CodingAgentSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
    }

    func removeSession(withID sessionID: String) {
        withdrawPendingApprovals(forSessionID: sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    private func withdrawPendingApprovals(forSessionID sessionID: String) {
        for abandonedApproval in pendingApprovals where abandonedApproval.sessionID == sessionID {
            abandonedApproval.responder.answer(.noDecision)
        }
        pendingApprovals.removeAll { $0.sessionID == sessionID }
    }

    func dismissLatestCompletion() {
        latestCompletion = nil
    }

    private func announceCompletion(of session: CodingAgentSession, didFail: Bool, summary: String) {
        latestCompletion = CodingAgentCompletion(
            sessionID: session.id,
            agentName: session.agentKind.displayName,
            projectName: session.projectName,
            didFail: didFail,
            summary: summary,
            date: Date()
        )
    }

    private func appendStep(_ stepText: String, to session: inout CodingAgentSession) {
        session.steps.append(stepText)
        if session.steps.count > Self.maximumStepCount {
            session.steps.removeFirst(session.steps.count - Self.maximumStepCount)
        }
    }

    /// A field the relay couldn't read on this event (e.g. the tty, which is
    /// only looked up on some events) keeps its earlier value.
    private func mergeTerminalContext(_ newContext: CodingAgentTerminalContext, into session: inout CodingAgentSession) {
        if !newContext.terminalProgram.isEmpty { session.terminalContext.terminalProgram = newContext.terminalProgram }
        if !newContext.hostApplicationBundleIdentifier.isEmpty {
            session.terminalContext.hostApplicationBundleIdentifier = newContext.hostApplicationBundleIdentifier
        }
        if !newContext.iTermSessionIdentifier.isEmpty {
            session.terminalContext.iTermSessionIdentifier = newContext.iTermSessionIdentifier
        }
        if !newContext.terminalDevicePath.isEmpty { session.terminalContext.terminalDevicePath = newContext.terminalDevicePath }
    }

    private func performHousekeeping() {
        let now = Date()
        for session in sessions where now.timeIntervalSince(session.lastActivityDate) > Self.inactiveSessionRemovalSeconds {
            // A session waiting on a held approval is never "inactive".
            guard session.state != .waitingForApproval else { continue }
            removeSession(withID: session.id)
        }
        sessions = sessions.map { session in
            var settledSession = session
            let isStaleFinish = (session.state == .finished || session.state == .failed)
                && now.timeIntervalSince(session.lastActivityDate) > Self.finishedStateDisplaySeconds
            if isStaleFinish { settledSession.state = .idle }
            return settledSession
        }
    }

    private static func sessionID(for hookEvent: CodingAgentHookEvent) -> String {
        "\(hookEvent.agentKind.displayName)|\(hookEvent.sessionIdentifier)"
    }
}
