//
//  MCP structured-content suite: how an MCP tool result with
//  `structuredContent` is rendered for the model (element lines, compact JSON,
//  caps), that a result without it is unchanged, the cua-driver always-ask
//  floor and its scoping, and the cua-driver confirmation card built from
//  element tokens Wisp has seen.
//
//  The fixture is a real cua-driver 0.34.1 `get_window_state` result's exact
//  field shapes, with its labels swapped for a neutral Mail compose window.
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

/// Every header title, row and value on a card, in order, for text checks.
func cardTexts(_ card: GlanceCard?) -> [String] {
    guard let card else { return [] }
    return card.blocks.flatMap { block -> [String] in
        switch block {
        case .header(let title, _, let trailingText): return [title] + (trailingText.map { [$0] } ?? [])
        case .keyValue(let pairs): return pairs.flatMap { [$0.key, $0.value] }
        case .list(let rows): return rows.map(\.text)
        case .stats(let items): return items.map(\.value)
        }
    }
}

func headerTitle(_ card: GlanceCard?) -> String? {
    guard case .header(let title, _, _)? = card?.blocks.first else { return nil }
    return title
}

func headerTrailingText(_ card: GlanceCard?) -> String? {
    guard case .header(_, _, let trailingText)? = card?.blocks.first else { return nil }
    return trailingText
}

let cannotBeUndoneText = "This can't be taken back"

// MARK: - Fixture

let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureData = try! Data(contentsOf: fixtureURL)
let fixtureResult = JSONValue(untypedValue: try! JSONSerialization.jsonObject(with: fixtureData))
guard case .object(let fixtureResultFields) = fixtureResult,
      let fixtureStructuredContent = fixtureResultFields["structuredContent"] else {
    fatalError("fixture has no structuredContent")
}
// The same flattening MCPClient applies to `content`: text kept, an image named.
let fixtureFlattenedText = "(image content)\n" + {
    guard case .array(let blocks)? = fixtureResultFields["content"] else { return "" }
    return blocks.compactMap { block -> String? in
        guard case .object(let blockFields) = block, case .string(let text)? = blockFields["text"] else { return nil }
        return text
    }.joined(separator: "\n")
}()

// MARK: - Text-only results are unchanged

section("a result without structuredContent is returned exactly as before")
check(MCPToolResultRendering.modelText(flattenedContentText: "42 files found", structuredContent: nil) == "42 files found",
      "plain text passes through untouched")
check(MCPToolResultRendering.modelText(flattenedContentText: "", structuredContent: nil) == "(the tool returned nothing)",
      "empty text keeps the old placeholder")
check(MCPToolResultRendering.modelText(flattenedContentText: "(image content)", structuredContent: nil) == "(image content)",
      "image-only result keeps the old placeholder")
let longPlainText = String(repeating: "x", count: 20_000)
check(MCPToolResultRendering.modelText(flattenedContentText: longPlainText, structuredContent: nil) == longPlainText,
      "a long text-only result is not newly capped")
check(MCPToolResultRendering.modelText(flattenedContentText: "ok", structuredContent: .null) == "ok",
      "a null structuredContent counts as none")

// MARK: - Element lists

section("an element list becomes one line per element with its token")
let renderedFixture = MCPToolResultRendering.modelText(
    flattenedContentText: fixtureFlattenedText,
    structuredContent: fixtureStructuredContent
)
print(renderedFixture.split(separator: "\n").prefix(12).map { "   │ \($0)" }.joined(separator: "\n"))
check(renderedFixture.contains("s1a2b3c4d:1 Button \"Send\""), "Send button line carries its token")
check(renderedFixture.contains("s1a2b3c4d:2 TextField \"To:\" = \"sam@example.com\""), "a short value is shown")
check(renderedFixture.contains("s1a2b3c4d:4 TextArea \"Message body\" = \"Hi Sam, Are we still on for lunch?\""),
      "a multi-line value is collapsed to one line")
