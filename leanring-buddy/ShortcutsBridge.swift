//
//  ShortcutsBridge.swift
//  leanring-buddy
//
//  Lets Wisp list and run the user's Apple Shortcuts through the system
//  `/usr/bin/shortcuts` command-line tool.
//
//  Why the command-line tool: it is the one supported, public way for a third
//  party to run a shortcut on macOS, it ships with every Mac, and it needs no
//  server, no key and no network — a user's hundreds of existing automations
//  become agent tools while everything stays on this machine.
//
//  Three rules shape the code here:
//  - The shortcut name always travels as one element of an argument array
//    (never through a shell string), after a `--` terminator, so a name with
//    spaces, quotes or a leading dash cannot be read as anything but a name.
//  - Every run is bounded by a timeout and killed if it overruns or the turn is
//    cancelled, so a shortcut waiting on a dialog nobody sees cannot hold the
//    conversation open.
//  - Text handed back to the model is capped, because it shares a context
//    window with a screenshot.
//
//  Listing is cached (a few minutes) because spawning the tool costs a few
//  hundred milliseconds and the list barely changes; the dashboard's refresh
//  button and a failed name lookup both force a fresh read.
//

import Combine
import Foundation

// MARK: - One shortcut

/// One entry from `shortcuts list --show-identifiers`.
nonisolated struct AppleShortcutEntry: Equatable, Sendable {
    /// The name as the user sees it in the Shortcuts app.
    let name: String
    /// The shortcut's UUID, when the listing included one. Running by
    /// identifier is preferred because it cannot collide with another name.
    let identifier: String?
}

// MARK: - Parsing `shortcuts list`

