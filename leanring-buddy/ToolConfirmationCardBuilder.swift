//
//  ToolConfirmationCardBuilder.swift
//  leanring-buddy
//
//  Builds the rich card shown on the tool-confirmation panel ("Phase 6" of
//  docs/glance-cards-plan.md): instead of asking the user to approve a line of
//  raw JSON, the panel shows what the call will actually do — a "New Email"
//  card with To / Subject and the start of the body, a "New Event" card with
//  its time and guests, a file write with the file, its folder and a preview.
//
//  Built deterministically from the tool call, never by the model. The card is
//  part of the consent step, so it must describe the arguments that will run,
//  not a paraphrase the model chose. Tools that match none of the shapes below
//  get no card and the panel falls back to today's plain summary, so an
//  unrecognised tool looks exactly as it did before.
//
//  The card reuses the generic glance-card blocks (`GlanceCard` / `GlanceBlock`)
//  and their renderer (`GlanceCardView`), so it looks like every other card
//  Wisp shows.
//
//  v1 is display-only. Inline-editable fields — letting the user fix a
//  recipient or a subject on the card before allowing it (VoiceOS-style
//  `{{param}}` bindings) — are a deliberate future extension, not an omission.
//

import Foundation

enum ToolConfirmationCardBuilder {

    // MARK: - Limits

    /// How much of a message body, event description or file content is shown.
    /// Enough to recognise the text, short enough that the card stays a glance.
    static let maximumBodyPreviewCharacters = 180

    /// Values in key/value rows (a recipient list, a path) are cut at this.
    static let maximumFieldValueCharacters = 80

    /// How many rows a Composio multi-action card lists before summarising.
    private static let maximumListedActions = 5

    // MARK: - Argument key vocabularies

    private static let emailRecipientKeys = ["to", "recipient", "recipients", "recipient_email", "to_email", "send_to", "email_to", "emails"]
    private static let messageRecipientKeys = ["channel", "channel_id", "channel_name", "chat_id", "conversation", "conversation_id", "to", "recipient", "recipient_id", "user", "user_id", "username", "phone_number", "thread"]
    private static let bodyKeys = ["body", "message_body", "text", "message", "content", "html", "html_body", "markdown_text", "markdown", "status", "caption"]
    private static let subjectKeys = ["subject"]
    private static let eventTitleKeys = ["summary", "title", "name", "subject"]
    private static let eventStartKeys = ["start", "start_time", "start_datetime", "start_date_time", "start_date", "starts_at", "when"]
    private static let eventEndKeys = ["end", "end_time", "end_datetime", "end_date_time", "end_date", "ends_at"]
    private static let eventGuestKeys = ["attendees", "invitees", "guests", "participants"]
    private static let fileContentKeys = ["content", "contents", "text", "data", "body", "new_text", "new_content"]

    // MARK: - Word vocabularies

    private static let emailWords: Set<String> = ["email", "emails", "mail", "gmail", "outlook", "draft"]
    private static let messageWords: Set<String> = ["message", "messages", "chat", "dm", "sms"]
    private static let postWords: Set<String> = ["post", "tweet", "publish", "status", "comment"]
    private static let calendarWords: Set<String> = ["event", "events", "meeting", "calendar"]
    private static let deletionWords: Set<String> = ["delete", "remove", "trash", "purge", "destroy", "erase", "wipe", "unlink", "rm", "rmdir"]
    private static let fileWritingWords: Set<String> = ["write", "edit", "create", "move", "rename", "overwrite", "save", "append", "put", "copy", "mkdir"]
    private static let fileObjectWords: Set<String> = ["file", "files", "directory", "folder", "dir"]
    private static let composingVerbWords: Set<String> = ["send", "create", "compose", "draft", "reply", "forward", "post", "write", "new", "add"]

    // MARK: - Entry point

