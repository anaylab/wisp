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
//  The card can also let the user fix the wording before allowing — a subject,
//  a message, an event title (`EditableConfirmationFields` decides which, and
//  never a recipient or a path). Edits are held here, not in the view, so a
//  spoken "yes" approves with whatever is in the fields right now; typing
//  pushes the timeout out so an edit in progress is not lost to it.
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

    /// Asks the same way, but lets the user edit the call's human-text fields
    /// on the card first, and hands back what they typed along with the
    /// decision. Only a caller that will run the edited input may use this —
    /// one that asks this way and then runs the original would show the user
    /// an edit that never happens.
    func requestApprovalAllowingEdits(toolName: String, toolInput: JSONValue) async -> ToolApprovalOutcome
}

extension ToolPermissionBroker {
    /// A broker that only understands summaries — a test stub, say — still
    /// works: it is asked with the compact JSON, exactly as before.
    func requestApproval(toolName: String, toolInput: JSONValue) async -> ToolConfirmationCoordinator.Decision {
        await requestApproval(toolName: toolName, argumentSummary: toolInput.compactDescription)
    }

    /// A broker with no editable card — every existing stub — approves or
    /// declines the call exactly as asked, with no edits.
    func requestApprovalAllowingEdits(toolName: String, toolInput: JSONValue) async -> ToolApprovalOutcome {
        ToolApprovalOutcome(
            decision: await requestApproval(toolName: toolName, toolInput: toolInput),
            editedTextsByArgumentKey: [:]
        )
    }
}

/// A decision plus whatever the user typed into the card's editable fields.
///
/// Carries the raw edits rather than a finished input on purpose: whoever
/// runs the tool gets the input with `approvedToolInput(forAskedToolInput:toolName:)`,
/// which goes back through `EditableConfirmationFields.applyingEdits` against
/// the input that was actually asked about. So no broker — however it is
/// written — can hand the executor an input with a different recipient, path
/// or tool; at worst its edits to such keys are dropped.
struct ToolApprovalOutcome: Equatable {
    let decision: ToolConfirmationCoordinator.Decision
    /// Argument key (exact spelling) → the text in that field when the user
    /// approved. Empty when declined or when nothing was offered for editing.
    let editedTextsByArgumentKey: [String: String]

    var isApproved: Bool { decision.isApproved }