nonisolated enum ShortcutsListParser {
    /// Matches the ` (UUID)` suffix `--show-identifiers` appends to each line.
    /// Only a real UUID counts, so a shortcut literally named "Backup (daily)"
    /// keeps its parenthesis as part of its name.
    private static let trailingIdentifierPattern =
        " \\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\\)$"

    /// One entry per non-blank line, in the tool's order.
    ///
    /// Accepts output with or without identifiers, so a line that lacks a UUID
    /// still yields a runnable (by name) entry rather than being dropped.
    static func parseShortcutsListOutput(_ shortcutsListOutput: String) -> [AppleShortcutEntry] {
        var parsedEntries: [AppleShortcutEntry] = []
        for rawLine in shortcutsListOutput.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            if let identifierMatchRange = trimmedLine.range(of: trailingIdentifierPattern, options: .regularExpression) {
                let shortcutName = String(trimmedLine[..<identifierMatchRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                // Drop the " (" and ")" around the UUID.
                let identifierText = trimmedLine[identifierMatchRange]
                    .dropFirst(2)
                    .dropLast()
                guard !shortcutName.isEmpty else { continue }
                parsedEntries.append(AppleShortcutEntry(name: shortcutName, identifier: String(identifierText)))
            } else {
                parsedEntries.append(AppleShortcutEntry(name: trimmedLine, identifier: nil))
            }
        }
        return parsedEntries
    }
}

// MARK: - Command lines

nonisolated enum ShortcutsCommandLine {
    static let executablePath = "/usr/bin/shortcuts"

    static var executableURL: URL { URL(fileURLWithPath: executablePath) }

    /// `shortcuts list --show-identifiers`.
    static let listArguments: [String] = ["list", "--show-identifiers"]

    /// The argument array for one run.
    ///
    /// Options come first and the shortcut goes last, after `--`: the tool's
    /// argument parser would otherwise treat a name beginning with a dash as an
    /// option. Verified against the real tool: options-then-`--`-then-name is
    /// accepted.
    static func runArguments(
        shortcutNameOrIdentifier: String,
        inputFilePath: String?,
        outputFilePath: String?
    ) -> [String] {
        var runArguments: [String] = ["run"]
        if let inputFilePath {
            runArguments.append(contentsOf: ["--input-path", inputFilePath])
        }
        if let outputFilePath {
            runArguments.append(contentsOf: ["--output-path", outputFilePath])
        }
        runArguments.append("--")
        runArguments.append(shortcutNameOrIdentifier)
        return runArguments
    }
}

// MARK: - Running the process

/// What one invocation of the `shortcuts` tool produced.
nonisolated struct ShortcutsProcessResult: Sendable, Equatable {
    let terminationStatus: Int32
    let standardOutputText: String
    let standardErrorText: String
    let didTimeOut: Bool
    /// Set when the process could not be started at all.
    let launchFailureDescription: String?

    var succeeded: Bool {
        launchFailureDescription == nil && !didTimeOut && terminationStatus == 0
    }
}

nonisolated enum ShortcutsProcessRunner {

    /// Collects bytes read on one thread for another. `@unchecked Sendable`
    /// because the only access pattern is write-then-`DispatchGroup.wait`,
    /// which orders the write before the read.
    private final class ReadDataBox: @unchecked Sendable {
        var readData = Data()
    }

    /// Set by the timeout watchdog; read after the process has exited.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    }

    /// Runs `/usr/bin/shortcuts` with the given arguments, off the main actor.
    ///
    /// The blocking work (launch, draining both pipes, waiting for exit) runs on
    /// a global dispatch queue so neither the main actor nor a Swift
    /// concurrency thread is parked. Both pipes are drained concurrently: a
    /// process that fills one pipe's buffer while nobody reads it would
    /// otherwise block forever. A watchdog terminates the process at the
    /// timeout, and cancelling the calling task terminates it too — which is
    /// how `AgentTurnRunner`'s own per-tool timeout and "talking cancels it"
    /// reach the child process.
    static func runShortcutsTool(arguments: [String], timeoutSeconds: TimeInterval) async -> ShortcutsProcessResult {
        let shortcutsProcess = Process()
        shortcutsProcess.executableURL = ShortcutsCommandLine.executableURL
        shortcutsProcess.arguments = arguments
        shortcutsProcess.standardInput = FileHandle.nullDevice
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        shortcutsProcess.standardOutput = standardOutputPipe
        shortcutsProcess.standardError = standardErrorPipe

        let timeoutFlag = TimeoutFlag()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ShortcutsProcessResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try shortcutsProcess.run()
                    } catch {
                        continuation.resume(returning: ShortcutsProcessResult(
                            terminationStatus: -1,
                            standardOutputText: "",
                            standardErrorText: "",
                            didTimeOut: false,
                            launchFailureDescription: error.localizedDescription
                        ))
                        return
                    }

                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                        if shortcutsProcess.isRunning {
                            timeoutFlag.markTimedOut()
                            shortcutsProcess.terminate()
                        }
                    }

                    let standardErrorBox = ReadDataBox()
                    let standardErrorDrainGroup = DispatchGroup()
                    standardErrorDrainGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        standardErrorBox.readData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
                        standardErrorDrainGroup.leave()
                    }
                    let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
                    standardErrorDrainGroup.wait()
                    shortcutsProcess.waitUntilExit()

                    continuation.resume(returning: ShortcutsProcessResult(
                        terminationStatus: shortcutsProcess.terminationStatus,
                        standardOutputText: String(decoding: standardOutputData, as: UTF8.self),
                        standardErrorText: String(decoding: standardErrorBox.readData, as: UTF8.self),
                        didTimeOut: timeoutFlag.didTimeOut,
                        launchFailureDescription: nil
                    ))
                }
            }
        } onCancel: {
            if shortcutsProcess.isRunning {
                shortcutsProcess.terminate()
            }
        }
    }
}

// MARK: - Turning a run into text for the model