    /// The card for a pending tool call, or nil when the call matches no known
    /// shape and the plain summary should be shown instead.
    ///
    /// - Parameter agentWorkingDirectoryPath: When given, a file write that
    ///   lands outside this folder is flagged on the card.
    static func confirmationCard(
        forToolNamed toolName: String,
        toolInput: JSONValue,
        agentWorkingDirectoryPath: String?
    ) -> GlanceCard? {
        // Checked by name before any word matching: "run shortcut" matches no
        // shape below, and without its own card the user would approve an
        // opaque automation from a line of raw JSON.
        if ToolCallInspection.bareToolName(toolName) == ShortcutsToolRouting.runShortcutToolName {
            return runShortcutCard(toolInput: toolInput)
        }
        // Its prepared input names the resolved person and handle, which the
        // generic message shape would show only half of.
        if ToolCallInspection.bareToolName(toolName) == MessagingToolNames.sendIMessage {
            return sendIMessageCard(toolInput: toolInput)
        }

        let inspectedActions = ToolCallInspection.inspectedActions(toolName: toolName, toolInput: toolInput)

        if inspectedActions.count > 1 {
            return multipleActionsCard(for: inspectedActions)
        }
        guard let onlyAction = inspectedActions.first else { return nil }
        return confirmationCard(for: onlyAction, agentWorkingDirectoryPath: agentWorkingDirectoryPath)
    }

    /// The card for one concrete action. Order matters: deletion is checked
    /// first because "delete email" must read as a deletion, not a new email.
    static func confirmationCard(
        for inspectedAction: InspectedToolAction,
        agentWorkingDirectoryPath: String?
    ) -> GlanceCard? {
        let actionNameWords = Set(inspectedAction.actionNameWords)
        let isReadingAction = ToolCallSafety.namesReadingAction(actionNameWords: actionNameWords)
            && ToolCallSafety.alwaysIrreversibleWords.isDisjoint(with: actionNameWords)

        // A tool that only looks something up has nothing worth a card; the
        // plain summary is already the right amount of detail.
        if isReadingAction { return nil }

        if !actionNameWords.isDisjoint(with: deletionWords) {
            return deletionCard(for: inspectedAction)
        }
        if let emailCard = emailCard(for: inspectedAction) { return emailCard }
        if let calendarEventCard = calendarEventCard(for: inspectedAction) { return calendarEventCard }
        if let messageOrPostCard = messageOrPostCard(for: inspectedAction) { return messageOrPostCard }
        if let fileWriteCard = fileWriteCard(for: inspectedAction, agentWorkingDirectoryPath: agentWorkingDirectoryPath) {
            return fileWriteCard
        }
        if ToolCallSafety.namesIrreversibleAction(actionNameWords: actionNameWords) {
            return irreversibleActionCard(for: inspectedAction)
        }
        return nil
    }

    // MARK: - Email

    private static func emailCard(for inspectedAction: InspectedToolAction) -> GlanceCard? {
        let actionNameWords = Set(inspectedAction.actionNameWords)
        let arguments = inspectedAction.arguments
        let hasSubject = ToolCallInspection.stringValue(forAnyOf: subjectKeys, in: arguments) != nil
        let namesEmail = !actionNameWords.isDisjoint(with: emailWords)
        let composesSomething = !actionNameWords.isDisjoint(with: composingVerbWords)

        // "Email" in the name plus a composing verb, or a subject line on a
        // call that has a recipient — either way this is a message by mail.
        let hasRecipient = ToolCallInspection.stringValue(forAnyOf: emailRecipientKeys, in: arguments) != nil
        guard (namesEmail && composesSomething) || (hasSubject && hasRecipient) else { return nil }
        // Mail suites also own calendars (`OUTLOOK_CALENDAR_CREATE_EVENT`);
        // those are events, not emails.
        guard actionNameWords.isDisjoint(with: calendarWords) else { return nil }

        let headerTitle: String
        if actionNameWords.contains("reply") {
            headerTitle = "Reply"
        } else if actionNameWords.contains("forward") {
            headerTitle = "Forward Email"
        } else if actionNameWords.contains("draft") {
            headerTitle = "New Draft"
        } else {
            headerTitle = "New Email"
        }

        var blocks: [GlanceBlock] = [
            .header(title: headerTitle, iconName: "envelope", trailingText: displayServiceName(inspectedAction.serviceName))
        ]
        let keyValuePairs = keyValuePairs(from: [
            ("To", emailRecipientKeys),
            ("Cc", ["cc", "cc_emails"]),
            ("Bcc", ["bcc", "bcc_emails"]),
            ("Subject", subjectKeys)
        ], in: arguments)
        if !keyValuePairs.isEmpty { blocks.append(.keyValue(pairs: keyValuePairs)) }
        if let bodyPreviewBlock = bodyPreviewBlock(forAnyOf: bodyKeys, in: arguments) {
            blocks.append(bodyPreviewBlock)
        }
        return GlanceCard(blocks: blocks)
    }

