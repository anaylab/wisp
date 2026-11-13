//
//  MailInboxReader.swift
//  leanring-buddy
//
//  Reads the user's mail from Mail.app on this Mac: recent inbox messages,
//  their bodies, who the user has written to lately, and the user's own
//  addresses. Every account the user added to Mail is covered with no sign-in
//  of Wisp's own, and nothing goes over the network.
//
//  The scripts run in `/usr/bin/osascript` off the main actor, fixed source on
//  stdin with plain arguments, so no text from an email can change what runs.
//  They answer as plain text with ASCII 30/31 separators, parsed by
//  `MailInboxScriptOutputParser`, and end with a TIMING line that is logged.
//
//  Speed: Mail answers per-message questions slowly on a large mailbox
//  (measured ~2s a message on a 36,000-message inbox), so the inbox script
//  asks for each field of the whole recent range in one Apple Event, and
//  bodies are read in a second step with a time budget. The engine keeps
//  bodies it already has, so later syncs only read new mail.
//

import AppKit
import Foundation
import os

nonisolated enum MailInboxReaderError: LocalizedError, Equatable {
    case automationNotAllowed
    case mailNotRunning
    case timedOut
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .automationNotAllowed:
            return "Wisp isn't allowed to read Mail. Allow it in System Settings → Privacy & Security → Automation → Mail."
        case .mailNotRunning:
            return "Mail isn't open, so the inbox wasn't checked. Open Mail or press Sync now."
        case .timedOut:
            return "Mail took too long to answer. Try Sync now in a moment."
        case .scriptFailed(let reason):
            return "Mail couldn't be read: \(reason)"
        }
    }
}

