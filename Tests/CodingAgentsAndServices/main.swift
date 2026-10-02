//
//  Coding agents & services suite: hook payload parsing, the settings-file
//  merging behind "Install hooks", the hook relay end to end against a test
//  socket, and the service integrations' response parsing.
//

import Darwin
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

func jsonData(_ jsonText: String) -> Data { Data(jsonText.utf8) }

// MARK: - Hook payload parsing

let sessionStart = CodingAgentHookEventParser.parse(payload: [
    "hook_event_name": "SessionStart", "session_id": "abc", "cwd": "/Users/me/code/wisp",
])
check(sessionStart.agentKind == .claudeCode, "an untagged event is Claude Code")
check(sessionStart.kind == .sessionStarted, "SessionStart parses")
check(sessionStart.projectName == "wisp", "the project is the cwd's folder")
check(CodingAgentHookEventParser.parse(payload: ["hook_event_name": "Stop"]).projectName == "Session",
      "no cwd → 'Session'")
check(CodingAgentHookEventParser.parse(payload: ["hook_event_name": "Stop"]).sessionIdentifier == "unknown",
      "no session id → 'unknown'")

check(CodingAgentKind.from(agentTag: "gemini") == .geminiCLI, "gemini tag")
check(CodingAgentKind.from(agentTag: "antigravity") == .antigravity, "antigravity tag")
check(CodingAgentKind.from(agentTag: "my-tool") == .other(name: "my-tool"), "a valid third-party tag")
check(CodingAgentKind.from(agentTag: "claude") == .claudeCode, "'claude' can't be claimed as a tag")
check(CodingAgentKind.from(agentTag: "Bad Name") == .claudeCode, "an invalid tag falls back to Claude Code")
check(CodingAgentKind.from(agentTag: String(repeating: "a", count: 25)) == .claudeCode, "a too-long tag is invalid")
check(CodingAgentHookEventParser.parse(payload: ["coucou_agent": "gemini"]).agentKind == .geminiCLI,
      "Coucou's tag is accepted too")

let bashStep = CodingAgentHookEventParser.parse(payload: [
    "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "npm test"],
])
check(bashStep.kind == .toolStarting(stepDescription: "Running · npm test"), "a Bash step names its command")
let editStep = CodingAgentHookEventParser.parse(payload: [
    "hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": ["file_path": "/a/b/NotchHUDView.swift"],
])
check(editStep.kind == .toolStarting(stepDescription: "Editing · NotchHUDView.swift"), "an Edit step names just the file")
let webStep = CodingAgentHookEventParser.parse(payload: [
    "hook_event_name": "PreToolUse", "tool_name": "WebFetch", "tool_input": ["url": "https://docs.swift.org/x"],
])
check(webStep.kind == .toolStarting(stepDescription: "Fetching · docs.swift.org"), "a fetch names the host")

let longPrompt = CodingAgentHookEventParser.parse(payload: [
    "hook_event_name": "UserPromptSubmit", "prompt": String(repeating: "word ", count: 50),
])
if case .promptSubmitted(let promptText) = longPrompt.kind {
    check(promptText.count == CodingAgentHookEventParser.maximumStepTextLength, "a long prompt is clipped")
    check(promptText.hasSuffix("…"), "a clipped prompt ends with an ellipsis")
} else {
    check(false, "UserPromptSubmit parses as a prompt")
}

let permission = CodingAgentHookEventParser.parse(payload: [
    "hook_event_name": "PermissionRequest", "tool_name": "Bash",
    "tool_input": ["command": "rm -rf build && make"],
    "permission_suggestions": [["type": "addRules"]],
])
check(permission.kind == .permissionRequested(CodingAgentPermissionRequestDetails(
    toolName: "Bash", actionSummary: "rm -rf build && make", offersAlwaysAllow: true
)), "a permission request carries the whole command and the always option")
let permissionWithoutSuggestions = CodingAgentHookEventParser.parse(payload: [
    "hook_event_name": "PermissionRequest", "tool_name": "Write", "tool_input": ["file_path": "/tmp/x.txt"],
])
check(permissionWithoutSuggestions.kind == .permissionRequested(CodingAgentPermissionRequestDetails(
    toolName: "Write", actionSummary: "Write /tmp/x.txt", offersAlwaysAllow: false
)), "a file permission names the full path; no suggestions → no Always")