    // MARK: - Chat messages and posts

    private static func messageOrPostCard(for inspectedAction: InspectedToolAction) -> GlanceCard? {
        let actionNameWords = Set(inspectedAction.actionNameWords)
        let arguments = inspectedAction.arguments
        let hasBody = ToolCallInspection.stringValue(forAnyOf: bodyKeys, in: arguments) != nil
        let recipientText = ToolCallInspection.stringValue(forAnyOf: messageRecipientKeys, in: arguments)

        let namesMessage = !actionNameWords.isDisjoint(with: messageWords)
        let namesPost = !actionNameWords.isDisjoint(with: postWords)
        let sendsSomething = actionNameWords.contains("send") || actionNameWords.contains("reply")
            || actionNameWords.contains("forward")

        guard hasBody, namesMessage || namesPost || sendsSomething else { return nil }

        // A post goes to an audience rather than a person; a message with a
        // recipient is a message even when the API calls it "postMessage".
        let isPost = namesPost && !namesMessage && recipientText == nil
        let headerTitle: String
        if isPost {
            headerTitle = actionNameWords.contains("comment") ? "New Comment" : "New Post"
        } else if actionNameWords.contains("reply") {
            headerTitle = "Reply"
        } else {
            headerTitle = "New Message"
        }

        var blocks: [GlanceBlock] = [
            .header(
                title: headerTitle,
                iconName: isPost ? "doc" : "envelope",
                trailingText: displayServiceName(inspectedAction.serviceName)
            )
        ]
        let keyValuePairs = keyValuePairs(from: [
            ("To", messageRecipientKeys),
            ("Where", ["subreddit", "board", "page", "group", "repo", "repository"]),
            ("Title", ["title"])
        ], in: arguments)
        if !keyValuePairs.isEmpty { blocks.append(.keyValue(pairs: keyValuePairs)) }
        if let bodyPreviewBlock = bodyPreviewBlock(forAnyOf: bodyKeys, in: arguments) {
            blocks.append(bodyPreviewBlock)
        }
        return GlanceCard(blocks: blocks)
    }

    // MARK: - Calendar events

    private static func calendarEventCard(for inspectedAction: InspectedToolAction) -> GlanceCard? {
        let actionNameWords = Set(inspectedAction.actionNameWords)
        let arguments = inspectedAction.arguments
        let hasStart = ToolCallInspection.stringValue(forAnyOf: eventStartKeys, in: arguments) != nil
        guard !actionNameWords.isDisjoint(with: calendarWords) || (hasStart && actionNameWords.contains("schedule")) else {
            return nil
        }

        let isUpdate = actionNameWords.contains("update") || actionNameWords.contains("edit")
            || actionNameWords.contains("patch") || actionNameWords.contains("move")
        var blocks: [GlanceBlock] = [
            .header(
                title: isUpdate ? "Update Event" : "New Event",
                iconName: "calendar",
                trailingText: displayServiceName(inspectedAction.serviceName)
            )
        ]
        let keyValuePairs = keyValuePairs(from: [
            ("Title", eventTitleKeys),
            ("Starts", eventStartKeys),
            ("Ends", eventEndKeys),
            ("Where", ["location", "place", "where"]),
            ("Guests", eventGuestKeys)
        ], in: arguments)
        if !keyValuePairs.isEmpty { blocks.append(.keyValue(pairs: keyValuePairs)) }
        if let descriptionPreviewBlock = bodyPreviewBlock(forAnyOf: ["description", "notes", "body", "details"], in: arguments) {
            blocks.append(descriptionPreviewBlock)
        }
        return GlanceCard(blocks: blocks)
    }