nonisolated enum MailInboxReader {

    static let mailBundleIdentifier = "com.apple.mail"
    /// Long enough for the first run's "Wisp wants to control Mail" prompt to be answered.
    static let scriptTimeoutSeconds: TimeInterval = 240
    /// The body script stops starting new bodies after this long (each can be
    /// a download); what it didn't reach is read on a later sync.
    static let bodyBudgetSeconds: TimeInterval = 90
    /// Bodies asked for per sync, newest people first.
    static let maximumBodiesPerSync = 80

    /// Shared helpers for the scripts below.
    private static let scriptHelpers = """
    on wispclean(sourceText)
        set cleanedText to sourceText as text
        set AppleScript's text item delimiters to {character id 30, character id 31}
        set textPieces to text items of cleanedText
        set AppleScript's text item delimiters to " "
        set cleanedText to textPieces as text
        set AppleScript's text item delimiters to ""
        return cleanedText
    end wispclean

    on wispclip(sourceText, maximumLength)
        if (length of sourceText) > maximumLength then return text 1 thru maximumLength of sourceText
        return sourceText
    end wispclip

    -- How many messages from the newest end of a date list are recent: walks
    -- from the newest, allowing 25 older ones in a row for loose ordering.
    on wisprecentspan(dateList, cutoffDate, maximumCount, newestAtEnd)
        set listCount to count of dateList
        set recentSpan to 0
        set olderInARow to 0
        repeat with stepIndex from 1 to listCount
            if newestAtEnd then
                set dateIndex to listCount - stepIndex + 1
            else
                set dateIndex to stepIndex
            end if
            if (item dateIndex of dateList) > cutoffDate then
                set recentSpan to stepIndex
                set olderInARow to 0
            else
                set olderInARow to olderInARow + 1
                if olderInARow > 25 then exit repeat
            end if
            if recentSpan ≥ maximumCount then exit repeat
        end repeat
        return recentSpan
    end wisprecentspan

    """

    /// The inbox script: every recent message's fields, one Apple Event per
    /// field. Asked as "of every message" and sliced here: measured on a
    /// 36,000-message inbox, Mail answers that form in ~2s but a 200-message
    /// range ("messages 1 thru 200") in ~95s, per field. No bodies. Each record also carries where
    /// the message is (mailbox number, index) for the body script.
    private static let inboxScriptSource = scriptHelpers + """
    on run argv
        set lookbackDays to (item 1 of argv) as integer
        set maximumCount to (item 2 of argv) as integer
        set recordSeparator to character id 30
        set fieldSeparator to character id 31
        set nowDate to current date
        set cutoffDate to nowDate - (lookbackDays * days)
        set outputText to ""
        set timingText to ""
        set totalCount to 0
        tell application "Mail"
            with timeout of 600 seconds
                set inboxMailboxes to mailboxes of inbox
                if (count of inboxMailboxes) is 0 then set inboxMailboxes to {inbox}
                set mailboxNumber to 0
                repeat with currentMailbox in inboxMailboxes
                    set mailboxNumber to mailboxNumber + 1
                    set accountText to ""
                    try
                        set accountText to name of account of currentMailbox
                    end try
                    log "mailbox " & mailboxNumber & " dates start " & ((current date) - nowDate)
                    set dateList to date received of every message of currentMailbox
                    set listCount to count of dateList
                    log "mailbox " & mailboxNumber & " has " & listCount & " dates at " & ((current date) - nowDate)
                    if listCount > 0 and totalCount < maximumCount then
                        set newestAtEnd to (item 1 of dateList) < (item listCount of dateList)
                        set recentSpan to my wisprecentspan(dateList, cutoffDate, maximumCount - totalCount, newestAtEnd)
                        log "recent span " & recentSpan & " newest at end " & newestAtEnd & " at " & ((current date) - nowDate)
                        if recentSpan > 0 then
                            if newestAtEnd then
                                set rangeStart to listCount - recentSpan + 1
                                set rangeEnd to listCount
                            else
                                set rangeStart to 1
                                set rangeEnd to recentSpan
                            end if
                            set allValues to message id of every message of currentMailbox
                            set idList to items rangeStart thru rangeEnd of allValues
                            log "ids at " & ((current date) - nowDate)
                            set allValues to sender of every message of currentMailbox
                            set senderList to items rangeStart thru rangeEnd of allValues
                            set allValues to subject of every message of currentMailbox
                            set subjectList to items rangeStart thru rangeEnd of allValues
                            set allValues to read status of every message of currentMailbox
                            set readList to items rangeStart thru rangeEnd of allValues
                            set allValues to was replied to of every message of currentMailbox
                            set repliedList to items rangeStart thru rangeEnd of allValues
                            log "fields at " & ((current date) - nowDate)
                            set toList to {}
                            try
                                set allValues to address of to recipients of every message of currentMailbox
                                set toList to items rangeStart thru rangeEnd of allValues
                            end try
                            log "to at " & ((current date) - nowDate)
                            set ccList to {}
                            try
                                set allValues to address of cc recipients of every message of currentMailbox
                                set ccList to items rangeStart thru rangeEnd of allValues
                            end try
                            log "cc at " & ((current date) - nowDate)
                            repeat with offsetIndex from 1 to (count of idList)
                                set messageIndex to rangeStart + offsetIndex - 1
                                set receivedDate to item messageIndex of dateList
                                if receivedDate > cutoffDate then
                                    set toText to ""
                                    if (count of toList) ≥ offsetIndex then
                                        repeat with currentAddress in (item offsetIndex of toList)
                                            set toText to toText & currentAddress & linefeed
                                        end repeat
                                    end if
                                    set ccText to ""
                                    if (count of ccList) ≥ offsetIndex then
                                        repeat with currentAddress in (item offsetIndex of ccList)
                                            set ccText to ccText & currentAddress & linefeed
                                        end repeat
                                    end if
                                    set secondsAgo to (nowDate - receivedDate) as integer
                                    set fieldList to {item offsetIndex of idList, accountText, item offsetIndex of senderList, toText, ccText, secondsAgo as text, item offsetIndex of subjectList, "", (item offsetIndex of readList) as text, (item offsetIndex of repliedList) as text, "false", "false", "", mailboxNumber as text, messageIndex as text}
                                    set recordText to ""
                                    repeat with fieldIndex from 1 to (count of fieldList)
                                        if fieldIndex > 1 then set recordText to recordText & fieldSeparator
                                        set recordText to recordText & my wispclean(item fieldIndex of fieldList)
                                    end repeat
                                    set outputText to outputText & recordText & recordSeparator
                                    set totalCount to totalCount + 1
                                end if
                            end repeat
                        end if
                    end if
                    set timingText to timingText & "mailbox " & mailboxNumber & " has " & listCount & "; "
                end repeat
            end timeout
        end tell
        set timingText to timingText & totalCount & " recent in " & ((current date) - nowDate) & "s"
        return outputText & "TIMING " & timingText
    end run
    """

    /// The quick check: only the recent messages' ids (one field, so about a
    /// seventh of the full read), to tell whether anything new arrived.
    private static let recentIDsScriptSource = scriptHelpers + """
    on run argv
        set lookbackDays to (item 1 of argv) as integer
        set maximumCount to (item 2 of argv) as integer
        set recordSeparator to character id 30
        set cutoffDate to (current date) - (lookbackDays * days)
        set outputText to ""
        set totalCount to 0
        tell application "Mail"
            with timeout of 600 seconds
                set inboxMailboxes to mailboxes of inbox
                if (count of inboxMailboxes) is 0 then set inboxMailboxes to {inbox}
                repeat with currentMailbox in inboxMailboxes
                    set dateList to date received of every message of currentMailbox
                    set listCount to count of dateList
                    if listCount > 0 and totalCount < maximumCount then
                        set newestAtEnd to (item 1 of dateList) < (item listCount of dateList)
                        set recentSpan to my wisprecentspan(dateList, cutoffDate, maximumCount - totalCount, newestAtEnd)
                        if recentSpan > 0 then
                            if newestAtEnd then
                                set rangeStart to listCount - recentSpan + 1
                                set rangeEnd to listCount
                            else
                                set rangeStart to 1
                                set rangeEnd to recentSpan
                            end if
                            set allValues to message id of every message of currentMailbox
                            repeat with offsetIndex from rangeStart to rangeEnd
                                if (item offsetIndex of dateList) > cutoffDate then
                                    set outputText to outputText & my wispclean(item offsetIndex of allValues) & recordSeparator
                                    set totalCount to totalCount + 1
                                end if
                            end repeat
                        end if
                    end if
                end repeat
            end timeout
        end tell
        return outputText
    end run
    """

    /// The body script: for each "mailbox<TAB>index<TAB>message id" argument,
    /// the start of the body and whether it has a List-Unsubscribe header,
    /// checked against the id so a shifted index never reads the wrong mail.
    private static let bodyScriptSource = scriptHelpers + """
    on run argv
        set excerptLength to (item 1 of argv) as integer
        set budgetSeconds to (item 2 of argv) as integer
        set recordSeparator to character id 30
        set fieldSeparator to character id 31
        set startDate to current date
        set outputText to ""
        set bodyCount to 0
        tell application "Mail"
            with timeout of 600 seconds
                set inboxMailboxes to mailboxes of inbox
                if (count of inboxMailboxes) is 0 then set inboxMailboxes to {inbox}
                repeat with argumentIndex from 3 to (count of argv)
                    if ((current date) - startDate) > budgetSeconds then exit repeat
                    set AppleScript's text item delimiters to tab
                    set locationParts to text items of (item argumentIndex of argv)
                    set AppleScript's text item delimiters to ""
                    try
                        set mailboxNumber to (item 1 of locationParts) as integer
                        set messageIndex to (item 2 of locationParts) as integer
                        set expectedID to item 3 of locationParts
                        set currentMessage to message messageIndex of (item mailboxNumber of inboxMailboxes)
                        if (message id of currentMessage) is expectedID then
                            set bodyText to ""
                            try
                                set bodyText to my wispclip(content of currentMessage, excerptLength)
                            end try
                            set listFlag to "false"
                            try
                                if (count of (headers of currentMessage whose name is "List-Unsubscribe")) > 0 then set listFlag to "true"
                            end try
                            set outputText to outputText & my wispclean(expectedID) & fieldSeparator & my wispclean(bodyText) & fieldSeparator & listFlag & recordSeparator
                            set bodyCount to bodyCount + 1
                        end if
                    end try
                end repeat
            end timeout
        end tell
        return outputText & "TIMING " & bodyCount & " bodies in " & ((current date) - startDate) & "s"
    end run
    """

    /// The signals script: the user's own addresses, then everyone they sent
    /// mail to in the last N days (bulk, like the inbox script), separated by
    /// ASCII 30.
    private static let signalsScriptSource = scriptHelpers + """
    on run argv
        set lookbackDays to (item 1 of argv) as integer
        set maximumCount to (item 2 of argv) as integer
        set cutoffDate to (current date) - (lookbackDays * days)
        set ownText to ""
        set sentText to ""
        tell application "Mail"
            with timeout of 600 seconds
                repeat with currentAccount in accounts
                    try
                        repeat with currentAddress in (email addresses of currentAccount)
                            set ownText to ownText & (currentAddress as text) & linefeed
                        end repeat
                    end try
                end repeat
                try
                    set sentMailboxes to mailboxes of sent mailbox
                    if (count of sentMailboxes) is 0 then set sentMailboxes to {sent mailbox}
                    repeat with sentBox in sentMailboxes
                        try
                            set dateList to date sent of every message of sentBox
                            set listCount to count of dateList
                            if listCount > 0 then
                                set newestAtEnd to (item 1 of dateList) < (item listCount of dateList)
                                set recentSpan to my wisprecentspan(dateList, cutoffDate, maximumCount, newestAtEnd)
                                if recentSpan > 0 then
                                    if newestAtEnd then
                                        set rangeStart to listCount - recentSpan + 1
                                        set rangeEnd to listCount
                                    else
                                        set rangeStart to 1
                                        set rangeEnd to recentSpan
                                    end if
                                    -- The user's own addresses, as the sender of their sent mail
                                    -- (an account's "email addresses" can come back empty).
                                    try
                                        set allValues to sender of every message of sentBox
                                        repeat with senderText in (items rangeStart thru rangeEnd of allValues)
                                            set ownText to ownText & senderText & linefeed
                                        end repeat
                                    end try
                                    set allValues to address of to recipients of every message of sentBox
                                    repeat with recipientAddresses in (items rangeStart thru rangeEnd of allValues)
                                        repeat with currentAddress in recipientAddresses
                                            set sentText to sentText & currentAddress & linefeed
                                        end repeat
                                    end repeat
                                end if
                            end if
                        end try
                    end repeat
                end try
            end timeout
        end tell
        return ownText & (character id 30) & sentText
    end run
    """

    /// One cheap call, so a missing permission (which blocks) is told apart
    /// from a slow inbox read.
    private static let probeScriptSource = """
    tell application "Mail" to return (count of accounts) as text
    """

    /// How many accounts Mail answers with; throws when it doesn't answer.
    static func probe(timeoutSeconds: TimeInterval) async throws -> Int {
        let output = try await runScript(probeScriptSource, arguments: [], timeoutSeconds: timeoutSeconds)
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static var isMailRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleIdentifier).isEmpty
    }

    /// Recent inbox messages, without bodies (`isBodyRead` false). With
    /// `launchesMail` false and Mail closed, it throws `mailNotRunning` instead
    /// of opening Mail behind the user's back.
    static func readInboxMessages(launchesMail: Bool, now: Date = Date()) async throws -> [MailInboxMessage] {
        if !launchesMail && !isMailRunning { throw MailInboxReaderError.mailNotRunning }
        let probeStart = Date()
        let accountCount = try await probe(timeoutSeconds: 90)
        mailInboxLog.notice("Mail answered in \(Date().timeIntervalSince(probeStart), privacy: .public)s with \(accountCount, privacy: .public) accounts")
        let output = try await runScript(inboxScriptSource, arguments: [
            String(MailInboxLimits.lookbackDays),
            String(MailInboxLimits.maximumMessagesRead),
        ])
        return MailInboxScriptOutputParser.parseInboxMessages(loggingTiming(of: output, step: "inbox"), now: now)
    }

    /// The recent messages' ids only (the quick check).
    static func readRecentMessageIDs(launchesMail: Bool) async throws -> Set<String> {
        if !launchesMail && !isMailRunning { throw MailInboxReaderError.mailNotRunning }
        let started = Date()
        let output = try await runScript(recentIDsScriptSource, arguments: [
            String(MailInboxLimits.lookbackDays),
            String(MailInboxLimits.maximumMessagesRead),
        ])
        let messageIDs = Set(output
            .split(separator: MailInboxScriptOutputParser.recordSeparator)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \n\t")) }
            .filter { !$0.isEmpty })
        mailInboxLog.notice("quick check: \(messageIDs.count, privacy: .public) recent ids in \(Date().timeIntervalSince(started), privacy: .public)s")
        return messageIDs
    }

    /// Bodies for messages the inbox script listed, in the order given. Returns
    /// what it reached within `bodyBudgetSeconds`, keyed by message id.
    static func readBodies(of messages: [MailInboxMessage]) async throws -> [String: MailInboxScriptOutputParser.BodyRecord] {
        guard !messages.isEmpty else { return [:] }
        let locationArguments = messages.prefix(maximumBodiesPerSync).map { message in
            "\(message.mailboxNumber)\t\(message.messageIndex)\t\(message.messageID)"
        }
        let output = try await runScript(bodyScriptSource, arguments: [
            String(MailInboxLimits.bodyExcerptCharacterCount),
            String(Int(bodyBudgetSeconds)),
        ] + locationArguments)
        return MailInboxScriptOutputParser.parseBodies(loggingTiming(of: output, step: "bodies"))
    }

    /// The user's own addresses and the people they wrote to lately.
    static func readUserAddressSignals() async throws -> (ownAddresses: Set<String>, addressesUserWroteTo: Set<String>) {
        let output = try await runScript(signalsScriptSource, arguments: [
            String(MailInboxLimits.sentLookbackDays),
            String(MailInboxLimits.maximumSentMessagesRead),
        ])
        let parts = output.split(separator: MailInboxScriptOutputParser.recordSeparator, omittingEmptySubsequences: false)
        func addresses(_ part: Substring?) -> Set<String> {
            guard let part else { return [] }
            return Set(MailInboxScriptOutputParser.addressList(String(part)))
        }
        return (addresses(parts.first), addresses(parts.count > 1 ? parts[1] : nil))
    }

    /// Shows the message in Mail (`message:` links are Mail's own).
    @MainActor
    static func openInMail(messageID: String) {
        let encodedID = "<\(messageID)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? messageID
        guard let messageURL = URL(string: "message://\(encodedID)") else { return }
        NSWorkspace.shared.open(messageURL)
    }

    /// Logs the script's closing TIMING line (counts and seconds, no mail
    /// text) and returns the output without it.
    private static func loggingTiming(of output: String, step: String) -> String {
        guard let timingRange = output.range(of: "TIMING ", options: .backwards) else { return output }
        let timingText = String(output[timingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        mailInboxLog.notice("Mail \(step, privacy: .public): \(timingText, privacy: .public)")
        return String(output[..<timingRange.lowerBound])
    }

    // MARK: - Running osascript

    private static func runScript(_ scriptSource: String, arguments: [String], timeoutSeconds: TimeInterval = scriptTimeoutSeconds) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try runScriptBlocking(scriptSource, arguments: arguments, timeoutSeconds: timeoutSeconds) })
            }
        }
    }

    private static func runScriptBlocking(_ scriptSource: String, arguments: [String], timeoutSeconds: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // "-" reads the script from stdin; the rest arrive as `argv`.
        process.arguments = ["-"] + arguments
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Both pipes are drained while the script runs: a large inbox fills
        // the pipe buffer, and a blocked writer would never exit.
        let collectedOutput = LockedDataBuffer()
        let collectedError = LockedDataBuffer()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in collectedOutput.append(handle.availableData) }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in collectedError.append(handle.availableData) }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw MailInboxReaderError.scriptFailed(error.localizedDescription)
        }
        inputPipe.fileHandleForWriting.write(Data(scriptSource.utf8))
        try? inputPipe.fileHandleForWriting.close()

        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            // osascript waiting on an Apple Event ignores SIGTERM and would keep
            // Mail busy for the next sync, so it gets a hard kill too.
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            // The script's `log` lines (step names and seconds, no mail text)
            // say where it was when it ran out of time.
            let progressLines = String(decoding: collectedError.data, as: UTF8.self)
                .split(separator: "\n").suffix(4).joined(separator: " | ")
            mailInboxLog.error("script timed out after \(timeoutSeconds, privacy: .public)s; last steps: \(progressLines, privacy: .public)")
            throw MailInboxReaderError.timedOut
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        // Whatever arrived after the last handler call.
        if let remainingOutput = try? outputPipe.fileHandleForReading.readToEnd() { collectedOutput.append(remainingOutput) }
        if let remainingError = try? errorPipe.fileHandleForReading.readToEnd() { collectedError.append(remainingError) }
        let output = String(decoding: collectedOutput.data, as: UTF8.self)
        let errorText = String(decoding: collectedError.data, as: UTF8.self)
        if process.terminationStatus == 0, !errorText.isEmpty {
            // Step names and seconds from the script's `log` lines (no mail text).
            mailInboxLog.notice("script steps: \(errorText.split(separator: "\n").joined(separator: " | "), privacy: .public)")
        }

        guard process.terminationStatus == 0 else {
            if errorText.contains("-1743") { throw MailInboxReaderError.automationNotAllowed }
            if errorText.contains("-600") { throw MailInboxReaderError.mailNotRunning }
            let reason = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MailInboxReaderError.scriptFailed(reason.isEmpty ? "exit \(process.terminationStatus)" : String(reason.prefix(200)))
        }
        return output
    }
}

/// Bytes appended from the pipes' reader threads.
nonisolated private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()

    func append(_ chunk: Data) {
        lock.lock(); collectedData.append(chunk); lock.unlock()
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return collectedData
    }
}