check(CodingAgentHookEventParser.notificationCategory(for: "Claude hit the usage limit") == .rateLimited, "usage limit")
check(CodingAgentHookEventParser.notificationCategory(for: "Claude is waiting for your input") == .waitingForInput, "waiting")
check(CodingAgentHookEventParser.notificationCategory(for: "Compacting conversation") == .informational, "informational")

let terminalEvent = CodingAgentHookEventParser.parse(payload: [
    "hook_event_name": "SessionStart", "term_program": "iTerm.app", "iterm_session_id": "w0t1p0:ABC-123",
    "tty": "/dev/ttys004", "bundle_id": "com.googlecode.iterm2",
])
check(terminalEvent.terminalContext == CodingAgentTerminalContext(
    terminalProgram: "iTerm.app", hostApplicationBundleIdentifier: "com.googlecode.iterm2",
    iTermSessionIdentifier: "w0t1p0:ABC-123", terminalDevicePath: "/dev/ttys004"
), "terminal context is carried through")

// MARK: - Settings merging

let commandBase = "/bin/sh \"/Users/me/Library/Application Support/Wisp/hooks/wisp-agent-hook\""

func wispHookCount(in settings: [String: Any], event: String) -> Int {
    let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        .filter { CodingAgentHookSettingsMerger.isWispHookCommand($0["command"] as? String ?? "") }
        .count
}

