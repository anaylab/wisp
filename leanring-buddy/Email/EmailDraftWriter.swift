//
//  EmailDraftWriter.swift
//  leanring-buddy
//
//  Opens the email composer for a request and fills it: the recipient's
//  address from Contacts, the screen's text when the email is about something
//  on screen, and the subject and body from one text-only model call through
//  the selected provider. Also the `draft_email` agent tool, which opens the
//  same composer with what the model already wrote.
//
//  Nothing here sends anything. The composer's Send button is the only way a
//  draft leaves the Mac, so neither path asks for confirmation.
//

import Foundation

enum EmailToolNames {
    static let draftEmail = "draft_email"
}

@MainActor
enum EmailDraftWriter {

    /// What the turn reports when the composer has opened.
    struct DraftStart {
        /// Who the To field was filled with, for the notch line ("sam chen").
        let recipientDisplayName: String?
        /// Why the To field is still empty, if it is and the user named someone.
        let recipientProblem: String?
    }

    /// Opens the composer for a spoken request and starts writing the draft.
    /// Returns once it is open; `onDraftWritten` is told how the writing went
    /// (nil = written, otherwise why not) for the History record.
    static func startDraft(
        for emailDraftRequest: EmailDraftRequest,
        transcript: String,
        onDraftWritten: @escaping (_ failureText: String?) -> Void
    ) async -> DraftStart {
        var initialDraftFields = EmailDraftFields()
        var recipientDisplayName: String?
        var recipientProblem: String?
        if let recipientPhrase = emailDraftRequest.recipientPhrase {
            let resolvedRecipient = await resolveRecipient(spokenRecipient: recipientPhrase)
            initialDraftFields.toField = resolvedRecipient.fieldText
            recipientDisplayName = resolvedRecipient.displayName
            recipientProblem = resolvedRecipient.problem
        }

        // Read before the composer opens, so the read is of the user's work
        // (Wisp's own windows are excluded from capture anyway).
        let screenText = emailDraftRequest.refersToScreen ? await readScreenText() : nil

        let composerController = EmailComposerWindowController.shared
        let composerModel = composerController.open(
            with: initialDraftFields,
            isWriting: emailDraftRequest.hasContentToWrite
        )
        if let recipientProblem {
            composerModel.noticeText = recipientProblem
        }
        guard emailDraftRequest.hasContentToWrite else {
            onDraftWritten(nil)
            return DraftStart(recipientDisplayName: recipientDisplayName, recipientProblem: recipientProblem)
        }

        func writeIntoComposer() {
            composerModel.phase = .writing
            composerController.draftWritingTask = Task { @MainActor in
                do {
                    let writtenDraft = try await writeDraft(
                        transcript: transcript,
                        recipientDisplayName: recipientDisplayName ?? emailDraftRequest.recipientPhrase,
                        isAddressedToUser: emailDraftRequest.isAddressedToUser,
                        screenText: screenText,
                        isReply: emailDraftRequest.isReply
                    )
                    guard !Task.isCancelled else { return }
                    // An address the model "read" off the screen is kept only
                    // if it is really there — never one it made up.
                    let toAddressFromScreen = writtenDraft.toAddress.flatMap { modelAddress in
                        (screenText ?? "").localizedCaseInsensitiveContains(modelAddress) ? modelAddress : nil
                    }
                    composerModel.fillWrittenDraft(
                        subject: writtenDraft.subject,
                        body: writtenDraft.body,
                        toAddressFromScreen: toAddressFromScreen
                    )
                    onDraftWritten(nil)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    let failureText = "I couldn't write the draft (\(error.localizedDescription)). Write it here, or try again."
                    composerModel.showWritingFailure(failureText, retry: { writeIntoComposer() })
                    onDraftWritten(failureText)
                }
            }
        }
        writeIntoComposer()
        return DraftStart(recipientDisplayName: recipientDisplayName, recipientProblem: recipientProblem)
    }

    // MARK: - Recipient

    /// A spoken recipient → the To field's text. An address is used as is; a
    /// name is looked up in Contacts for its email address. Anything else
    /// leaves To empty for the user, with the reason.
    static func resolveRecipient(spokenRecipient: String) async -> (fieldText: String, displayName: String?, problem: String?) {
        let trimmedRecipient = spokenRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if EmailAddressList.isEmailAddress(trimmedRecipient) {
            return (trimmedRecipient, nil, nil)
        }
        // "me" is the user: their own card, not a contact search for "me".
        if EmailDraftRequestParser.userSelfReferences.contains(trimmedRecipient.lowercased()) {
            guard let meCard = await ContactsDirectory.shared.meCard(asksForAccess: true) else {
                return ("", nil, "I couldn't find your own card in Contacts, so add your address.")
            }
            guard let ownEmailHandle = meCard.emailHandles.first else {
                return ("", meCard.displayName, "Your card in Contacts has no email address, so add yours.")
            }
            return (
                EmailAddressList.fieldEntry(displayName: meCard.displayName, address: ownEmailHandle.value),
                meCard.displayName,
                nil
            )
        }
        do {
            switch try await ContactsDirectory.shared.resolve(spokenName: trimmedRecipient) {
            case .matched(let contact):
                guard let emailHandle = contact.emailHandles.first else {
                    return ("", contact.displayName, "\(contact.displayName) has no email address in your contacts.")
                }
                return (
                    EmailAddressList.fieldEntry(displayName: contact.displayName, address: emailHandle.value),
                    contact.displayName,
                    nil
                )
            case .ambiguous(let matchingContacts):
                let listedNames = matchingContacts.prefix(3).map(\.displayName).joined(separator: ", ")
                return ("", nil, "More than one contact matches “\(trimmedRecipient)” (\(listedNames)). Add who it's to.")
            case .noMatch:
                // "my landlord", "the team": not a contact, and not a problem —
                // the model still writes to them; the user fills in the address.
                return ("", nil, nil)
            }
        } catch {
            return ("", nil, nil)
        }
    }