    /// The input to run and which fields the user changed. With no edits (or
    /// no approval), the asked-about input unchanged.
    func approvedToolInput(forAskedToolInput askedToolInput: JSONValue, toolName: String) -> AppliedConfirmationEdits {
        guard decision.isApproved else {
            return AppliedConfirmationEdits(toolInput: askedToolInput, editedFields: [])
        }
        return EditableConfirmationFields.applyingEdits(
            editedTextsByArgumentKey,
            toToolInput: askedToolInput,
            toolNamed: toolName
        )
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
        /// summary exactly as it always has. The card itself is display-only;
        /// its editable rows are drawn from `editableFields` instead.
        let confirmationCard: GlanceCard?
        /// Set for a `send_imessage` call: the panel is then drawn as a
        /// Siri-style message (avatar, bubble, Send) instead of a tool card.
        var messageDraft: MessageSendDraft? = nil
        /// The fields the card shows as text boxes the user may edit before
        /// allowing. Empty for most calls, and always empty when the caller
        /// asked without `requestApprovalAllowingEdits` (it would run the
        /// original input, so offering an edit would be a lie).
        var editableFields: [EditableConfirmationField] = []
        /// The structured arguments asked about, when the caller gave them —
        /// so the panel can show the call as it will run with the edits made.
        var toolInput: JSONValue? = nil

        /// Whether the panel needs keyboard focus (so the overlay must be
        /// allowed to become key while it is up).
        var offersEditableFields: Bool { !editableFields.isEmpty }
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

    /// The longest a prompt can stay up while the user keeps editing it. Each
    /// edit gives another `confirmationTimeoutSeconds`, so someone typing never
    /// loses their words to the countdown — but an edited card that is then
    /// forgotten still expires (and declines) rather than hanging the turn.
    static let maximumConfirmationWindowWhileEditingSeconds: TimeInterval = 5 * 60

    @Published private(set) var pendingConfirmation: PendingConfirmation?

    /// When the pending prompt expires and declines. Moves later while the
    /// user edits a field; the panel's countdown reads it.
    @Published private(set) var pendingConfirmationExpiryDate: Date?

    /// What the user has typed into the card's editable fields so far, by
    /// exact argument key. Kept here rather than in the view so every way of
    /// approving — the Allow button, Cmd-Return, a spoken "yes" — approves
    /// the same, current text.
    @Published private(set) var editedTextsByArgumentKey: [String: String] = [:]

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

    private var pendingContinuation: CheckedContinuation<ToolApprovalOutcome, Never>?

    /// An answer that came while the question was still being spoken.
    ///
    /// The card appears the moment a request is made, but the wait for an
    /// answer only begins once the question has been said aloud. A click (or an
    /// accessibility press) in between used to clear the card and resume
    /// nothing, so the request sat until its timeout and was reported as "no
    /// answer" — measured live, with the island already flashing the approval.
    /// The slower on-device voice made that gap seconds long. The answer is now
    /// kept here and returned as soon as speaking ends.
    private var answerReceivedWhileAsking: ToolApprovalOutcome?
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

    /// Asks about a tool call and offers its human-text fields for editing.
    ///
    /// The registry's entry point (and the direct "text mom …" route's): both
    /// run what the returned outcome says, edits included.
    func requestApprovalAllowingEdits(toolName: String, toolInput: JSONValue) async -> ToolApprovalOutcome {
        await requestApprovalWithStructuredInput(toolName: toolName, toolInput: toolInput, offersEditableFields: true)
    }

    /// Asks about a tool call using its structured arguments.
    ///
    /// The registry's entry point. Two things need the arguments rather than a
    /// summary string: the destructive-action floor, which keeps asking about
    /// sends, deletes and payments even with session auto-approve on, and the
    /// confirmation card, which shows what the call will do.
    func requestApproval(toolName: String, toolInput: JSONValue) async -> Decision {
        // A caller asking this way runs the input it passed, so the card must
        // not offer edits that would silently never happen.
        await requestApprovalWithStructuredInput(toolName: toolName, toolInput: toolInput, offersEditableFields: false).decision
    }

    private func requestApprovalWithStructuredInput(
        toolName: String,
        toolInput: JSONValue,
        offersEditableFields: Bool
    ) async -> ToolApprovalOutcome {
        guard let speakHandler else {
            // No way to ask means no way to consent.
            return ToolApprovalOutcome(
                decision: .declined(reason: "there was no way to ask you about this"),
                editedTextsByArgumentKey: [:]
            )
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
        let editableFields = offersEditableFields
            ? EditableConfirmationFields.editableFields(forToolNamed: toolName, toolInput: toolInput)
            : []
        return await askAndWaitForOutcome(
            toolName: toolName,
            argumentSummary: toolInput.compactDescription,
            speak: speakHandler,
            ignoresSessionAutoApprove: mustAskEvenWithSessionAutoApprove,
            spokenQuestionOverride: Self.spokenQuestionOverride(forToolNamed: toolName, toolInput: toolInput),
            confirmationCard: confirmationCard,
            messageDraft: MessageSendDraft(toolName: toolName, toolInput: toolInput),
            editableFields: editableFields,
            toolInput: toolInput
        )
    }

    /// A question worth hearing for tools whose generic "i'd need to run …"
    /// would hide the one thing to check — for a message, who it goes to.
    private static func spokenQuestionOverride(forToolNamed toolName: String, toolInput: JSONValue) -> String? {
        if ToolCallInspection.bareToolName(toolName) == FormFillToolNames.fillForm {
            return "fill in what's on the card? i won't submit it."
        }
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
        await askAndWaitForOutcome(
            toolName: toolName,
            argumentSummary: argumentSummary,
            speak: speak,
            ignoresSessionAutoApprove: ignoresSessionAutoApprove,
            spokenQuestionOverride: spokenQuestionOverride,
            confirmationCard: confirmationCard,
            messageDraft: messageDraft,
            editableFields: [],
            toolInput: nil
        ).decision
    }

    private func askAndWaitForOutcome(
        toolName: String,
        argumentSummary: String,
        speak: @MainActor (String) async -> Void,
        ignoresSessionAutoApprove: Bool,
        spokenQuestionOverride: String?,
        confirmationCard: GlanceCard?,
        messageDraft: MessageSendDraft?,
        editableFields: [EditableConfirmationField],
        toolInput: JSONValue?
    ) async -> ToolApprovalOutcome {
        // Session auto-approve short-circuits the whole prompt so long tasks can
        // run without stopping to ask on every step — except for the few actions
        // that must always be asked about. Nothing is shown, so nothing is edited.
        if autoApproveThisSession && !ignoresSessionAutoApprove {
            return ToolApprovalOutcome(decision: .approved, editedTextsByArgumentKey: [:])
        }

        // A second request while one is outstanding is refused rather than
        // queued: two spoken questions at once cannot be answered separately.
        if pendingConfirmation != nil {
            return ToolApprovalOutcome(
                decision: .declined(reason: "another confirmation was already waiting"),
                editedTextsByArgumentKey: [:]
            )
        }

        let question = spokenQuestionOverride ?? Self.spokenQuestion(forToolNamed: toolName)
        let requestedAt = Date()
        answerReceivedWhileAsking = nil
        editedTextsByArgumentKey = [:]
        pendingConfirmationExpiryDate = requestedAt.addingTimeInterval(Self.confirmationTimeoutSeconds)
        pendingConfirmation = PendingConfirmation(
            toolName: toolName,
            spokenQuestion: question,
            argumentSummary: argumentSummary,
            requestedAt: requestedAt,
            confirmationCard: confirmationCard,
            messageDraft: messageDraft,
            editableFields: editableFields,
            toolInput: toolInput
        )

        await speak(question)

        if let answerReceivedWhileAsking {
            self.answerReceivedWhileAsking = nil
            return answerReceivedWhileAsking
        }

        // As before, the full window counts from when the question has been
        // asked aloud, not from when the card appeared.
        if pendingConfirmation != nil, let expiryBeforeSpeaking = pendingConfirmationExpiryDate {
            pendingConfirmationExpiryDate = max(expiryBeforeSpeaking, Date().addingTimeInterval(Self.confirmationTimeoutSeconds))
        }
        startTimeoutCountdown()

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    // MARK: - Editing the card

    /// Records the text now in one of the card's editable fields, and gives
    /// the user more time — an edit in progress must not be declined out from
    /// under them by the countdown.
    ///
    /// A key the pending card did not offer for editing is ignored here, and
    /// would be again when the edits are applied.
    func updateEditedText(_ editedText: String, forArgumentKey argumentKey: String) {
        guard let pendingConfirmation,
              pendingConfirmation.editableFields.contains(where: { $0.argumentKey == argumentKey }) else { return }
        editedTextsByArgumentKey[argumentKey] = editedText
        extendTimeoutForEditing()
    }

    /// The user is working in a field (focused it, or is typing): push the
    /// expiry out to a full window from now, never past the editing cap.
    func extendTimeoutForEditing() {
        guard let pendingConfirmation, pendingConfirmation.offersEditableFields,
              let currentExpiryDate = pendingConfirmationExpiryDate else { return }
        let latestAllowedExpiryDate = pendingConfirmation.requestedAt
            .addingTimeInterval(Self.maximumConfirmationWindowWhileEditingSeconds)
        let extendedExpiryDate = min(
            latestAllowedExpiryDate,
            max(currentExpiryDate, Date().addingTimeInterval(Self.confirmationTimeoutSeconds))
        )
        guard extendedExpiryDate > currentExpiryDate else { return }
        pendingConfirmationExpiryDate = extendedExpiryDate
        startTimeoutCountdown()
    }

    /// When the pending prompt for this tool will expire, for a caller that
    /// bounds the whole tool call (the agent loop's own timeout) and must not
    /// give up while the user is still editing the card. Nil when no prompt
    /// for this tool is up.
    func expiryDateOfPendingConfirmation(forToolNamed toolName: String) -> Date? {
        guard pendingConfirmation?.toolName == toolName else { return nil }
        return pendingConfirmationExpiryDate
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
        // Whether a request is out. Its card can be answered before the wait
        // below has begun (see `answerReceivedWhileAsking`).
        let isRequestOutstanding = pendingConfirmation != nil || pendingContinuation != nil
        timeoutTask?.cancel()
        timeoutTask = nil
        // Edits only travel with an approval; a decline runs nothing.
        let approvedEditedTexts = decision.isApproved ? editedTextsByArgumentKey : [:]
        pendingConfirmation = nil
        pendingConfirmationExpiryDate = nil
        editedTextsByArgumentKey = [:]

        let outcome = ToolApprovalOutcome(
            decision: decision,
            editedTextsByArgumentKey: approvedEditedTexts
        )
        guard let continuation = pendingContinuation else {
            if isRequestOutstanding { answerReceivedWhileAsking = outcome }
            return
        }
        pendingContinuation = nil
        continuation.resume(returning: outcome)
    }

    /// (Re)starts the countdown to `pendingConfirmationExpiryDate` — restarted
    /// rather than added to when an edit moves the expiry later.
    private func startTimeoutCountdown() {
        timeoutTask?.cancel()
        let secondsUntilExpiry = max(0, pendingConfirmationExpiryDate?.timeIntervalSinceNow ?? Self.confirmationTimeoutSeconds)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(secondsUntilExpiry * 1_000_000_000)
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