    // MARK: - File writes

    private static func fileWriteCard(
        for inspectedAction: InspectedToolAction,
        agentWorkingDirectoryPath: String?
    ) -> GlanceCard? {
        let actionNameWords = Set(inspectedAction.actionNameWords)
        let arguments = inspectedAction.arguments
        guard !actionNameWords.isDisjoint(with: fileWritingWords) else { return nil }

        let sourcePath = ToolCallInspection.stringValue(forAnyOf: ["source", "source_path", "old_path", "from"], in: arguments)
        let destinationPath = ToolCallInspection.stringValue(forAnyOf: ["destination", "destination_path", "new_path", "dest", "to_path", "target_path"], in: arguments)
        let singlePath = ToolCallInspection.stringValue(forAnyOf: ["path", "file_path", "filepath", "file", "filename", "file_name"], in: arguments)
        let isMoveOrCopy = sourcePath != nil && destinationPath != nil

        // A write verb alone ("create_issue") is not a file write; it needs a
        // path, or a file word in the name alongside some path-like field.
        guard isMoveOrCopy || singlePath != nil else { return nil }
        guard isMoveOrCopy || !actionNameWords.isDisjoint(with: fileObjectWords)
            || ToolCallInspection.fieldValue(forAnyOf: ["path", "file_path", "filepath"], in: arguments) != nil else {
            return nil
        }

        let isDirectory = actionNameWords.contains("directory") || actionNameWords.contains("folder")
            || actionNameWords.contains("dir") || actionNameWords.contains("mkdir")

        let headerTitle: String
        if isMoveOrCopy {
            headerTitle = actionNameWords.contains("copy") ? "Copy File" : "Move File"
        } else if isDirectory {
            headerTitle = "Create Folder"
        } else if actionNameWords.contains("edit") || actionNameWords.contains("replace") {
            headerTitle = "Edit File"
        } else {
            headerTitle = "Write File"
        }

        var blocks: [GlanceBlock] = [
            .header(
                title: headerTitle,
                iconName: isDirectory ? "folder" : "doc",
                trailingText: displayServiceName(inspectedAction.serviceName)
            )
        ]

        var keyValuePairs: [GlanceKeyValuePair] = []
        if isMoveOrCopy, let sourcePath, let destinationPath {
            keyValuePairs.append(GlanceKeyValuePair(key: "From", value: truncatedFieldValue(abbreviatedPath(sourcePath)), tone: .neutral))
            keyValuePairs.append(GlanceKeyValuePair(key: "To", value: truncatedFieldValue(abbreviatedPath(destinationPath)), tone: .neutral))
        } else if let singlePath {
            let fileName = (singlePath as NSString).lastPathComponent
            let parentFolder = (singlePath as NSString).deletingLastPathComponent
            keyValuePairs.append(GlanceKeyValuePair(key: isDirectory ? "Folder" : "File", value: truncatedFieldValue(fileName), tone: .neutral))
            if !parentFolder.isEmpty {
                keyValuePairs.append(GlanceKeyValuePair(key: "In", value: truncatedFieldValue(abbreviatedPath(parentFolder)), tone: .neutral))
            }
        }

        // Flag a write that lands outside the agent's folder — the same line
        // the destructive floor draws, shown so the user sees why it asked.
        if let agentWorkingDirectoryPath {
            let writtenPaths = [singlePath, destinationPath].compactMap { $0 }
            let landsOutsideAgentFolder = writtenPaths.contains { writtenPath in
                !ToolCallInspection.isPath(writtenPath, insideDirectory: agentWorkingDirectoryPath)
            }
            if landsOutsideAgentFolder {
                keyValuePairs.append(GlanceKeyValuePair(key: "Location", value: "Outside agent folder", tone: .bad))
            }
        }
        if !keyValuePairs.isEmpty { blocks.append(.keyValue(pairs: keyValuePairs)) }

        if let contentPreviewBlock = bodyPreviewBlock(forAnyOf: fileContentKeys, in: arguments) {
            blocks.append(contentPreviewBlock)
        } else if case .array(let editItems)? = ToolCallInspection.fieldValue(forAnyOf: ["edits", "changes"], in: arguments),
                  !editItems.isEmpty {
            let editCountText = editItems.count == 1 ? "1 edit" : "\(editItems.count) edits"
            blocks.append(.list(rows: [GlanceListRow(text: editCountText, iconName: "list.bullet", tone: .neutral)]))
        }
        return GlanceCard(blocks: blocks)
    }