    // MARK: - Screen

    private static func readScreenText() async -> String? {
        guard let screenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
              let screenTextSnapshot = await ScreenTextRecognizer.shared.snapshot(
                for: screenCaptures,
                waitingAtMost: ScreenTextRecognizer.toolWaitBudgetSeconds,
                maximumLineCount: AgentToolRegistry.readScreenTextMaximumLineCount,
                maximumCharacterCount: EmailDraftPrompt.maximumScreenTextCharacterCount
              ) else {
            return nil
        }
        return screenTextSnapshot.plainText()
    }

    // MARK: - Model

    private struct EmptyDraftError: LocalizedError {
        var errorDescription: String? { "the model's reply had no email in it" }
    }

    private static func writeDraft(
        transcript: String,
        recipientDisplayName: String?,
        isAddressedToUser: Bool,
        screenText: String?,
        isReply: Bool
    ) async throws -> EmailDraftReplyParser.ParsedDraft {
        // The first name on the user's own Contacts card. Not the Mac account's
        // name, which is often a handle ("m3pro"); with no card, no name.
        let meCard = await ContactsDirectory.shared.meCard(asksForAccess: false)
        let senderFirstName = meCard.map { $0.givenName.isEmpty ? $0.nickname : $0.givenName }
        let draftRequest = ModelRequest(
            systemPrompt: EmailDraftPrompt.systemPrompt(senderFirstName: senderFirstName, isReply: isReply),
            messages: [BuddyChatMessage(role: .user, text: EmailDraftPrompt.userMessage(
                request: transcript,
                recipientDisplayName: recipientDisplayName,
                isAddressedToUser: isAddressedToUser,
                screenText: screenText
            ))],
            maxOutputTokens: 700,
            temperature: 0.4
        )
        let modelProvider = ModelProviderFactory.make()
        let draftTurn = try await ModelAccessGate.shared.withAccess(priority: .interactive) {
            try await modelProvider.completeTurn(draftRequest)
        }
        guard let parsedDraft = EmailDraftReplyParser.parse(modelReply: draftTurn.text) else {
            throw EmptyDraftError()
        }
        return parsedDraft
    }
}

// MARK: - Agent tool

extension AgentToolRegistry {

    /// Registers `draft_email`, which opens the composer with a draft the
    /// model wrote. It sends nothing — the user reviews, edits and presses Send
    /// — so, like opening an app, it runs without a confirmation card.
    func registerEmailTools() {
        register(
            BuddyToolDefinition(
                name: EmailToolNames.draftEmail,
                description: "Open an email draft for the user to review, edit and send themselves. Use whenever the user wants to write, draft or send an email. Write the full subject and body. It never sends anything on its own.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "to": .object([
                            "type": .string("string"),
                            "description": .string("Who it is to: email addresses, or contact names like \"sam\", separated by commas. Empty if unknown.")
                        ]),
                        "cc": .object([
                            "type": .string("string"),
                            "description": .string("Optional Cc addresses or contact names, separated by commas.")
                        ]),
                        "subject": .object([
                            "type": .string("string"),
                            "description": .string("The subject line.")
                        ]),
                        "body": .object([
                            "type": .string("string"),
                            "description": .string("The full email body, plain text, with greeting and sign-off.")
                        ])
                    ]),
                    "required": .array([.string("subject"), .string("body")])
                ]),
                // Opens a window the user closes; nothing changes until they press Send.
                metadata: .trivialAndReversible
            )
        ) { input in
            guard case .object(let arguments) = input else { return "i need the email's subject and body." }
            func stringArgument(_ key: String) -> String {
                if case .string(let value)? = arguments[key] { return value }
                return ""
            }
            let body = stringArgument("body")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "i need the email's body to open a draft."
            }

            let toField = await Self.resolvedAddressField(fromModelText: stringArgument("to"))
            let ccField = await Self.resolvedAddressField(fromModelText: stringArgument("cc"))
            EmailComposerWindowController.shared.open(
                with: EmailDraftFields(
                    toField: toField.fieldText,
                    ccField: ccField.fieldText,
                    subject: stringArgument("subject"),
                    body: body
                ),
                isWriting: false
            )
            var toolResultText = "opened the draft for the user to review and send. it has not been sent — don't say it was."
            let unresolvedNames = toField.unresolvedNames + ccField.unresolvedNames
            if !unresolvedNames.isEmpty {
                toolResultText += " no email address found for \(unresolvedNames.joined(separator: ", ")); the user will fill it in."
            }
            return toolResultText
        }
    }

    /// "sam, lee@example.com" → "Sam Chen <sam@…>, lee@example.com". Names
    /// that aren't a contact with an email are left out and reported.
    private static func resolvedAddressField(fromModelText modelAddressText: String) async -> (fieldText: String, unresolvedNames: [String]) {
        var fieldEntries: [String] = []
        var unresolvedNames: [String] = []
        let entries = modelAddressText
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for entry in entries {
            if let address = EmailAddressList.parse(entry).addresses.first {
                fieldEntries.append(entry.contains("<") ? entry : address)
                continue
            }
            let resolvedRecipient = await EmailDraftWriter.resolveRecipient(spokenRecipient: entry)
            if resolvedRecipient.fieldText.isEmpty {
                unresolvedNames.append(entry)
            } else {
                fieldEntries.append(resolvedRecipient.fieldText)
            }
        }
        return (fieldEntries.joined(separator: ", "), unresolvedNames)
    }
}