nonisolated enum ShortcutRunResultFormatter {
    /// The same cap `read_clipboard` uses: the result is pushed back into a
    /// context window shared with a screenshot.
    static let maximumOutputCharacters = 2000

    /// The plain-language result handed back to the model.
    ///
    /// Prefers the shortcut's output file (its real "output"), falls back to
    /// anything it printed, and reports a failure with the tool's own error
    /// line so the model can tell the user something specific.
    static func resultText(
        shortcutName: String,
        processResult: ShortcutsProcessResult,
        outputFileData: Data?,
        timeoutSeconds: TimeInterval
    ) -> String {
        if let launchFailureDescription = processResult.launchFailureDescription {
            return "couldn't start the Shortcuts tool: \(launchFailureDescription)"
        }
        if processResult.didTimeOut {
            return "the shortcut \"\(shortcutName)\" was still running after \(Int(timeoutSeconds)) seconds, so it was stopped. it may be waiting for input in a dialog."
        }
        guard processResult.terminationStatus == 0 else {
            let errorLine = processResult.standardErrorText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "Error: ", with: "")
            let explanation = errorLine.isEmpty ? "it exited with status \(processResult.terminationStatus)" : errorLine
            return "the shortcut \"\(shortcutName)\" failed: \(capped(explanation))"
        }

        if let outputFileData, !outputFileData.isEmpty {
            guard let outputText = String(data: outputFileData, encoding: .utf8) else {
                return "ran the shortcut \"\(shortcutName)\". it produced output that isn't text (\(outputFileData.count) bytes)."
            }
            let trimmedOutputText = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOutputText.isEmpty {
                return "ran the shortcut \"\(shortcutName)\". its output:\n\(capped(trimmedOutputText))"
            }
        }

        let printedText = processResult.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !printedText.isEmpty {
            return "ran the shortcut \"\(shortcutName)\". its output:\n\(capped(printedText))"
        }
        return "ran the shortcut \"\(shortcutName)\". it finished without any output."
    }

    static func capped(_ text: String) -> String {
        text.count > maximumOutputCharacters
            ? String(text.prefix(maximumOutputCharacters)) + "\n…(truncated, \(text.count) characters total)"
            : text
    }
}

// MARK: - The bridge

/// The app's view of the user's Shortcuts: a cached list for routing and the
/// dashboard, and the one place a shortcut is run from.
@MainActor
final class ShortcutsBridge: ObservableObject {
    static let shared = ShortcutsBridge()

    enum Availability: Equatable {
        /// Nothing has been read yet.
        case notChecked
        /// The Mac has the tool and it answered.
        case available
        /// No tool, or it failed to list — with a reason the dashboard shows.
        case unavailable(reason: String)
    }

    @Published private(set) var availability: Availability = .notChecked
    @Published private(set) var shortcuts: [AppleShortcutEntry] = []
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var isRefreshing = false

    /// How long a listing is trusted. The list changes only when the user
    /// edits Shortcuts, and a stale miss is repaired by the forced re-read in
    /// `runShortcut`, so a few minutes costs nothing in practice.
    static let listCacheTimeToLiveSeconds: TimeInterval = 5 * 60

    /// Listing is a local read and should be near-instant; this only guards
    /// against the tool hanging.
    static let listTimeoutSeconds: TimeInterval = 15

    /// The longest one shortcut may run. Generous because real shortcuts call
    /// the network or other apps; `AgentTurnRunner` budgets the confirmation
    /// window on top of this for `run_shortcut`.
    static let runTimeoutSeconds: TimeInterval = 120

    private var inFlightRefreshTask: Task<Void, Never>?

    private init() {}

    var cachedShortcutNames: [String] { shortcuts.map(\.name) }

    var isCacheStale: Bool {
        guard let lastRefreshDate else { return true }
        return Date().timeIntervalSince(lastRefreshDate) > Self.listCacheTimeToLiveSeconds
    }

    /// Re-reads the list only if the cache has expired.
    func refreshIfStale() async {
        guard isCacheStale else { return }
        await refresh()
    }

    /// Fire-and-forget variant for callers that must not wait — the per-turn
    /// router uses the cache as it is and lets this warm it for next time.
    func refreshInBackgroundIfStale() {
        guard isCacheStale, inFlightRefreshTask == nil else { return }
        Task { await refresh() }
    }