    // MARK: - Apple Shortcuts

    /// "Run Shortcut": the shortcut's name and the text it will receive, plus
    /// a reminder that what it does is up to the shortcut — the reason this
    /// card appears even under session auto-approve.
    static func runShortcutCard(toolInput: JSONValue) -> GlanceCard {
        var blocks: [GlanceBlock] = [
            .header(title: "Run Shortcut", iconName: "square.stack.3d.up", trailingText: "Shortcuts")
        ]
        var keyValuePairs: [GlanceKeyValuePair] = []
        if let shortcutName = ToolCallInspection.stringValue(forAnyOf: ["name"], in: toolInput) {
            keyValuePairs.append(GlanceKeyValuePair(key: "Shortcut", value: truncatedFieldValue(shortcutName), tone: .neutral))
        }
        if let shortcutInputText = ToolCallInspection.stringValue(forAnyOf: ["input"], in: toolInput) {
            let inputPreviewText = truncatedPreview(shortcutInputText, maximumCharacters: maximumBodyPreviewCharacters)
            if !inputPreviewText.isEmpty {
                keyValuePairs.append(GlanceKeyValuePair(key: "Input", value: inputPreviewText, tone: .neutral))
            }
        }
        if !keyValuePairs.isEmpty { blocks.append(.keyValue(pairs: keyValuePairs)) }
        blocks.append(.list(rows: [
            GlanceListRow(text: "Does whatever this shortcut is built to do", iconName: "info.circle", tone: .neutral)
        ]))
        return GlanceCard(blocks: blocks)
    }

    // MARK: - Messages

    /// "New Message": the contact's name, the number or address it goes to
    /// (so a wrong match is visible before it sends), and the message.
    static func sendIMessageCard(toolInput: JSONValue) -> GlanceCard {
        var blocks: [GlanceBlock] = [
            .header(title: "New Message", iconName: "message", trailingText: "Messages")
        ]
        var keyValuePairs: [GlanceKeyValuePair] = []
        let recipientName = ToolCallInspection.stringValue(forAnyOf: ["to"], in: toolInput)
        let recipientHandleValue = ToolCallInspection.stringValue(forAnyOf: ["handle"], in: toolInput)
        if let recipientName {
            keyValuePairs.append(GlanceKeyValuePair(key: "To", value: truncatedFieldValue(recipientName), tone: .neutral))
        }
        if let recipientHandleValue, recipientHandleValue != recipientName {
            let handleKey = recipientHandleValue.contains("@") ? "Email" : "Number"
            keyValuePairs.append(GlanceKeyValuePair(key: handleKey, value: truncatedFieldValue(recipientHandleValue), tone: .neutral))
        }
        if !keyValuePairs.isEmpty { blocks.append(.keyValue(pairs: keyValuePairs)) }
        if let bodyPreviewBlock = bodyPreviewBlock(forAnyOf: ["message"], in: toolInput) {
            blocks.append(bodyPreviewBlock)
        }
        return GlanceCard(blocks: blocks)
    }

