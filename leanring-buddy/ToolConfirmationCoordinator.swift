//
//  ToolConfirmationCoordinator.swift
//  leanring-buddy
//
//  Asks the user before running a tool that could change something.
//
//  Tools reach here for two reasons, and both matter. Some genuinely act on
//  the world — writing a file, sending something — and should never run
//  unasked. And the local model has been measured occasionally inventing a
//  tool call on a turn that needed none, which is tolerable for a tool that
//  only reads and is not tolerable for one that does not.
//
//  The interaction is deliberately spoken, because this is a voice assistant
//  and the user's hands are usually elsewhere. The assistant says what it
//  wants to do; the next push-to-talk is treated as the answer rather than as
//  a new question.
//
//  Three defaults keep an unanswered prompt from doing harm:
//
//  * Silence times out, and a timeout denies.
//  * Anything that isn't a clear yes is a no. "Maybe", a half-sentence, or a
//    misheard word all decline, because the cost of wrongly declining is one
//    repeated request, while wrongly accepting is an action the user never
//    asked for.
//  * A denial is reported to the model as a normal tool result, so it can say
//    something sensible instead of failing the turn.
//

import Combine

/// Whoever decides whether a tool may run.
///
/// A protocol so the tool registry depends on the decision rather than on the
/// spoken-confirmation UI, which is what makes the boundary testable without a
/// microphone, a user, or a running app.
@MainActor
protocol ToolPermissionBroker: AnyObject {
    func requestApproval(toolName: String, argumentSummary: String) async -> ToolConfirmationCoordinator.Decision

    /// Asks with the call's structured arguments rather than a one-line summary,
    /// so the broker can judge the call (the destructive floor under session
    /// auto-approve) and describe it (the rich confirmation card).
    func requestApproval(toolName: String, toolInput: JSONValue) async -> ToolConfirmationCoordinator.Decision
}

extension ToolPermissionBroker {
    /// A broker that only understands summaries — a test stub, say — still
    /// works: it is asked with the compact JSON, exactly as before.
    func requestApproval(toolName: String, toolInput: JSONValue) async -> ToolConfirmationCoordinator.Decision {
        await requestApproval(toolName: toolName, argumentSummary: toolInput.compactDescription)
    }
}
import Foundation