check(renderedFixture.contains("s1a2b3c4d:6 PopUpButton \"From\" (disabled)"), "a disabled element is marked")
check(renderedFixture.contains("s1a2b3c4d:7 Group"), "an unlabelled element still gets its token and role")
check(renderedFixture.contains("app_name=\"Mail\""), "the header names the app")
check(renderedFixture.contains("window_id=777"), "the header carries numeric fields")
check(!renderedFixture.contains("_note"), "underscore-prefixed developer notes are left out")
check(!renderedFixture.contains("tree_markdown="), "a long markdown dump is left out of the header")
check(!renderedFixture.contains("\"frame\""), "frames and other nested fields are not dumped as JSON")
check(renderedFixture.contains("(image content)"), "the image is still named")
let fixtureTextSection = renderedFixture.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
check(fixtureTextSection.count <= MCPToolResultRendering.maximumTextCharactersBesideElementList + 1,
      "beside an element list, the text blocks (the same tree as markdown) are cut short, got \(fixtureTextSection.count)")

section("readable role names")
check(MCPToolResultRendering.readableRoleName("AXButton") == "Button", "AX prefix dropped")
check(MCPToolResultRendering.readableRoleName("AXe") == "AXe", "a role merely starting with AX is kept")
check(MCPToolResultRendering.readableRoleName("button") == "button", "a non-AX role is kept")

section("a large element list is capped")
var manyElements: [JSONValue] = []
for elementIndex in 0..<600 {
    manyElements.append(object([
        "element_token": .string(String(format: "s0000abcd:%d", elementIndex)),
        "role": .string("AXButton"),
        "label": .string("Button number \(elementIndex) with a fairly long label to fill the line"),
    ]))
}
let manyElementsContent = object(["app_name": .string("Xcode"), "elements": .array(manyElements)])
let renderedManyElements = MCPToolResultRendering.renderedStructuredContent(manyElementsContent)
check(renderedManyElements.count <= MCPToolResultRendering.maximumStructuredContentCharacters,
      "element rendering stays within \(MCPToolResultRendering.maximumStructuredContentCharacters), got \(renderedManyElements.count)")
check(renderedManyElements.contains("more elements not shown"), "the omission is stated")
check(renderedManyElements.contains("s0000abcd:0 Button"), "the first elements are kept")
let renderedManyWithText = MCPToolResultRendering.modelText(
    flattenedContentText: String(repeating: "tree line\n", count: 5000),
    structuredContent: manyElementsContent
)
check(renderedManyWithText.count <= MCPToolResultRendering.maximumCombinedResultCharacters,
      "the whole result stays within \(MCPToolResultRendering.maximumCombinedResultCharacters), got \(renderedManyWithText.count)")

section("a long label is shortened, not dropped")
let longLabelLine = MCPToolResultRendering.renderedElementLine([
    "element_token": .string("s00000001:9"),
    "role": .string("AXStaticText"),
    "label": .string(String(repeating: "word ", count: 60)),
])
check(longLabelLine.count < 120, "long label line is short, got \(longLabelLine.count)")
check(longLabelLine.hasSuffix("…\""), "the cut is marked with an ellipsis")

section("a list without roles or ids is not an element list")
let recordsContent = object(["windows": .array([object(["app_name": .string("Notes"), "window_id": .number(5)])])])
check(MCPToolResultRendering.elementList(in: recordsContent) == nil, "windows list is not mistaken for elements")

// MARK: - Generic structured content

section("other structured content becomes compact JSON")
let genericContent = object([
    "zeta": .number(1),
    "alpha": .string("a/b"),
    "nested": object(["flag": .bool(true)]),
])
let renderedGeneric = MCPToolResultRendering.modelText(flattenedContentText: "Done.", structuredContent: genericContent)
check(renderedGeneric == "{\"alpha\":\"a/b\",\"nested\":{\"flag\":true},\"zeta\":1}\n\nDone.",
      "sorted compact JSON first, then the text, got \(renderedGeneric)")