    // MARK: - Deletion

    private static func deletionCard(for inspectedAction: InspectedToolAction) -> GlanceCard {
        var blocks: [GlanceBlock] = [
            .header(
                title: readableActionTitle(for: inspectedAction),
                iconName: "exclamationmark.triangle",
                trailingText: displayServiceName(inspectedAction.serviceName)
            )
        ]
        let identifyingPairs = scalarArgumentPairs(in: inspectedAction.arguments, maximumPairs: 3)
        if !identifyingPairs.isEmpty { blocks.append(.keyValue(pairs: identifyingPairs)) }
        blocks.append(cannotBeUndoneWarningBlock)
        return GlanceCard(blocks: blocks)
    }

    // MARK: - Other irreversible actions

    /// Payments, merges, invitations, shares — anything the destructive floor
    /// recognises by name but that has no dedicated shape above. Shown as the
    /// action plus its simplest arguments, with the same warning line.
    private static func irreversibleActionCard(for inspectedAction: InspectedToolAction) -> GlanceCard {
        var blocks: [GlanceBlock] = [
            .header(
                title: readableActionTitle(for: inspectedAction),
                iconName: "exclamationmark.triangle",
                trailingText: displayServiceName(inspectedAction.serviceName)
            )
        ]
        let argumentPairs = scalarArgumentPairs(in: inspectedAction.arguments, maximumPairs: 4)
        if !argumentPairs.isEmpty { blocks.append(.keyValue(pairs: argumentPairs)) }
        blocks.append(cannotBeUndoneWarningBlock)
        return GlanceCard(blocks: blocks)
    }

    // MARK: - Several Composio actions

    /// A Composio execute call that runs several tools at once: one row per
    /// tool, with the irreversible ones marked, so the user sees the whole
    /// batch they are approving rather than just its first item.
    private static func multipleActionsCard(for inspectedActions: [InspectedToolAction]) -> GlanceCard {
        let distinctServiceNames = Set(inspectedActions.compactMap(\.serviceName))
        let trailingServiceText = distinctServiceNames.count == 1
            ? displayServiceName(distinctServiceNames.first)
            : nil

        var actionRows: [GlanceListRow] = inspectedActions.prefix(maximumListedActions).map { inspectedAction in
            let isIrreversible = ToolCallSafety.namesIrreversibleAction(actionNameWords: Set(inspectedAction.actionNameWords))
            return GlanceListRow(
                text: readableActionTitle(for: inspectedAction),
                iconName: isIrreversible ? "exclamationmark.triangle" : "checkmark.circle",
                tone: isIrreversible ? .bad : .neutral
            )
        }
        let unlistedActionCount = inspectedActions.count - maximumListedActions
        if unlistedActionCount > 0 {
            actionRows.append(GlanceListRow(text: "and \(unlistedActionCount) more", iconName: nil, tone: .neutral))
        }

        return GlanceCard(blocks: [
            .header(title: "\(inspectedActions.count) Actions", iconName: "list.bullet", trailingText: trailingServiceText),
            .list(rows: actionRows)
        ])
    }

    // MARK: - Block helpers

    private static let cannotBeUndoneWarningBlock: GlanceBlock = .list(rows: [
        GlanceListRow(text: "This can't be taken back", iconName: "exclamationmark.triangle", tone: .bad)
    ])

    /// Key/value rows for whichever of the labelled fields are present, in the
    /// order given, skipping absent or blank ones.
    private static func keyValuePairs(
        from labelledFieldKeys: [(label: String, candidateKeys: [String])],
        in arguments: JSONValue
    ) -> [GlanceKeyValuePair] {
        labelledFieldKeys.compactMap { labelledField in
            guard let fieldText = ToolCallInspection.stringValue(forAnyOf: labelledField.candidateKeys, in: arguments) else {
                return nil
            }
            return GlanceKeyValuePair(key: labelledField.label, value: truncatedFieldValue(fieldText), tone: .neutral)
        }
    }