@MainActor
final class ToolConfirmationCoordinator: ObservableObject, ToolPermissionBroker {
    static let shared = ToolConfirmationCoordinator()

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let toolName: String
        /// Plain-language description of what is about to happen.
        let spokenQuestion: String
        let argumentSummary: String
        let requestedAt: Date
        /// What the call will do, as a glance card — "New Email" with To and
        /// Subject, a file write with its path — built deterministically from
        /// the arguments by `ToolConfirmationCardBuilder`. Nil for a tool with
        /// no recognisable shape, in which case the panel shows the plain
        /// summary exactly as it always has. Display-only.
        let confirmationCard: GlanceCard?
        /// Set for a `send_imessage` call: the panel is then drawn as a
        /// Siri-style message (avatar, bubble, Send) instead of a tool card.
        var messageDraft: MessageSendDraft? = nil
    }

    enum Decision: Equatable {
        case approved
        case declined(reason: String)

        var isApproved: Bool {
            if case .approved = self { return true }
            return false
        }
    }

    /// Unanswered prompts expire. Long enough to walk back to the keyboard,
    /// short enough that a forgotten prompt doesn't leave a turn hanging.
    static let confirmationTimeoutSeconds: TimeInterval = 45

    @Published private(set) var pendingConfirmation: PendingConfirmation?

    /// When on, tool calls are approved without asking, until the app restarts.
    /// Deliberately session-scoped and not persisted: a blanket "always approve"
    /// that survived relaunches would be too easy to forget you left on. Reset
    /// every launch so the safe default (ask each time) is what you come back to.
    ///
    /// Not blanket: calls that `ToolCallSafety` classifies as irreversible or
    /// outward-facing (sending, posting, deleting, paying, inviting, running
    /// commands, writing outside the agent folder) are still asked about.
    @Published var autoApproveThisSession = false

    /// How questions are asked aloud.
    ///
    /// Installed once at startup rather than passed per call, because approval
    /// now happens inside the tool registry — which has no business knowing
    /// which text-to-speech provider is configured, and would otherwise have to
    /// thread a closure through every caller that might ever run a tool.
    ///
    /// Nil means nothing can be spoken. That is not treated as permission: an
    /// unanswerable question is refused rather than assumed, since a user who
    /// cannot hear the prompt cannot have consented to it.
    private var speakHandler: (@MainActor (String) async -> Void)?

    func installSpeechHandler(_ handler: @escaping @MainActor (String) async -> Void) {
        speakHandler = handler
    }

    private var pendingContinuation: CheckedContinuation<Decision, Never>?
    private var timeoutTask: Task<Void, Never>?

    var isAwaitingConfirmation: Bool { pendingConfirmation != nil }

    /// Asks the user to approve a tool call and suspends until they answer.
    ///
    /// - Parameter speak: Used to ask the question aloud. Injected rather than
    ///   reached for directly so this type stays independent of which
    ///   text-to-speech provider is configured.
    /// Asks using the installed speech handler.
    ///
    /// The entry point for the permission boundary inside the tool registry.
    func requestApproval(toolName: String, argumentSummary: String) async -> Decision {
        guard let speakHandler else {
            // No way to ask means no way to consent.
            return .declined(reason: "there was no way to ask you about this")
        }
        return await requestApproval(
            toolName: toolName, argumentSummary: argumentSummary, speak: speakHandler
        )
    }

    /// Asks about a tool call using its structured arguments.
    ///
    /// The registry's entry point. Two things need the arguments rather than a
    /// summary string: the destructive-action floor, which keeps asking about
    /// sends, deletes and payments even with session auto-approve on, and the
    /// confirmation card, which shows what the call will do.
    func requestApproval(toolName: String, toolInput: JSONValue) async -> Decision {
        guard let speakHandler else {
            // No way to ask means no way to consent.
            return .declined(reason: "there was no way to ask you about this")
        }
        let agentWorkingDirectoryPath = AgentSettingsStore.resolvedWorkingDirectoryPath()
        let mustAskEvenWithSessionAutoApprove = ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: toolName,
            toolInput: toolInput,
            agentWorkingDirectoryPath: agentWorkingDirectoryPath
        )
        let confirmationCard = ToolConfirmationCardBuilder.confirmationCard(
            forToolNamed: toolName,
            toolInput: toolInput,
            agentWorkingDirectoryPath: agentWorkingDirectoryPath
        )
        return await requestApproval(
            toolName: toolName,
            argumentSummary: toolInput.compactDescription,
            speak: speakHandler,
            ignoresSessionAutoApprove: mustAskEvenWithSessionAutoApprove,
            spokenQuestionOverride: Self.spokenQuestionOverride(forToolNamed: toolName, toolInput: toolInput),
            confirmationCard: confirmationCard,
            messageDraft: MessageSendDraft(toolName: toolName, toolInput: toolInput)
        )
    }

    /// A question worth hearing for tools whose generic "i'd need to run …"
    /// would hide the one thing to check — for a message, who it goes to.
    private static func spokenQuestionOverride(forToolNamed toolName: String, toolInput: JSONValue) -> String? {
        guard ToolCallInspection.bareToolName(toolName) == MessagingToolNames.sendIMessage,
              let recipientName = ToolCallInspection.stringValue(forAnyOf: ["to"], in: toolInput) else { return nil }
        return "send that to \(recipientName.lowercased())?"
    }

    /// Asks before a browser action that cannot be taken back — placing an
    /// order, sending a message, deleting something.
    ///
    /// Deliberately ignores session auto-approve. Auto-approve exists so a long
    /// task does not stop to ask about every read and every click; it was never
    /// meant as consent to spend the user's money or speak in their name, and a
    /// browser agent is exactly the tool that can do both.
    func requestIrreversibleBrowserActionApproval(actionSummary: String) async -> Decision {
        guard let speakHandler else {
            return .declined(reason: "there was no way to ask you about this")
        }
        return await requestApproval(
            toolName: "browser_action",
            argumentSummary: actionSummary,
            speak: speakHandler,
            ignoresSessionAutoApprove: true,
            spokenQuestionOverride: "before i \(actionSummary) — is that okay?"
        )
    }

    func requestApproval(
        toolName: String,
        argumentSummary: String,
        speak: @MainActor (String) async -> Void,
        ignoresSessionAutoApprove: Bool = false,
        spokenQuestionOverride: String? = nil,
        confirmationCard: GlanceCard? = nil,
        messageDraft: MessageSendDraft? = nil
    ) async -> Decision {
        // Session auto-approve short-circuits the whole prompt so long tasks can
        // run without stopping to ask on every step — except for the few actions
        // that must always be asked about.
        if autoApproveThisSession && !ignoresSessionAutoApprove {
            return .approved
        }

        // A second request while one is outstanding is refused rather than
        // queued: two spoken questions at once cannot be answered separately.
        if pendingConfirmation != nil {
            return .declined(reason: "another confirmation was already waiting")
        }

        let question = spokenQuestionOverride ?? Self.spokenQuestion(forToolNamed: toolName)
        pendingConfirmation = PendingConfirmation(
            toolName: toolName,
            spokenQuestion: question,
            argumentSummary: argumentSummary,
            requestedAt: Date(),
            confirmationCard: confirmationCard,
            messageDraft: messageDraft
        )

        await speak(question)

        startTimeoutCountdown()

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    /// Interprets a spoken reply as the answer to the outstanding prompt.
    ///
    /// - Returns: Whether the utterance was consumed as an answer. When false,
    ///   the caller should treat it as an ordinary request.
    @discardableResult
    func handleSpokenResponse(_ transcript: String) -> Bool {
        guard pendingConfirmation != nil else { return false }

        if Self.readsAsAffirmative(transcript) {
            resolve(with: .approved)
        } else {
            resolve(with: .declined(reason: "you said no"))
        }
        return true
    }

    func approveFromUserInterface() {
        resolve(with: .approved)
    }

    func declineFromUserInterface() {
        resolve(with: .declined(reason: "you declined"))
    }

    private func resolve(with decision: Decision) {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingConfirmation = nil

        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(returning: decision)
    }

    private func startTimeoutCountdown() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.confirmationTimeoutSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.resolve(with: .declined(reason: "there was no answer, so it was skipped"))
        }
    }

    /// Cancels an outstanding prompt, for when the whole turn is abandoned.
    func cancelPending() {
        guard pendingConfirmation != nil else { return }
        resolve(with: .declined(reason: "the request was cancelled"))
    }

    // MARK: - Language

    /// Turns a tool name into something worth saying out loud.
    ///
    /// Names arrive as identifiers — `filesystem__write_file` — which are
    /// unpleasant to hear and hard to follow. Namespacing is dropped and
    /// underscores become spaces, so the question sounds like a question.
    private static func spokenQuestion(forToolNamed toolName: String) -> String {
        let withoutServerPrefix = toolName.contains("__")
            ? String(toolName.split(separator: "_", omittingEmptySubsequences: true).dropFirst().joined(separator: " "))
            : toolName
        let readable = withoutServerPrefix.replacingOccurrences(of: "_", with: " ")
        return "i'd need to run \(readable) to do that. is that okay?"
    }

    /// Whether a reply is a clear yes.
    ///
    /// Matching is exact against a short list rather than searching for "yes"
    /// anywhere, so "no, yes I mean don't" cannot approve by accident.
    /// Anything unrecognised declines.
    static func readsAsAffirmative(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))

        let affirmatives: Set<String> = [
            "yes", "yeah", "yep", "yup", "sure", "okay", "ok", "go ahead",
            "do it", "please do", "yes please", "sounds good", "confirm",
            "approved", "affirmative", "of course", "definitely"
        ]

        if affirmatives.contains(normalized) { return true }

        // Allow a short lead-in — "yes, go ahead" — while still refusing a
        // long sentence that merely contains the word.
        let words = normalized.split(separator: " ")
        if words.count <= 3, let firstWord = words.first {
            return affirmatives.contains(String(firstWord))
        }

        return false
    }
}