section("text that repeats the structured content as JSON is not shown twice")
let repeatedText = "{\n  \"zeta\": 1, \"alpha\": \"a/b\", \"nested\": {\"flag\": true}\n}"
let renderedWithoutRepeat = MCPToolResultRendering.modelText(flattenedContentText: repeatedText, structuredContent: genericContent)
check(renderedWithoutRepeat == "{\"alpha\":\"a/b\",\"nested\":{\"flag\":true},\"zeta\":1}", "only the compact JSON remains")

section("large generic structured content is capped")
let hugeGenericContent = object(["rows": .array((0..<2000).map { .string("row \($0) of the report") })])
let renderedHugeGeneric = MCPToolResultRendering.modelText(flattenedContentText: "", structuredContent: hugeGenericContent)
check(renderedHugeGeneric.count <= MCPToolResultRendering.maximumStructuredContentCharacters,
      "compact JSON stays within the cap, got \(renderedHugeGeneric.count)")
check(renderedHugeGeneric.contains("…(truncated,"), "the truncation is stated")

// MARK: - The always-ask floor

section("cua-driver action tools always ask, even under session auto-approve")
let anyFolder = "/Users/someone/Wisp"
for actionToolName in CuaDriverToolNames.actionBareToolNames.sorted() {
    check(
        ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: "cua-driver__\(actionToolName)",
            toolInput: object(["element_token": .string("s1a2b3c4d:1")]),
            agentWorkingDirectoryPath: anyFolder
        ),
        "cua-driver__\(actionToolName) asks"
    )
}
check(ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: "cua-driver__browser_navigate", toolInput: object([:]), agentWorkingDirectoryPath: anyFolder),
      "an unlisted cua-driver tool asks too (allow-list of reads, not block-list of actions)")
check(ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: "cua_driver__click", toolInput: object([:]), agentWorkingDirectoryPath: anyFolder),
      "an underscore spelling of the server name is still covered")
check(ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: "cua__type_text", toolInput: object([:]), agentWorkingDirectoryPath: anyFolder),
      "a server named just \"cua\" is still covered")

section("cua-driver read-only tools stay auto-approvable")
for readOnlyToolName in ["list_apps", "list_windows", "get_window_state", "verify_state", "scroll"] {
    check(
        !ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: "cua-driver__\(readOnlyToolName)",
            toolInput: object(["pid": .number(4242)]),
            agentWorkingDirectoryPath: anyFolder
        ),
        "cua-driver__\(readOnlyToolName) does not hit the floor"
    )
}

section("the same bare names on other servers are judged as before")
for otherToolName in ["other-server__click", "figma__type_text", "click", "type_text", "game__press_key", "cuarate__click"] {
    check(
        !ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: otherToolName, toolInput: object([:]), agentWorkingDirectoryPath: anyFolder),
        "\(otherToolName) is not caught by the cua-driver rule"
    )
}
check(ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: "other-server__send_message", toolInput: object([:]), agentWorkingDirectoryPath: anyFolder),
      "the ordinary word floor still applies elsewhere")

// MARK: - The element cache

section("the cache remembers tokens from the latest snapshots")
let elementCache = CuaDriverElementCache.shared
elementCache.removeAll()
elementCache.recordElements(fromStructuredContent: fixtureStructuredContent)
check(elementCache.elementDescription(forToken: "s1a2b3c4d:1") == CuaDriverElementDescription(roleName: "Button", label: "Send", appName: "Mail"),
      "Send button resolved with role, label and app")
