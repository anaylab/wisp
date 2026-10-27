//
//  Live check against the real cua-driver, through Wisp's own MCP client and
//  renderer: starts `cua-driver mcp --direct` with telemetry and update checks
//  off, calls ONLY the read-only `list_windows` and `get_window_state`, and
//  prints what the model would see plus the card a click on one of the
//  returned buttons would get. No action tool is ever called.
//

import Foundation

let readOnlyToolsThisCheckMayCall: Set<String> = ["list_windows", "get_window_state"]

var liveFailureCount = 0
func liveCheck(_ condition: Bool, _ description: String) {
    print(condition ? "ok   \(description)" : "FAIL \(description)")
    if !condition { liveFailureCount += 1 }
}

func callReadOnlyTool(
    _ toolName: String,
    _ arguments: JSONValue,
    on connection: MCPServerConnection
) async throws -> MCPServerConnection.ToolCallContent {
    precondition(readOnlyToolsThisCheckMayCall.contains(toolName), "the live check only reads")
    return try await connection.callToolReturningContent(name: toolName, arguments: arguments)
}

let cuaDriverPath = CommandLine.arguments[1]
let connection = MCPServerConnection(configuration: MCPServerConfiguration(
    name: "cua-driver",
    command: cuaDriverPath,
    arguments: ["mcp", "--direct"],
    environment: [
        "DO_NOT_TRACK": "1",
        "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false",
        "CUA_DRIVER_RS_UPDATE_CHECK": "false",
    ]
))

do {
    try await connection.connect()
    let discoveredToolNames = Set(await connection.discoveredTools.map(\.name))
    liveCheck(discoveredToolNames.isSuperset(of: ["list_windows", "get_window_state", "click"]), "tools/list has the expected tools (\(discoveredToolNames.count) total)")

    // Pick the largest on-screen window on the current Space: off-Space
    // windows come back with an empty tree on purpose.
    let windowListContent = try await callReadOnlyTool("list_windows", .object(["on_screen_only": .bool(true)]), on: connection)
    var chosenWindow: (pid: Double, windowID: Double, appName: String, area: Double)?
    if case .object(let windowListFields)? = windowListContent.structuredContent,
       case .array(let windowValues)? = windowListFields["windows"] {
        for windowValue in windowValues {
            guard case .object(let windowFields) = windowValue,
                  case .number(let pid)? = windowFields["pid"],
                  case .number(let windowID)? = windowFields["window_id"],
                  case .object(let boundsFields)? = windowFields["bounds"],
                  case .number(let windowWidth)? = boundsFields["width"],
                  case .number(let windowHeight)? = boundsFields["height"],
                  windowHeight > 100 else { continue }
            let appName: String
            if case .string(let windowAppName)? = windowFields["app_name"] { appName = windowAppName } else { appName = "?" }
            if chosenWindow == nil || windowWidth * windowHeight > chosenWindow!.area {
                chosenWindow = (pid, windowID, appName, windowWidth * windowHeight)
            }
        }
    }
    guard let chosenWindow else {
        liveCheck(false, "an on-screen window to read")
        exit(1)
    }
    print("reading \(chosenWindow.appName) (pid \(Int(chosenWindow.pid)), window \(Int(chosenWindow.windowID)))")

    let windowStateContent = try await callReadOnlyTool("get_window_state", .object([
        "pid": .number(chosenWindow.pid),
        "window_id": .number(chosenWindow.windowID),
        "max_elements": .number(80),
        "max_image_dimension": .number(256),
    ]), on: connection)

    let tokenPattern = try NSRegularExpression(pattern: "s[0-9a-f]{8}:[0-9]+")
    let flattenedText = windowStateContent.flattenedContentText
    let tokensInTextBlocks = tokenPattern.numberOfMatches(in: flattenedText, range: NSRange(flattenedText.startIndex..., in: flattenedText))
    liveCheck(tokensInTextBlocks == 0, "the text blocks alone carry no element tokens (the reason for this change)")
    let modelText = MCPToolResultRendering.modelText(
        flattenedContentText: windowStateContent.flattenedContentText,
        structuredContent: windowStateContent.structuredContent
    )
    let tokenMatchCount = tokenPattern.numberOfMatches(in: modelText, range: NSRange(modelText.startIndex..., in: modelText))
    liveCheck(tokenMatchCount > 0, "the model text carries \(tokenMatchCount) element tokens")
    liveCheck(modelText.count <= MCPToolResultRendering.maximumCombinedResultCharacters, "the model text is within the cap (\(modelText.count) characters)")

    print("\n── what the model sees (first 14 lines) ──")
    print(modelText.split(separator: "\n", omittingEmptySubsequences: false).prefix(14).joined(separator: "\n"))

    // The card a click on the first labelled button would get. Built only;
    // nothing is clicked.
    if let structuredContent = windowStateContent.structuredContent {
        CuaDriverElementCache.shared.recordElements(fromStructuredContent: structuredContent)
        if let (_, elements) = MCPToolResultRendering.elementList(in: structuredContent),
           let firstButton = elements.first(where: {
               MCPToolResultRendering.firstScalarText(forAnyOf: ["role"], in: $0) == "AXButton"
                   && MCPToolResultRendering.firstScalarText(forAnyOf: ["label"], in: $0) != nil
           }),
           let buttonToken = MCPToolResultRendering.firstScalarText(forAnyOf: ["element_token"], in: firstButton) {
            let clickCard = ToolConfirmationCardBuilder.confirmationCard(
                forToolNamed: "cua-driver__click",
                toolInput: .object(["element_token": .string(buttonToken), "pid": .number(chosenWindow.pid)]),
                agentWorkingDirectoryPath: nil
            )
            var cardTexts: [String] = []
            for block in clickCard?.blocks ?? [] {
                switch block {
                case .header(let title, _, let trailingText): cardTexts.append(title); if let trailingText { cardTexts.append(trailingText) }
                case .keyValue(let pairs): cardTexts.append(contentsOf: pairs.map { "\($0.key): \($0.value)" })
                case .list(let rows): cardTexts.append(contentsOf: rows.map(\.text))
                case .stats: break
                }
            }
            print("\n── card for a (not performed) click on \(buttonToken) ──")
            print(cardTexts.joined(separator: " · "))
            liveCheck(cardTexts.first?.hasPrefix("Click “") == true, "the click card names the button")
            liveCheck(ToolCallSafety.mustAskEvenWithSessionAutoApprove(
                toolName: "cua-driver__click",
                toolInput: .object(["element_token": .string(buttonToken)]),
                agentWorkingDirectoryPath: NSHomeDirectory()
            ), "the click would ask even under session auto-approve")
        } else {
            print("(no labelled button in this window to build a sample card from)")
        }
    }
} catch {
    liveCheck(false, "live cua-driver session: \(error)")
}
await connection.disconnect()
print(liveFailureCount == 0 ? "\nlive cua-driver check passed" : "\nlive cua-driver check: \(liveFailureCount) failed")
exit(liveFailureCount == 0 ? 0 : 1)
