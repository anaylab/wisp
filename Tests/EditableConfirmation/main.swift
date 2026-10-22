//
//  Editable confirmation suite: which fields of a pending tool call the card
//  offers for editing, and the rule that edits can only ever land on those.
//
//  The safety half matters most. A field the user may edit changes what the
//  call says; a field they may not (a recipient, a handle, a path, a nested
//  Composio argument) would change what was consented to, so every edit to
//  one of those must be dropped — whatever key it names.
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

func section(_ name: String) { print("── \(name)") }

func object(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

func editableKeys(_ toolName: String, _ toolInput: JSONValue) -> [String] {
    EditableConfirmationFields.editableFields(forToolNamed: toolName, toolInput: toolInput).map(\.argumentKey)
}

func stringField(_ key: String, in toolInput: JSONValue) -> String? {
    guard case .object(let fields) = toolInput, case .string(let text)? = fields[key] else { return nil }
    return text
}

// MARK: - Email

section("email: subject and body are editable, recipients are not")
let emailInput = object([
    "to": .string("sam@example.com"),
    "cc": .string("lee@example.com"),
    "subject": .string("Lunch"),
    "body": .string("See you at noon."),
])
let emailFields = EditableConfirmationFields.editableFields(forToolNamed: "gmail__send_email", toolInput: emailInput)
check(emailFields.map(\.argumentKey) == ["subject", "body"], "email fields are subject then body, got \(emailFields.map(\.argumentKey))")
check(emailFields.first?.isMultiline == false, "subject is single-line")
check(emailFields.last?.isMultiline == true, "body is multi-line")
check(emailFields.first?.replacedCardRowLabel == "Subject", "subject replaces the card's Subject row")
check(emailFields.last?.replacedCardRowLabel == nil, "body replaces the preview line, not a row")
check(emailFields.first?.originalText == "Lunch", "original text is kept verbatim")

section("email: edits apply to allowed keys")
let editedEmail = EditableConfirmationFields.applyingEdits(
    ["subject": "Lunch moved to 1pm"],
    toToolInput: emailInput,
    toolNamed: "gmail__send_email"
)
check(stringField("subject", in: editedEmail.toolInput) == "Lunch moved to 1pm", "subject edit applied")
check(stringField("body", in: editedEmail.toolInput) == "See you at noon.", "unedited body untouched")
check(stringField("to", in: editedEmail.toolInput) == "sam@example.com", "recipient untouched")
check(editedEmail.editedFields == [EditedConfirmationField(argumentKey: "subject", label: "Subject", editedText: "Lunch moved to 1pm")],
      "edited fields name the subject")
check(editedEmail.hasEdits, "hasEdits is true")

section("email: edits to non-editable keys are ignored")
let refusedEmailEdit = EditableConfirmationFields.applyingEdits(
    ["to": "attacker@example.com", "cc": "x@example.com", "bcc": "y@example.com", "tool": "delete_everything"],
    toToolInput: emailInput,
    toolNamed: "gmail__send_email"
)
check(refusedEmailEdit.toolInput == emailInput, "input unchanged when only disallowed keys are edited")
check(refusedEmailEdit.editedFields.isEmpty, "no edited fields reported")

section("email: allowed and disallowed edits together — only the allowed one lands")
let mixedEmailEdit = EditableConfirmationFields.applyingEdits(
    ["body": "See you at 1.", "to": "attacker@example.com"],
    toToolInput: emailInput,
    toolNamed: "gmail__send_email"
)
check(stringField("body", in: mixedEmailEdit.toolInput) == "See you at 1.", "body edit applied")
check(stringField("to", in: mixedEmailEdit.toolInput) == "sam@example.com", "recipient edit dropped")
check(mixedEmailEdit.editedFields.map(\.argumentKey) == ["body"], "only body reported edited")

section("no edits / blank edits / unchanged edits leave the input as it was")
check(EditableConfirmationFields.applyingEdits([:], toToolInput: emailInput, toolNamed: "gmail__send_email").toolInput == emailInput,
      "no edits → identical input")
let blankEdit = EditableConfirmationFields.applyingEdits(["subject": "   \n"], toToolInput: emailInput, toolNamed: "gmail__send_email")
check(blankEdit.toolInput == emailInput && !blankEdit.hasEdits, "a blanked field is ignored")
let sameEdit = EditableConfirmationFields.applyingEdits(["subject": "Lunch"], toToolInput: emailInput, toolNamed: "gmail__send_email")
check(sameEdit.toolInput == emailInput && !sameEdit.hasEdits, "an edit equal to the original is not an edit")

section("lenient key lookup, exact key written back")
let capitalisedEmailInput = object([
    "To": .string("sam@example.com"),
    "Subject": .string("Lunch"),
    "Body": .string("Noon."),
])
check(editableKeys("gmail__send_email", capitalisedEmailInput) == ["Subject", "Body"],
      "keys found case-insensitively and reported as spelled, got \(editableKeys("gmail__send_email", capitalisedEmailInput))")
let capitalisedEdit = EditableConfirmationFields.applyingEdits(
    ["Subject": "Lunch at 1", "subject": "lowercase twin"],
    toToolInput: capitalisedEmailInput,
    toolNamed: "gmail__send_email"
)
check(stringField("Subject", in: capitalisedEdit.toolInput) == "Lunch at 1", "edit lands on the exact key")
check(stringField("subject", in: capitalisedEdit.toolInput) == nil, "no second spelling of the key is added")
check(ToolCallInspection.matchingFieldKey(forAnyOf: ["message_body"], in: object(["messageBody": .string("hi")])) == "messageBody",
      "underscore/camelCase spellings agree, as in fieldValue")
check(ToolCallInspection.matchingFieldKey(forAnyOf: ["subject"], in: object(["subject": .null])) == nil,
      "a null field is skipped, as in fieldValue")
check(ToolCallInspection.fieldValue(forAnyOf: ["Start-Time"], in: object(["start_time": .string("9am")])) == .string("9am"),
      "fieldValue still reads leniently after the refactor")

section("a non-string value is never editable")
let numericSubjectInput = object(["to": .string("sam@example.com"), "subject": .number(42), "body": .string("hi")])
check(editableKeys("gmail__send_email", numericSubjectInput) == ["body"], "numeric subject is read-only")
let numericSubjectEdit = EditableConfirmationFields.applyingEdits(["subject": "now text"], toToolInput: numericSubjectInput, toolNamed: "gmail__send_email")
check(numericSubjectEdit.toolInput == numericSubjectInput, "edit to a non-string field is ignored")

// MARK: - Messages and posts

section("send_imessage: only the message")
let preparedMessageInput = object([
    "to": .string("Mom"),
    "handle": .string("+15551234567"),
    "message": .string("running late"),
    "contact_id": .string("ABC"),
])
check(editableKeys("send_imessage", preparedMessageInput) == ["message"], "only message is editable")
let messageEdit = EditableConfirmationFields.applyingEdits(
    ["message": "running 10 min late", "handle": "+15550000000", "to": "Boss", "contact_id": "XYZ"],
    toToolInput: preparedMessageInput,
    toolNamed: "send_imessage"
)
check(stringField("message", in: messageEdit.toolInput) == "running 10 min late", "message edit applied")
check(stringField("handle", in: messageEdit.toolInput) == "+15551234567", "handle edit dropped")
check(stringField("to", in: messageEdit.toolInput) == "Mom", "recipient name edit dropped")
check(stringField("contact_id", in: messageEdit.toolInput) == "ABC", "contact id edit dropped")

section("chat message: text editable, channel not")
let slackInput = object(["channel": .string("#general"), "text": .string("shipping today")])
check(editableKeys("slack__send_message", slackInput) == ["text"], "slack text editable, got \(editableKeys("slack__send_message", slackInput))")
let slackEdit = EditableConfirmationFields.applyingEdits(["channel": "#random", "text": "shipping tomorrow"], toToolInput: slackInput, toolNamed: "slack__send_message")
check(stringField("channel", in: slackEdit.toolInput) == "#general", "channel edit dropped")
check(stringField("text", in: slackEdit.toolInput) == "shipping tomorrow", "text edit applied")

section("post: title and text")
let postInput = object(["title": .string("Release notes"), "content": .string("v2 is out")])
check(editableKeys("blog__create_post", postInput) == ["title", "content"], "post title and content editable, got \(editableKeys("blog__create_post", postInput))")

// MARK: - Calendar, reminders, shortcuts

section("calendar event: title and location, never guests or times")
let eventInput = object([
    "summary": .string("Standup"),
    "location": .string("Room 4"),
    "start": .string("2026-10-06T09:00"),
    "attendees": .array([.string("sam@example.com")]),
])
check(editableKeys("calendar__create_event", eventInput) == ["summary", "location"],
      "event title + location editable, got \(editableKeys("calendar__create_event", eventInput))")
let eventFields = EditableConfirmationFields.editableFields(forToolNamed: "calendar__create_event", toolInput: eventInput)
check(eventFields.map(\.replacedCardRowLabel) == ["Title", "Where"], "event fields replace Title and Where rows")
let eventEdit = EditableConfirmationFields.applyingEdits(
    ["summary": "Daily standup", "start": "2026-10-07T09:00", "attendees": "everyone@example.com"],
    toToolInput: eventInput,
    toolNamed: "calendar__create_event"
)
check(stringField("summary", in: eventEdit.toolInput) == "Daily standup", "title edit applied")
check(stringField("start", in: eventEdit.toolInput) == "2026-10-06T09:00", "start edit dropped")
if case .object(let eventFieldsAfterEdit) = eventEdit.toolInput {
    check(eventFieldsAfterEdit["attendees"] == .array([.string("sam@example.com")]), "guests edit dropped")
}

section("create_reminder: title only")
let reminderInput = object(["title": .string("call dentist"), "due": .string("2026-10-06"), "list": .string("Home")])
check(editableKeys("create_reminder", reminderInput) == ["title"], "reminder title editable")
let reminderEdit = EditableConfirmationFields.applyingEdits(["title": "call the dentist", "list": "Work"], toToolInput: reminderInput, toolNamed: "create_reminder")
check(stringField("title", in: reminderEdit.toolInput) == "call the dentist", "reminder title edit applied")
check(stringField("list", in: reminderEdit.toolInput) == "Home", "reminder list edit dropped")

section("run_shortcut: input, never the shortcut's name")
let shortcutInput = object(["name": .string("Log Water"), "input": .string("250ml")])
check(editableKeys("run_shortcut", shortcutInput) == ["input"], "shortcut input editable")
let shortcutEdit = EditableConfirmationFields.applyingEdits(["name": "Delete All Photos", "input": "500ml"], toToolInput: shortcutInput, toolNamed: "run_shortcut")
check(stringField("name", in: shortcutEdit.toolInput) == "Log Water", "shortcut name edit dropped")
check(stringField("input", in: shortcutEdit.toolInput) == "500ml", "shortcut input edit applied")
check(editableKeys("run_shortcut", object(["name": .string("Log Water")])).isEmpty, "no input → nothing to edit (a field is never added)")

// MARK: - Nothing editable

section("file writes, deletions, reads, unknown tools: nothing editable")
check(editableKeys("filesystem__write_file", object(["path": .string("/tmp/a.txt"), "content": .string("hi")])).isEmpty, "file write")
check(editableKeys("gmail__delete_email", object(["subject": .string("Lunch"), "id": .string("1")])).isEmpty, "deletion")
check(editableKeys("gmail__search_emails", object(["subject": .string("Lunch")])).isEmpty, "read-only search")
check(editableKeys("weather__lookup", object(["text": .string("paris")])).isEmpty, "unrecognised tool")
check(editableKeys("ask_buddy", object(["to": .string("Scout"), "message": .string("help")])).isEmpty, "ask_buddy stays read-only")
check(editableKeys("gmail__send_email", .string("not an object")).isEmpty, "non-object input")
let fileWriteInput = object(["path": .string("/tmp/a.txt"), "content": .string("hi")])
check(EditableConfirmationFields.applyingEdits(["content": "rm -rf", "path": "/etc/passwd"], toToolInput: fileWriteInput, toolNamed: "filesystem__write_file").toolInput == fileWriteInput,
      "file write edits ignored")

section("Composio batches and wrappers stay untouched")
let composioBatchInput = object([
    "tools": .array([
        object(["tool_slug": .string("GMAIL_SEND_EMAIL"), "arguments": object(["to": .string("a@b.com"), "subject": .string("Hi"), "body": .string("x")])]),
        object(["tool_slug": .string("SLACK_SEND_MESSAGE"), "arguments": object(["channel": .string("#x"), "text": .string("y")])]),
    ])
])
check(editableKeys("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", composioBatchInput).isEmpty, "batch has no editable fields")
let composioBatchEdit = EditableConfirmationFields.applyingEdits(
    ["tools": "[]", "subject": "Hello", "body": "z", "text": "z"],
    toToolInput: composioBatchInput,
    toolNamed: "composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL"
)
check(composioBatchEdit.toolInput == composioBatchInput && !composioBatchEdit.hasEdits, "batch edits ignored, nested arguments untouched")
let composioSingleInput = object([
    "tool_slug": .string("GMAIL_SEND_EMAIL"),
    "arguments": object(["to": .string("a@b.com"), "subject": .string("Hi"), "body": .string("x")]),
    "subject": .string("decoy top-level subject"),
])
check(editableKeys("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", composioSingleInput).isEmpty, "single-tool wrapper has no editable fields")
check(EditableConfirmationFields.applyingEdits(["subject": "changed"], toToolInput: composioSingleInput, toolNamed: "composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL").toolInput == composioSingleInput,
      "single-tool wrapper edits ignored")
check(editableKeys("composio-connect__COMPOSIO_SEARCH_TOOLS", object(["text": .string("send email")])).isEmpty, "other Composio meta-tools")

section("nested objects are never reached into")
let nestedEmailInput = object([
    "to": .string("sam@example.com"),
    "subject": .string("Hi"),
    "body": object(["text": .string("nested body")]),
])
check(editableKeys("gmail__send_email", nestedEmailInput) == ["subject"], "an object-valued body is read-only")
let nestedEdit = EditableConfirmationFields.applyingEdits(["body": "flat now", "text": "x"], toToolInput: nestedEmailInput, toolNamed: "gmail__send_email")
check(nestedEdit.toolInput == nestedEmailInput, "nested body untouched")

// MARK: - The note for the model

section("tool result note")
check(EditableConfirmationFields.toolResultNote(for: []) == nil, "no note without edits")
let note = EditableConfirmationFields.toolResultNote(for: editedEmail.editedFields) ?? ""
check(note.contains("edited"), "note says the user edited it")
check(note.contains("subject: \"Lunch moved to 1pm\""), "note quotes the edited subject, got \(note)")
let longText = String(repeating: "a", count: 500)
let longNote = EditableConfirmationFields.toolResultNote(for: [EditedConfirmationField(argumentKey: "body", label: "Body", editedText: longText)]) ?? ""
check(longNote.contains(String(repeating: "a", count: EditableConfirmationFields.maximumEditedTextCharactersInToolResult) + "…"), "long edits are clipped")
check(!longNote.contains(String(repeating: "a", count: EditableConfirmationFields.maximumEditedTextCharactersInToolResult + 1)), "clipped at the limit")

// MARK: - The card beside the fields

section("card rows replaced by fields are hidden, the rest stay")
if let emailCard = ToolConfirmationCardBuilder.confirmationCard(forToolNamed: "gmail__send_email", toolInput: emailInput, agentWorkingDirectoryPath: nil) {
    let trimmedCard = EditableConfirmationFields.card(emailCard, hidingRowsShownBy: emailFields)
    var keyValueKeys: [String] = []
    var listTexts: [String] = []
    var headerCount = 0
    for block in trimmedCard.blocks {
        switch block {
        case .keyValue(let pairs): keyValueKeys += pairs.map(\.key)
        case .list(let rows): listTexts += rows.map(\.text)
        case .header: headerCount += 1
        case .stats: break
        }
    }
    check(headerCount == 1, "header kept")
    check(keyValueKeys == ["To", "Cc"], "To and Cc kept, Subject hidden, got \(keyValueKeys)")
    check(listTexts.isEmpty, "body preview hidden, got \(listTexts)")
    check(trimmedCard.id == emailCard.id, "card identity kept")
    check(EditableConfirmationFields.card(emailCard, hidingRowsShownBy: []) == emailCard, "no fields → card unchanged")
} else {
    check(false, "email card was built")
}
if let shortcutCard = ToolConfirmationCardBuilder.confirmationCard(forToolNamed: "run_shortcut", toolInput: shortcutInput, agentWorkingDirectoryPath: nil) {
    let shortcutFields = EditableConfirmationFields.editableFields(forToolNamed: "run_shortcut", toolInput: shortcutInput)
    let trimmedShortcutCard = EditableConfirmationFields.card(shortcutCard, hidingRowsShownBy: shortcutFields)
    let remainingRowLabels = trimmedShortcutCard.blocks.flatMap { block -> [String] in
        if case .keyValue(let pairs) = block { return pairs.map(\.key) }
        if case .list(let rows) = block { return rows.map(\.text) }
        return []
    }
    check(remainingRowLabels.contains("Shortcut"), "shortcut name row kept")
    check(!remainingRowLabels.contains("Input"), "input row hidden")
    check(remainingRowLabels.contains("Does whatever this shortcut is built to do"), "the warning row (with an icon) is kept")
}

// MARK: - Chrome tab life (phase 04)

let staleSweepInput: JSONValue = .object([
    "session_name": .string("Cleanup Oct 21"),
    "minimum_days": .number(14),
    "tabs": .array((1...10).map { tabNumber in
        .object(["id": .number(Double(tabNumber)), "title": .string("Tab \(tabNumber)"), "url": .string("https://site\(tabNumber).example/")])
    }),
])
for tabLifeToolName in ["chrome_close_stale_tabs", "chrome_apply_tab_triage", "chrome_restore_tab_session"] {
    check(
        ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: tabLifeToolName, toolInput: staleSweepInput, agentWorkingDirectoryPath: "/tmp/agent"),
        "\(tabLifeToolName) asks even under session auto-approve"
    )
}
check(
    !ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: "chrome_list_tab_sessions", toolInput: .object([:]), agentWorkingDirectoryPath: "/tmp/agent"),
    "listing tab sessions doesn't"
)
if let staleSweepCard = ToolConfirmationCardBuilder.confirmationCard(forToolNamed: "chrome_close_stale_tabs", toolInput: staleSweepInput, agentWorkingDirectoryPath: nil),
   case .header(let headerTitle, _, _)? = staleSweepCard.blocks.first {
    check(headerTitle == "Close 10 tabs · saved as 'Cleanup Oct 21' first", "stale sweep card headline")
    let titleRows = staleSweepCard.blocks.flatMap { block -> [GlanceKeyValuePair] in
        if case .keyValue(let pairs) = block { return pairs }
        return []
    }
    check(titleRows.count == 8 && titleRows.first?.key == "Tab 1", "up to 8 tab titles")
    let footerTexts = staleSweepCard.blocks.flatMap { block -> [String] in
        if case .list(let rows) = block { return rows.map(\.text) }
        return []
    }
    check(footerTexts.contains("and 2 more"), "the rest are counted")
} else {
    check(false, "stale sweep card is built")
}
check(
    EditableConfirmationFields.editableFields(forToolNamed: "chrome_close_stale_tabs", toolInput: staleSweepInput).isEmpty,
    "nothing on the stale sweep card is editable"
)

print("\n\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