check(elementCache.elementDescription(forToken: "s1a2b3c4d:7")?.label == nil, "an unlabelled element has no label")
check(elementCache.elementDescription(forToken: "s99999999:1") == nil, "an unseen token resolves to nothing")
elementCache.recordElements(fromStructuredContent: recordsContent)
check(elementCache.elementDescription(forToken: "s1a2b3c4d:1") != nil, "a result with no elements does not evict anything")
for snapshotNumber in 0..<CuaDriverElementCache.maximumRememberedSnapshots {
    elementCache.recordElements(fromStructuredContent: object([
        "app_name": .string("Finder"),
        "elements": .array([object(["element_token": .string("s0000000\(snapshotNumber):0"), "role": .string("AXButton"), "label": .string("Back")])]),
    ]))
}
check(elementCache.elementDescription(forToken: "s1a2b3c4d:1") == nil, "the oldest snapshot is dropped past the limit")
check(elementCache.elementDescription(forToken: "s00000000:0")?.appName == "Finder", "recent snapshots are kept")

// MARK: - Cards

elementCache.removeAll()
elementCache.recordElements(fromStructuredContent: fixtureStructuredContent)

func cuaCard(_ bareToolName: String, _ toolInput: JSONValue) -> GlanceCard? {
    ToolConfirmationCardBuilder.confirmationCard(
        forToolNamed: "cua-driver__\(bareToolName)",
        toolInput: toolInput,
        agentWorkingDirectoryPath: anyFolder
    )
}

section("a click on a known token says what it presses, and where")
let sendClickCard = cuaCard("click", object(["element_token": .string("s1a2b3c4d:1"), "pid": .number(4242)]))
print("   │ " + cardTexts(sendClickCard).joined(separator: " · "))
check(headerTitle(sendClickCard) == "Click “Send” button", "title names the button, got \(headerTitle(sendClickCard) ?? "nil")")
check(headerTrailingText(sendClickCard) == "Mail", "the app is the trailing text")
check(cardTexts(sendClickCard).contains(cannotBeUndoneText), "Send is marked like other irreversible actions")

section("a harmless click carries no warning")
let fromClickCard = cuaCard("click", object(["element_token": .string("s1a2b3c4d:6")]))
check(headerTitle(fromClickCard) == "Click “From” pop up button", "role words are spelled out, got \(headerTitle(fromClickCard) ?? "nil")")
check(!cardTexts(fromClickCard).contains(cannotBeUndoneText), "no warning for a pop-up")
let deleteDraftCard = cuaCard("double_click", object(["element_token": .string("s1a2b3c4d:5")]))
check(headerTitle(deleteDraftCard) == "Double-click “Delete Draft” button", "double-click verb")
check(cardTexts(deleteDraftCard).contains(cannotBeUndoneText), "Delete is marked irreversible")
let unlabelledCard = cuaCard("right_click", object(["element_token": .string("s1a2b3c4d:7")]))
check(headerTitle(unlabelledCard) == "Right-click unlabelled group", "unlabelled element, got \(headerTitle(unlabelledCard) ?? "nil")")