    /// Re-reads the list now. Concurrent callers share one read.
    func refresh() async {
        if let inFlightRefreshTask {
            await inFlightRefreshTask.value
            return
        }
        let refreshTask = Task { @MainActor in
            await self.performRefresh()
        }
        inFlightRefreshTask = refreshTask
        await refreshTask.value
        inFlightRefreshTask = nil
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        guard FileManager.default.isExecutableFile(atPath: ShortcutsCommandLine.executablePath) else {
            availability = .unavailable(reason: "The shortcuts command isn't on this Mac.")
            shortcuts = []
            lastRefreshDate = Date()
            return
        }

        let listResult = await ShortcutsProcessRunner.runShortcutsTool(
            arguments: ShortcutsCommandLine.listArguments,
            timeoutSeconds: Self.listTimeoutSeconds
        )
        lastRefreshDate = Date()

        guard listResult.succeeded else {
            let failureReason: String
            if let launchFailureDescription = listResult.launchFailureDescription {
                failureReason = launchFailureDescription
            } else if listResult.didTimeOut {
                failureReason = "Listing shortcuts timed out."
            } else {
                let errorLine = listResult.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
                failureReason = errorLine.isEmpty ? "Listing shortcuts failed." : errorLine
            }
            availability = .unavailable(reason: failureReason)
            shortcuts = []
            return
        }

        shortcuts = ShortcutsListParser.parseShortcutsListOutput(listResult.standardOutputText)
        availability = .available
    }

    /// Runs one shortcut by name, with optional text input, and returns the
    /// text handed back to the model.
    ///
    /// The name must match an existing shortcut (ignoring case and
    /// punctuation) — never a fuzzy guess. The confirmation card showed the
    /// user this name, and running a different shortcut than the one they
    /// approved would make that approval meaningless.
    func runShortcut(named requestedShortcutName: String, textInput: String?) async -> String {
        await refreshIfStale()
        var resolvedShortcut = ShortcutNameMatcher.resolveShortcut(named: requestedShortcutName, among: shortcuts)
        if resolvedShortcut == nil {
            // The user may have created it since the last listing.
            await refresh()
            resolvedShortcut = ShortcutNameMatcher.resolveShortcut(named: requestedShortcutName, among: shortcuts)
        }

        guard let resolvedShortcut else {
            if case .unavailable(let reason) = availability {
                return "shortcuts aren't available: \(reason)"
            }
            let similarShortcutNames = ShortcutNameMatcher.matchingShortcutNames(
                forRequest: requestedShortcutName,
                among: cachedShortcutNames,
                requiresInvocationCue: false
            )
            if similarShortcutNames.isEmpty {
                return "there is no shortcut called \"\(requestedShortcutName)\". use list_shortcuts to see the exact names."
            }
            let quotedSimilarNames = similarShortcutNames.map { "\"\($0)\"" }.joined(separator: ", ")
            return "there is no shortcut called \"\(requestedShortcutName)\". did you mean \(quotedSimilarNames)? ask the user before running a different one."
        }

        // A private folder per run, so concurrent runs never share files and
        // cleanup is one removal.
        let runDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-shortcut-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runDirectoryURL) }

        var inputFilePath: String?
        let outputFileURL = runDirectoryURL.appendingPathComponent("output")
        do {
            try FileManager.default.createDirectory(at: runDirectoryURL, withIntermediateDirectories: true)
            if let textInput, !textInput.isEmpty {
                let inputFileURL = runDirectoryURL.appendingPathComponent("input.txt")
                try textInput.write(to: inputFileURL, atomically: true, encoding: .utf8)
                inputFilePath = inputFileURL.path
            }
        } catch {
            return "couldn't prepare the shortcut's input: \(error.localizedDescription)"
        }

        let runArguments = ShortcutsCommandLine.runArguments(
            shortcutNameOrIdentifier: resolvedShortcut.identifier ?? resolvedShortcut.name,
            inputFilePath: inputFilePath,
            outputFilePath: outputFileURL.path
        )
        let runResult = await ShortcutsProcessRunner.runShortcutsTool(
            arguments: runArguments,
            timeoutSeconds: Self.runTimeoutSeconds
        )
        let outputFileData = try? Data(contentsOf: outputFileURL)

        return ShortcutRunResultFormatter.resultText(
            shortcutName: resolvedShortcut.name,
            processResult: runResult,
            outputFileData: outputFileData,
            timeoutSeconds: Self.runTimeoutSeconds
        )
    }
}