    /// A one-row list holding the start of a long text field.
    private static func bodyPreviewBlock(forAnyOf candidateKeys: [String], in arguments: JSONValue) -> GlanceBlock? {
        guard let bodyText = ToolCallInspection.stringValue(forAnyOf: candidateKeys, in: arguments) else { return nil }
        let previewText = truncatedPreview(bodyText, maximumCharacters: maximumBodyPreviewCharacters)
        guard !previewText.isEmpty else { return nil }
        return .list(rows: [GlanceListRow(text: previewText, iconName: nil, tone: .neutral)])
    }

    /// The first few simple (string/number/bool) arguments, keys sorted so the
    /// card is the same every time for the same call.
    private static func scalarArgumentPairs(in arguments: JSONValue, maximumPairs: Int) -> [GlanceKeyValuePair] {
        guard case .object(let argumentFields) = arguments else { return [] }
        var pairs: [GlanceKeyValuePair] = []
        for argumentKey in argumentFields.keys.sorted() {
            guard pairs.count < maximumPairs, let argumentValue = argumentFields[argumentKey] else { continue }
            switch argumentValue {
            case .string, .number, .bool:
                guard let valueText = ToolCallInspection.displayText(for: argumentValue) else { continue }
                pairs.append(GlanceKeyValuePair(
                    key: humanReadableKey(argumentKey),
                    value: truncatedFieldValue(valueText),
                    tone: .neutral
                ))
            default:
                continue
            }
        }
        return pairs
    }

    // MARK: - Text helpers

    /// `GITHUB_DELETE_A_REPOSITORY` → "Delete a repository"; the service
    /// prefix is dropped because it is already shown as the header's trailing
    /// text.
    static func readableActionTitle(for inspectedAction: InspectedToolAction) -> String {
        var titleWords = inspectedAction.actionNameWords
        if let serviceName = inspectedAction.serviceName?.lowercased(),
           titleWords.count > 1, titleWords.first == serviceName {
            titleWords.removeFirst()
        }
        let joinedTitle = titleWords.joined(separator: " ")
        guard let firstCharacter = joinedTitle.first else { return inspectedAction.bareActionName }
        return String(firstCharacter).uppercased() + joinedTitle.dropFirst()
    }

    /// `recipient_email` → "Recipient email".
    private static func humanReadableKey(_ argumentKey: String) -> String {
        let joinedKey = ToolCallInspection.words(inIdentifier: argumentKey).joined(separator: " ")
        guard let firstCharacter = joinedKey.first else { return argumentKey }
        return String(firstCharacter).uppercased() + joinedKey.dropFirst()
    }

    /// `gmail` → "Gmail", `composio-connect` → "Composio connect".
    private static func displayServiceName(_ serviceName: String?) -> String? {
        guard let serviceName, !serviceName.isEmpty else { return nil }
        let joinedName = ToolCallInspection.words(inIdentifier: serviceName).joined(separator: " ")
        guard let firstCharacter = joinedName.first else { return nil }
        return String(firstCharacter).uppercased() + joinedName.dropFirst()
    }

    private static func abbreviatedPath(_ rawPath: String) -> String {
        (rawPath as NSString).abbreviatingWithTildeInPath
    }

    private static func truncatedFieldValue(_ fieldText: String) -> String {
        truncatedPreview(fieldText, maximumCharacters: maximumFieldValueCharacters)
    }

    /// Collapses runs of whitespace (newlines included) to single spaces, then
    /// cuts at the limit with an ellipsis, so a long body reads as one tidy
    /// paragraph instead of pushing the Allow button off the card.
    static func truncatedPreview(_ rawText: String, maximumCharacters: Int) -> String {
        let collapsedText = rawText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsedText.count > maximumCharacters else { return collapsedText }
        let cutText = collapsedText.prefix(maximumCharacters).trimmingCharacters(in: .whitespaces)
        return cutText + "…"
    }
}