section("typing, keys, values and menus show what will be entered")
let typeCard = cuaCard("type_text", object(["element_token": .string("s1a2b3c4d:3"), "text": .string("Lunch moved to 1pm")]))
check(headerTitle(typeCard) == "Type into “Subject:” text field", "type title, got \(headerTitle(typeCard) ?? "nil")")
check(cardTexts(typeCard).contains("Lunch moved to 1pm"), "the typed text is shown")
let setValueCard = cuaCard("set_value", object(["element_token": .string("s1a2b3c4d:2"), "value": .string("lee@example.com"), "pid": .number(4242)]))
check(headerTitle(setValueCard) == "Set “To:” text field", "set_value title")
check(cardTexts(setValueCard).contains("lee@example.com"), "the new value is shown")
let hotkeyCard = cuaCard("hotkey", object(["keys": .array([.string("cmd"), .string("shift"), .string("d")]), "pid": .number(4242)]))
check(headerTitle(hotkeyCard) == "Press cmd+shift+d", "hotkey keys joined, got \(headerTitle(hotkeyCard) ?? "nil")")
let pressKeyCard = cuaCard("press_key", object(["key": .string("return"), "modifiers": .array([.string("cmd")]), "element_token": .string("s1a2b3c4d:4")]))
check(headerTitle(pressKeyCard) == "Press cmd+return", "press_key modifiers + key, got \(headerTitle(pressKeyCard) ?? "nil")")
check(cardTexts(pressKeyCard).contains("“Message body” text area"), "the focused element is named")
let menuCard = cuaCard("invoke_menu", object(["path": .array([.string("Message"), .string("Send Again")]), "pid": .number(4242), "window_id": .number(777)]))
check(headerTitle(menuCard) == "Choose Message › Send Again", "menu path shown, got \(headerTitle(menuCard) ?? "nil")")
check(cardTexts(menuCard).contains(cannotBeUndoneText), "a Send menu item is marked irreversible")
let killCard = cuaCard("kill_app", object(["pid": .number(4242)]))
check(headerTitle(killCard) == "Force quit an app", "kill_app title")
check(cardTexts(killCard).contains("4242"), "kill_app shows the pid")
check(cardTexts(killCard).contains(cannotBeUndoneText), "force quitting is marked irreversible")

section("the app is named in place of its pid, and an unnamed app keeps its pid")
let namedAppHotkeyCard = ToolConfirmationCardBuilder.cuaDriverActionCard(
    bareToolName: "hotkey",
    toolInput: object(["keys": .array([.string("cmd"), .string("n")]), "pid": .number(85279), "window_id": .number(17444)]),
    elementCache: CuaDriverElementCache(),
    applicationNameForProcessIdentifier: { processIdentifier in processIdentifier == 85279 ? "Notes" : nil }
)
check(headerTrailingText(namedAppHotkeyCard) == "Notes", "the header names the app, got \(headerTrailingText(namedAppHotkeyCard) ?? "nil")")
check(!cardTexts(namedAppHotkeyCard).contains("85279") && !cardTexts(namedAppHotkeyCard).contains("17444"),
      "pid and window id rows are dropped once the app is named")
let unnamedAppKillCard = ToolConfirmationCardBuilder.cuaDriverActionCard(
    bareToolName: "kill_app",
    toolInput: object(["pid": .number(4242)]),
    elementCache: CuaDriverElementCache(),
    applicationNameForProcessIdentifier: { _ in nil }
)
check(cardTexts(unnamedAppKillCard).contains("4242"), "a force quit whose app can't be named still shows the pid")

section("an unknown token falls back to the raw arguments, and still asks")
let unknownTokenInput = object(["element_token": .string("s99999999:3"), "pid": .number(4242)])
let unknownTokenCard = cuaCard("click", unknownTokenInput)
print("   │ " + cardTexts(unknownTokenCard).joined(separator: " · "))
check(headerTitle(unknownTokenCard) == "Click", "plain verb title")
check(cardTexts(unknownTokenCard).contains("s99999999:3"), "the raw token is shown")
check(cardTexts(unknownTokenCard).contains("4242"), "the other raw arguments are shown")
check(cardTexts(unknownTokenCard).contains { $0.contains("hasn't seen this element") }, "the card says the element is unknown")
check(ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: "cua-driver__click", toolInput: unknownTokenInput, agentWorkingDirectoryPath: anyFolder),
      "the unknown click still asks")
let pixelClickCard = cuaCard("click", object(["x": .number(120), "y": .number(48), "pid": .number(4242)]))
check(cardTexts(pixelClickCard).contains("120, 48"), "a pixel click shows where")

section("cua cards stay out of other servers' calls, and offer no editable fields")
check(ToolConfirmationCardBuilder.confirmationCard(forToolNamed: "other-server__click", toolInput: object(["element_token": .string("s1a2b3c4d:1")]), agentWorkingDirectoryPath: anyFolder) == nil,
      "another server's click gets no cua card")