do {
    let installed = try CodingAgentHookSettingsMerger.installingHooks(
        for: .claudeCode, into: [:], commandBase: commandBase, settingsPathForErrors: "settings.json")
    let hooks = installed["hooks"] as? [String: Any] ?? [:]
    check(hooks.count == CodingAgentHookSettingsMerger.claudeCodeEventTimeouts.count, "every Claude Code event gets a hook")
    check(wispHookCount(in: installed, event: "PermissionRequest") == 1, "one permission hook")
    let permissionHook = ((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
    check(permissionHook?["timeout"] as? Int == 120, "the permission hook waits up to 120s")
    check(CodingAgentHookSettingsMerger.containsWispHooks(target: .claudeCode, settings: installed), "detected as installed")

    let installedTwice = try CodingAgentHookSettingsMerger.installingHooks(
        for: .claudeCode, into: installed, commandBase: commandBase, settingsPathForErrors: "settings.json")
    check(wispHookCount(in: installedTwice, event: "PreToolUse") == 1, "installing twice doesn't duplicate")

    let userSettings: [String: Any] = [
        "model": "opus",
        "hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "my-linter"]]]],
            "Stop": [["hooks": [
                ["type": "command", "command": "say done"],
                ["type": "command", "command": "/bin/sh \"/old/wisp-agent-hook\""],
            ]]],
        ],
    ]
    let merged = try CodingAgentHookSettingsMerger.installingHooks(
        for: .claudeCode, into: userSettings, commandBase: commandBase, settingsPathForErrors: "settings.json")
    check(merged["model"] as? String == "opus", "unrelated settings are kept")
    let mergedPreToolUse = (merged["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
    check(mergedPreToolUse.count == 2, "the user's own PreToolUse hook is kept beside Wisp's")
    check(wispHookCount(in: merged, event: "Stop") == 1, "a stale Wisp hook is replaced, not duplicated")
    let mergedStopCommands = ((merged["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? [])
        .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
    check(mergedStopCommands.contains("say done"), "another tool's hook in a shared group is kept")

    let removed = try CodingAgentHookSettingsMerger.removingHooks(
        for: .claudeCode, from: merged, settingsPathForErrors: "settings.json")
    let removedHooks = removed["hooks"] as? [String: Any] ?? [:]
    check(Set(removedHooks.keys) == ["PreToolUse", "Stop"], "removing leaves only the user's events")
    check(!CodingAgentHookSettingsMerger.containsWispHooks(target: .claudeCode, settings: removed), "nothing of Wisp's is left")

    let removedFromOnlyWisp = try CodingAgentHookSettingsMerger.removingHooks(
        for: .claudeCode, from: installed, settingsPathForErrors: "settings.json")
    check(removedFromOnlyWisp["hooks"] == nil, "an emptied hooks key is removed")
} catch {
    check(false, "merging threw: \(error)")
}

do {
    _ = try CodingAgentHookSettingsMerger.installingHooks(
        for: .claudeCode, into: ["hooks": "nope"], commandBase: commandBase, settingsPathForErrors: "settings.json")
    check(false, "a non-object hooks value must be refused")
} catch {
    check(error is CodingAgentHookInstallerError, "an unexpected hooks shape is refused, not overwritten")
}

do {
    let geminiInstalled = try CodingAgentHookSettingsMerger.installingHooks(
        for: .geminiCLI, into: [:], commandBase: commandBase, settingsPathForErrors: "settings.json")
    let beforeTool = ((geminiInstalled["hooks"] as? [String: Any])?["BeforeTool"] as? [[String: Any]])?.first
    let beforeToolCommand = (beforeTool?["hooks"] as? [[String: Any]])?.first?["command"] as? String ?? ""
    check(beforeToolCommand.hasSuffix("--agent gemini PreToolUse"), "Gemini's BeforeTool tells the relay it's a PreToolUse")
    check(beforeTool?["matcher"] as? String == "*", "Gemini hooks match every tool")

    let antigravityInstalled = try CodingAgentHookSettingsMerger.installingHooks(
        for: .antigravity, into: ["other": ["x": 1]], commandBase: commandBase, settingsPathForErrors: "hooks.json")
    check(antigravityInstalled["wisp"] != nil && antigravityInstalled["other"] != nil, "Antigravity gets its own hook set")
    check(CodingAgentHookSettingsMerger.containsWispHooks(target: .antigravity, settings: antigravityInstalled), "detected")
    let antigravityRemoved = try CodingAgentHookSettingsMerger.removingHooks(
        for: .antigravity, from: antigravityInstalled, settingsPathForErrors: "hooks.json")
    check(antigravityRemoved["wisp"] == nil && antigravityRemoved["other"] != nil, "removal takes only Wisp's set")
} catch {
    check(false, "gemini/antigravity merging threw: \(error)")
}

let changePreview = CodingAgentHookChangePreview(
    target: .claudeCode, isInstalling: true,
    currentNormalizedText: "{\n  \"a\": 1\n}",
    proposedText: "{\n  \"a\": 1,\n  \"b\": 2\n}",
    currentFileFingerprint: ""
)
check(changePreview.addedLines == ["  \"a\": 1,", "  \"b\": 2"], "the preview lists added lines")
check(changePreview.removedLines == ["  \"a\": 1"], "the preview lists removed lines")

// MARK: - Relay end to end

/// A one-connection Unix socket server: records the line it receives and
/// answers with `reply` (or nothing).
final class TestHookSocketServer: @unchecked Sendable {
    let socketPath: String
    private let listeningFileDescriptor: Int32
    private let lock = NSLock()
    private var receivedLines: [String] = []

    init(socketPath: String) {
        self.socketPath = socketPath
        unlink(socketPath)
        listeningFileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var socketAddress = sockaddr_un()
        socketAddress.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &socketAddress.sun_path) { sunPathBytes in
            for (byteIndex, pathByte) in socketPath.utf8.enumerated() where byteIndex < sunPathBytes.count - 1 {
                sunPathBytes[byteIndex] = pathByte
            }
        }
        _ = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listeningFileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        listen(listeningFileDescriptor, 4)
    }

    func serveOnce(reply: String?) {
        Thread.detachNewThread { [self] in
            let clientFileDescriptor = accept(listeningFileDescriptor, nil, nil)
            guard clientFileDescriptor >= 0 else { return }
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(clientFileDescriptor, &buffer, buffer.count, 0)
                if count <= 0 { break }
                received.append(contentsOf: buffer[0..<count])
                if buffer[0..<count].contains(UInt8(ascii: "\n")) { break }
            }
            lock.lock(); receivedLines.append(String(decoding: received, as: UTF8.self)); lock.unlock()
            if let reply {
                let replyBytes = Array((reply + "\n").utf8)
                _ = replyBytes.withUnsafeBytes { send(clientFileDescriptor, $0.baseAddress, $0.count, 0) }
            }
            close(clientFileDescriptor)
        }
    }

    func lastReceivedPayload() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let lastLine = receivedLines.last else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: Any]
    }

    deinit {
        close(listeningFileDescriptor)
        unlink(socketPath)
    }
}

/// Runs the relay with `payload` on stdin; returns stdout and the exit status.
func runRelay(scriptPath: String, arguments: [String], payload: [String: Any]) -> (output: String, status: Int32) {
    let relayProcess = Process()
    relayProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    relayProcess.arguments = [scriptPath] + arguments
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    relayProcess.standardInput = inputPipe
    relayProcess.standardOutput = outputPipe
    relayProcess.standardError = FileHandle.nullDevice
    do { try relayProcess.run() } catch { return ("", -1) }
    inputPipe.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
    inputPipe.fileHandleForWriting.closeFile()
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    relayProcess.waitUntilExit()
    return (String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), relayProcess.terminationStatus)
}

func isPythonAvailable() -> Bool {
    let xcodeSelect = Process()
    xcodeSelect.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    xcodeSelect.arguments = ["-p"]
    xcodeSelect.standardOutput = FileHandle.nullDevice
    xcodeSelect.standardError = FileHandle.nullDevice
    guard (try? xcodeSelect.run()) != nil else { return false }
    xcodeSelect.waitUntilExit()
    return xcodeSelect.terminationStatus == 0
}

if isPythonAvailable() {
    // Short path: a Unix socket path must fit in 103 bytes.
    let relayDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wh-\(getpid())")
    try? FileManager.default.createDirectory(at: relayDirectoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: relayDirectoryURL) }
    let socketPath = relayDirectoryURL.appendingPathComponent("s.sock").path
    let relayScriptPath = relayDirectoryURL.appendingPathComponent("relay.py").path
    try? CodingAgentHookRelay.pythonRelaySource(socketPath: socketPath).write(toFile: relayScriptPath, atomically: true, encoding: .utf8)

    let permissionPayload: [String: Any] = [
        "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/project",
        "tool_name": "Bash", "tool_input": ["command": "ls"],
        "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash"]]]],
    ]

    // Allow.
    var testServer: TestHookSocketServer? = TestHookSocketServer(socketPath: socketPath)
    testServer?.serveOnce(reply: #"{"permissionDecision":"allow"}"#)
    let allowResult = runRelay(scriptPath: relayScriptPath, arguments: [], payload: permissionPayload)
    let allowOutput = (try? JSONSerialization.jsonObject(with: Data(allowResult.output.utf8))) as? [String: Any]
    let allowDecision = (allowOutput?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    check(allowResult.status == 0, "the relay exits 0")
    check(allowDecision?["behavior"] as? String == "allow", "allow becomes Claude Code's allow decision")
    let forwardedPayload = testServer?.lastReceivedPayload()
    check(forwardedPayload?["tool_name"] as? String == "Bash", "the payload reaches Wisp")
    check(forwardedPayload?["term_program"] != nil, "the relay adds terminal context")

    // Always: Claude Code's own suggestions are handed back.
    testServer?.serveOnce(reply: #"{"permissionDecision":"always"}"#)
    let alwaysResult = runRelay(scriptPath: relayScriptPath, arguments: [], payload: permissionPayload)
    let alwaysOutput = (try? JSONSerialization.jsonObject(with: Data(alwaysResult.output.utf8))) as? [String: Any]
    let alwaysDecision = (alwaysOutput?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    check(alwaysDecision?["behavior"] as? String == "allow", "always allows")
    check((alwaysDecision?["updatedPermissions"] as? [Any])?.count == 1, "always passes the suggested rules back")

    // Deny.
    testServer?.serveOnce(reply: #"{"permissionDecision":"deny"}"#)
    let denyResult = runRelay(scriptPath: relayScriptPath, arguments: [], payload: permissionPayload)
    check(denyResult.output.contains("\"deny\""), "deny becomes a deny decision")

    // No decision: nothing printed, so Claude Code asks in the terminal.
    testServer?.serveOnce(reply: #"{"permissionDecision":"ask"}"#)
    let askResult = runRelay(scriptPath: relayScriptPath, arguments: [], payload: permissionPayload)
    check(askResult.output.isEmpty && askResult.status == 0, "no decision prints nothing")

    // Gemini: the event name is normalised, the agent tagged, and {} printed.
    testServer?.serveOnce(reply: nil)
    let geminiResult = runRelay(
        scriptPath: relayScriptPath,
        arguments: ["--agent", "gemini", "PreToolUse"],
        payload: ["hook_event_name": "BeforeTool", "toolCall": ["name": "run_shell_command", "args": ["CommandLine": "ls"]]]
    )
    Thread.sleep(forTimeInterval: 0.2)
    let geminiPayload = testServer?.lastReceivedPayload()
    check(geminiResult.output == "{}", "Gemini gets an empty JSON answer")
    check(geminiPayload?["hook_event_name"] as? String == "PreToolUse", "BeforeTool is forwarded as PreToolUse")
    check(geminiPayload?["wisp_agent"] as? String == "gemini", "the agent is tagged")
    check((geminiPayload?["tool_input"] as? [String: Any])?["command"] as? String == "ls", "Gemini's args are normalised")

    // The real server, on its own socket: an event arrives, an approval is
    // answered through the relay, and answering after the relay has hung up
    // (the case that killed the app with SIGPIPE) is survived.
    testServer = nil
    let realServerSocketPath = relayDirectoryURL.appendingPathComponent("r.sock").path
    let realServerRelayPath = relayDirectoryURL.appendingPathComponent("real-relay.py").path
    try? CodingAgentHookRelay.pythonRelaySource(socketPath: realServerSocketPath)
        .write(toFile: realServerRelayPath, atomically: true, encoding: .utf8)
    final class ServerTestRecord: @unchecked Sendable {
        var receivedEvents: [CodingAgentHookEvent] = []
        var heldResponders: [CodingAgentPermissionResponder] = []
    }
    let serverTestRecord = ServerTestRecord()
    CodingAgentHookServer.shared.start(socketPath: realServerSocketPath, installsRelayFiles: false) { hookEvent, permissionResponder in
        serverTestRecord.receivedEvents.append(hookEvent)
        if let permissionResponder {
            if hookEvent.sessionIdentifier == "answer-me" {
                permissionResponder.answer(.allow)
            } else {
                serverTestRecord.heldResponders.append(permissionResponder)
            }
        }
    }
    func waitOnMainRunLoop(seconds: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
    waitOnMainRunLoop(seconds: 2) { CodingAgentHookServer.shared.isListening }
    check(CodingAgentHookServer.shared.isListening, "the real server listens")

    _ = runRelay(scriptPath: realServerRelayPath, arguments: [], payload: ["hook_event_name": "SessionStart", "session_id": "s9", "cwd": "/tmp/p"])
    waitOnMainRunLoop(seconds: 2) { !serverTestRecord.receivedEvents.isEmpty }
    check(serverTestRecord.receivedEvents.first?.kind == .sessionStarted, "a fire-and-forget event reaches the handler (and the server survives it)")

    // The relay blocks for the answer, so it runs off the main thread while
    // the main run loop delivers the event to the handler.
    final class RelayOutputBox: @unchecked Sendable { var output: String? }
    let answeredRelayOutput = RelayOutputBox()
    let answerRelayPayload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "answer-me", "tool_name": "Bash", "tool_input": ["command": "ls"]]
    DispatchQueue.global().async {
        answeredRelayOutput.output = runRelay(scriptPath: realServerRelayPath, arguments: [], payload: answerRelayPayload).output
    }
    waitOnMainRunLoop(seconds: 5) { answeredRelayOutput.output != nil }
    check(answeredRelayOutput.output?.contains("\"allow\"") == true, "a held permission answered Allow reaches Claude Code as allow")

    // A client that sends a permission request and hangs up without waiting.
    let impatientClient = socket(AF_UNIX, SOCK_STREAM, 0)
    var impatientAddress = sockaddr_un()
    impatientAddress.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &impatientAddress.sun_path) { sunPathBytes in
        for (byteIndex, pathByte) in realServerSocketPath.utf8.enumerated() where byteIndex < sunPathBytes.count - 1 {
            sunPathBytes[byteIndex] = pathByte
        }
    }
    _ = withUnsafePointer(to: &impatientAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(impatientClient, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    let impatientLine = Array("{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"gone\",\"tool_name\":\"Bash\"}\n".utf8)
    _ = impatientLine.withUnsafeBytes { send(impatientClient, $0.baseAddress, $0.count, 0) }
    waitOnMainRunLoop(seconds: 2) { !serverTestRecord.heldResponders.isEmpty }
    close(impatientClient)
    Thread.sleep(forTimeInterval: 0.2)
    serverTestRecord.heldResponders.first?.answer(.deny)
    waitOnMainRunLoop(seconds: 1) { false }
    check(!serverTestRecord.heldResponders.isEmpty, "answering a permission after the relay hung up doesn't kill the process")

    // Wisp not running: nothing printed, exit 0, quickly.
    let startDate = Date()
    let offlineResult = runRelay(scriptPath: relayScriptPath, arguments: [], payload: permissionPayload)
    check(offlineResult.output.isEmpty && offlineResult.status == 0, "with Wisp not running the relay is silent")
    check(Date().timeIntervalSince(startDate) < 3, "and doesn't hang")
} else {
    print("(skipping the relay checks: python3 needs the command line tools)")
}

// MARK: - Service response parsing

do {
    let stripe = try ServiceIntegrationResponseParser.stripeSnapshot(
        balanceData: jsonData(#"{"available":[{"amount":1234,"currency":"usd"}],"pending":[{"amount":500,"currency":"usd"}]}"#),
        chargesData: jsonData(#"""
        {"data":[
          {"id":"ch_2","amount":4900,"currency":"usd","status":"succeeded","description":"Pro plan","created":1700000000},
          {"id":"ch_1","amount":900,"currency":"usd","status":"failed","billing_details":{"name":"Ada"},"created":1699990000}
        ]}
        """#)
    )
    check(stripe.headline.contains("12.34") && stripe.headline.contains("5.00 pending"), "Stripe headline: available and pending")
    check(stripe.announceableEvents.map(\.id) == ["ch_2-succeeded", "ch_1-failed"], "Stripe events, newest first")
    check(stripe.announceableEvents.first?.title.contains("49.00") == true, "a payment names its amount")
    check(stripe.announceableEvents.last?.tone == .bad, "a failed charge is bad news")
    check(ServiceIntegrationResponseParser.formattedMoney(minorUnits: 500, currencyCode: "jpy").contains("500"),
          "yen amounts aren't divided by 100")

    let vercel = try ServiceIntegrationResponseParser.vercelSnapshot(deploymentsData: jsonData(#"""
    {"deployments":[
      {"uid":"d3","name":"site","state":"BUILDING","created":1700000000000,"url":"site-3.vercel.app"},
      {"uid":"d2","name":"site","state":"ERROR","created":1699990000000,"url":"site-2.vercel.app","meta":{"githubCommitMessage":"Break it\nbody"}},
      {"uid":"d1","name":"api","readyState":"READY","created":1699980000000,"url":"api-1.vercel.app"}
    ]}
    """#))
    check(vercel.announceableEvents.map(\.id) == ["d2-ERROR", "d1-READY"], "only finished deploys are events")
    check(vercel.announceableEvents.first?.title == "Deploy failed: site", "a failed deploy says so")
    check(vercel.announceableEvents.first?.detail == "Break it", "the commit's subject line is the detail")
    check(vercel.headline == "site · Building", "the headline is the newest deploy")

    let n8n = try ServiceIntegrationResponseParser.n8nSnapshot(
        executionsData: jsonData(#"{"data":[{"id":12,"workflowId":"7","status":"error","startedAt":"2024-05-01T10:00:00.000Z"},{"id":11,"workflowId":"7","status":"success"}]}"#),
        workflowsData: jsonData(#"{"data":[{"id":"7","name":"Invoice sync"}]}"#),
        instanceBaseURL: "https://n8n.example.com"
    )
    check(n8n.rows.first?.title == "Invoice sync", "n8n rows use the workflow's name")
    check(n8n.announceableEvents.map(\.id) == ["12"], "only failed runs are announced")
    check(n8n.headline == "1 of the last 2 runs failed", "n8n headline counts failures")
    check(n8n.rows.first?.url?.absoluteString == "https://n8n.example.com/workflow/7/executions/12", "rows link to the run")

    let resend = try ServiceIntegrationResponseParser.resendSnapshot(emailsData: jsonData(#"""
    {"data":[
      {"id":"e2","to":["a@b.com"],"subject":"Welcome","last_event":"bounced","created_at":"2024-05-01 10:00:00.000000+00"},
      {"id":"e1","to":"c@d.com","subject":"Receipt","last_event":"delivered","created_at":"2024-05-01T09:00:00Z"}
    ]}
    """#))
    check(resend.announceableEvents.map(\.id) == ["e2-bounced"], "a bounce is announced")
    check(resend.rows.last?.detail.contains("to c@d.com") == true, "a single recipient string is read")
    check(ServiceIntegrationResponseParser.parseISO8601Date("2024-05-01 10:00:00.000000+00") != nil, "Resend's date format parses")

    let notion = try ServiceIntegrationResponseParser.notionSnapshot(searchData: jsonData(#"""
    {"results":[{"id":"p1","object":"page","url":"https://notion.so/p1","icon":{"type":"emoji","emoji":"📓"},
      "last_edited_time":"2024-05-01T10:00:00.000Z",
      "properties":{"Name":{"type":"title","title":[{"plain_text":"Road"},{"plain_text":"map"}]}}}]}
    """#))
    check(notion.rows.first?.title == "📓 Roadmap", "a Notion page's title joins its parts, with its emoji")

    let referenceDate = ServiceIntegrationResponseParser.parseISO8601Date("2024-05-01T08:00:00Z")!
    let calcom = try ServiceIntegrationResponseParser.calcomSnapshot(bookingsData: jsonData(#"""
    {"data":[
      {"uid":"b2","title":"Later call","start":"2024-05-02T10:00:00Z","attendees":[{"name":"Bo"}]},
      {"uid":"b1","title":"Intro","start":"2024-05-01T10:00:00Z","attendees":[{"email":"x@y.z"}]},
      {"uid":"b0","title":"Long gone","start":"2024-04-01T10:00:00Z"}
    ]}
    """#), now: referenceDate)
    check(calcom.rows.map(\.id) == ["b1", "b2"], "past bookings are dropped and the rest sorted")
    check(calcom.headline.hasPrefix("Next: Intro"), "the headline is the next booking")
    check(calcom.rows.first?.detail.contains("with x@y.z") == true, "an attendee without a name shows their email")

    let github = try ServiceIntegrationResponseParser.githubSnapshot(
        userData: jsonData(#"{"public_repos":2,"owned_private_repos":1}"#),
        repositoriesData: jsonData(#"[{"full_name":"me/a","stargazers_count":10,"html_url":"https://github.com/me/a"},{"full_name":"me/b","stargazers_count":5}]"#)
    )
    check(github.headline == "3 repos · 15 ★", "GitHub headline")
    check(github.announceableEvents.isEmpty, "GitHub announces nothing")

    do {
        _ = try ServiceIntegrationResponseParser.vercelSnapshot(deploymentsData: jsonData(#"{"error":"x"}"#))
        check(false, "an unexpected response must throw")
    } catch {
        check(error as? ServiceIntegrationFetchError == .unexpectedResponse, "an unexpected shape is reported as such")
    }
} catch {
    check(false, "service parsing threw: \(error)")
}

check(ServiceIntegrationClient.n8nBaseURL(from: "https://n8n.example.com/") == "https://n8n.example.com", "trailing slash trimmed")
check(ServiceIntegrationClient.n8nBaseURL(from: "http://n8n.example.com") == nil, "plain http to another host is refused")
check(ServiceIntegrationClient.n8nBaseURL(from: "http://localhost:5678") == "http://localhost:5678", "http to localhost is fine")
check(ServiceIntegrationClient.n8nBaseURL(from: "not a url") == nil, "garbage is refused")

print(failureCount == 0
    ? "Coding agents & services: all \(checkCount) checks passed"
    : "Coding agents & services: \(failureCount) of \(checkCount) checks FAILED")
exit(failureCount == 0 ? 0 : 1)