check(cuaCard("get_window_state", object(["pid": .number(4242)])) == nil, "a cua read gets no card")
check(EditableConfirmationFields.editableFields(forToolNamed: "cua-driver__type_text", toolInput: object(["text": .string("hi")])).isEmpty,
      "typed text is not an editable field")

// MARK: - Routing

let runningApplicationNames = ["Notes", "Finder", "Visual Studio Code", "Google Chrome", "Safari", "Wisp"]
func isNativeAppRequest(_ transcript: String) -> Bool {
    CuaDriverToolRouting.requestIsAboutOperatingNativeApplication(transcript, runningApplicationNames: runningApplicationNames)
}

section("a request about a running app's controls is routed to cua-driver")
check(isNativeAppRequest("click the New Note button in Notes"), "click a button in Notes")
check(isNativeAppRequest("type hello into the search field in Finder"), "type into a field in Finder")
check(isNativeAppRequest("open the Run menu in Visual Studio Code"), "a multi-word app name")
check(isNativeAppRequest("use cua to list my windows"), "naming cua is explicit")

section("anything else is left to the usual routing")
check(!isNativeAppRequest("click the sign in button on github.com in chrome"), "a browser named → browser tools")
check(!isNativeAppRequest("click the Notes link on this website"), "a web request that mentions an app")
check(!isNativeAppRequest("what's in my notes about atlas"), "an app name without a UI word")
check(!isNativeAppRequest("click the button in Mail"), "an app that isn't running")
check(!isNativeAppRequest("click the code button"), "part of an app's name is not the app")
check(!isNativeAppRequest(""), "an empty request")

// MARK: - Which cua tools ask, and how calls must be addressed

section("cua-driver's looking-only tools run without a card; actions and scroll still ask")
for bareToolName in ["list_apps", "list_windows", "get_window_state", "verify_state"] {
    check(!CuaDriverToolNames.requiresConfirmation(bareToolName: bareToolName), "\(bareToolName) runs without a card")
}
for bareToolName in ["click", "type_text", "press_key", "hotkey", "set_value", "invoke_menu", "scroll", "clipboard_read", "kill_app", "some_future_tool"] {
    check(CuaDriverToolNames.requiresConfirmation(bareToolName: bareToolName), "\(bareToolName) asks")
}

section("the model is told where element tokens and pids come from")
let clickSchema = object(["type": .string("object"), "properties": object([
    "pid": object(["type": .string("integer")]),
    "element_token": object(["type": .string("string")]),
])])
let clickDescription = CuaDriverToolNames.modelFacingDescription(originalDescription: "Click against a target pid.", inputSchema: clickSchema)
check(clickDescription.hasPrefix("Click against a target pid."), "the driver's own description comes first")
check(clickDescription.contains("get_window_state") && clickDescription.contains("a12"), "element tokens come from get_window_state, not Wisp's ids")
check(clickDescription.contains("never 0"), "pid must be real")
let listAppsSchema = object(["type": .string("object"), "properties": object(["session": object(["type": .string("string")])])])
check(CuaDriverToolNames.modelFacingDescription(originalDescription: "List apps.", inputSchema: listAppsSchema) == "List apps.",
      "a tool without tokens or pids keeps its description unchanged")

section("a call addressed with Wisp's ids or pid 0 is refused before any card")
check(CuaDriverToolNames.refusalForMisaddressedCall(toolInput: object(["pid": .number(0), "element_token": .string("a13")])) != nil,
      "Wisp's a13 is refused")
check(CuaDriverToolNames.refusalForMisaddressedCall(toolInput: object(["pid": .number(85279), "element_token": .string("t7")])) != nil,
      "Wisp's t7 is refused")
check(CuaDriverToolNames.refusalForMisaddressedCall(toolInput: object(["pid": .number(0), "element_token": .string("s1a2b3c4d:17")]))?.contains("pid") == true,
      "pid 0 is refused")
check(CuaDriverToolNames.refusalForMisaddressedCall(toolInput: object(["pid": .number(85279), "element_token": .string("s1a2b3c4d:17")])) == nil,
      "a real pid and token go ahead")
check(CuaDriverToolNames.refusalForMisaddressedCall(toolInput: object(["pid": .number(85279), "keys": .array([.string("cmd"), .string("n")])])) == nil,
      "a call without a token goes ahead")

// MARK: - Checking an action's effect

section("actions are checked afterwards; reads and off-screen actions aren't")
for bareToolName in ["click", "double_click", "type_text", "press_key", "hotkey", "set_value", "invoke_menu", "drag", "kill_app"] {
    check(CuaDriverPostActionCheck.shouldCheck(afterBareToolName: bareToolName), "\(bareToolName) is checked")
}
for bareToolName in ["get_window_state", "list_windows", "scroll", "clipboard_write", "replay_trajectory"] {
    check(!CuaDriverPostActionCheck.shouldCheck(afterBareToolName: bareToolName), "\(bareToolName) is not checked")
}

section("the check reads the same window and the app's window list")
let menuActionInput = object(["pid": .number(85279), "window_id": .number(17444), "path": .array([.string("File"), .string("New Note")])])
let windowStateCheckArguments = CuaDriverPostActionCheck.windowStateArguments(bareToolName: "invoke_menu", actionInput: menuActionInput)
check(windowStateCheckArguments == object([
    "pid": .number(85279), "window_id": .number(17444),
    "include_screenshot": .bool(false), "max_elements": .number(60),
]), "get_window_state for the acted-on window, without a screenshot")
check(CuaDriverPostActionCheck.windowListArguments(actionInput: menuActionInput) == object(["pid": .number(85279), "on_screen_only": .bool(true)]),
      "list_windows for the app")
check(CuaDriverPostActionCheck.windowStateArguments(bareToolName: "kill_app", actionInput: object(["pid": .number(4242), "window_id": .number(1)])) == nil,
      "a force quit only lists windows (its window is meant to go)")
check(CuaDriverPostActionCheck.windowStateArguments(bareToolName: "hotkey", actionInput: object(["pid": .number(85279), "keys": .array([.string("cmd"), .string("n")])])) == nil,
      "no window named → no window read")
check(CuaDriverPostActionCheck.windowListArguments(actionInput: object(["x": .number(10)])) == nil, "no pid → no window list")

section("the result keeps the action's own text and tells the model to compare")
let checkedResultText = CuaDriverPostActionCheck.resultText(
    actionResultText: "effect: unverifiable",
    windowListText: "Notes — New Note",
    windowStateText: "s1:4 TextArea \"New Note\"",
    lookFailureDescription: nil
)
check(checkedResultText.hasPrefix("effect: unverifiable"), "the action's result comes first")
check(checkedResultText.contains("Notes — New Note") && checkedResultText.contains("s1:4 TextArea"), "both reads are included")
check(checkedResultText.contains("before telling the user it's done"), "the model is told to compare before claiming success")
let failedLookText = CuaDriverPostActionCheck.resultText(actionResultText: "ok", windowListText: nil, windowStateText: nil, lookFailureDescription: "reading the window failed: timed out")
check(failedLookText.contains("couldn't read the app afterwards") && failedLookText.contains("timed out"), "a failed read is said, not hidden")
check(CuaDriverToolNames.modelFacingDescription(originalDescription: "Click.", inputSchema: object([:]), bareToolName: "click").contains("re-reads the app"),
      "an action's description says it will be checked")
check(!CuaDriverToolNames.modelFacingDescription(originalDescription: "List.", inputSchema: object([:]), bareToolName: "list_windows").contains("re-reads"),
      "a read's description doesn't")

// MARK: - MCPClient

await runScriptedTransportChecks(structuredToolResult: fixtureResult)

print("\n\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
