//
//  PersonalContextSources.swift
//  leanring-buddy
//
//  The places personal context searches, one type per source, all on this
//  Mac. Calendar, Reminders and Contacts are searched by their providers
//  (`CalendarDataProvider`, `RemindersDataProvider`, `ContactsDirectory`);
//  this file adds the rest:
//
//  • Files — Spotlight's index (`NSMetadataQuery`), limited to Documents,
//    Desktop, Downloads and iCloud Drive, so app support files and code don't
//    drown the user's own documents.
//  • Mail and Notes — AppleScript, with the search word passed as a handler
//    parameter (never spliced into script source), only while the app is
//    already open: a question never launches Mail or Notes.
//  • Messages — the history database, read-only, opt-in, and only readable
//    once the user grants Wisp Full Disk Access.
//
//  The rule every source keeps: searching never asks for a permission. A turn
//  is not the moment for a system prompt, so each source reports whether it
//  can be searched (`PersonalContextSourceAvailability`) and is skipped when it
//  can't; Settings → Connections → Your Data is where access is granted.
//

import AppKit
import Carbon
import Contacts
import EventKit
import Foundation
import SQLite3

/// Whether a source can be searched right now without asking anything.
enum PersonalContextSourceAvailability: Equatable, Sendable {
    case available
    /// Never asked; Settings can ask.
    case needsPermission
    /// Refused in System Settings.
    case denied
    /// Mail or Notes is closed — searched only while open.
    case appNotRunning
    /// Messages needs Full Disk Access, which only System Settings can grant.
    case needsFullDiskAccess

    var isSearchable: Bool { self == .available }

    /// The status line in Settings.
    func statusText(for sourceKind: PersonalContextSourceKind) -> String {
        switch self {
        case .available: return "Searched on this Mac"
        case .needsPermission where sourceKind == .files: return "Needs access to Documents, Desktop, Downloads and iCloud Drive"
        case .needsPermission: return "Needs your permission"
        case .denied: return "Turned off in System Settings"
        case .appNotRunning: return "Searched while \(sourceKind.displayName) is open"
        case .needsFullDiskAccess: return "Needs Full Disk Access"
        }
    }
}

// MARK: - Calendar, Reminders, Contacts (EventKit and Contacts permissions)

enum PersonalContextSystemPermissions {

    static func availability(for sourceKind: PersonalContextSourceKind) -> PersonalContextSourceAvailability {
        switch sourceKind {
        case .calendar: return eventKitAvailability(for: .event)
        case .reminders: return eventKitAvailability(for: .reminder)
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .available
            case .notDetermined: return .needsPermission
            default: return .denied
            }
        case .files: return SpotlightFileSearch.hasUserSetUpFolderAccess ? .available : .needsPermission
        case .mail: return ScriptedAppPermission.availability(ofApplicationWithBundleIdentifier: MailSearchBridge.mailBundleIdentifier)
        case .notes: return ScriptedAppPermission.availability(ofApplicationWithBundleIdentifier: NotesSearchBridge.notesBundleIdentifier)
        case .messages: return MessagesHistoryReader.isDatabaseReadable ? .available : .needsFullDiskAccess
        }
    }

    private static func eventKitAvailability(for entityType: EKEntityType) -> PersonalContextSourceAvailability {
        switch EKEventStore.authorizationStatus(for: entityType) {
        case .fullAccess: return .available
        case .notDetermined: return .needsPermission
        default: return .denied
        }
    }
}

// MARK: - Scripted apps (Mail, Notes)

/// Whether Wisp may send Apple Events to an app, checked without prompting
/// (`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded` false).
enum ScriptedAppPermission {

    static func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func availability(ofApplicationWithBundleIdentifier bundleIdentifier: String) -> PersonalContextSourceAvailability {
        guard isRunning(bundleIdentifier: bundleIdentifier) else { return .appNotRunning }
        switch automationPermissionStatus(bundleIdentifier: bundleIdentifier, askUserIfNeeded: false) {
        case noErr: return .available
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsPermission
        default: return .denied
        }
    }

    /// Asks (shows the system prompt) — only ever from Settings. Blocks
    /// until the user answers, so it runs off the main thread.
    static func requestAutomationPermission(bundleIdentifier: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            automationPermissionStatus(bundleIdentifier: bundleIdentifier, askUserIfNeeded: true) == noErr
        }.value
    }

    nonisolated private static func automationPermissionStatus(bundleIdentifier: String, askUserIfNeeded: Bool) -> OSStatus {
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let targetAddress = targetDescriptor.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(targetAddress, typeWildCard, typeWildCard, askUserIfNeeded)
    }
}

/// Runs one fixed AppleScript's handlers on a serial queue, with the
/// handler's arguments as Apple Event parameters. The same pattern as
/// `AppleNotesScriptBridge`: NSAppleScript blocks while the app answers and
/// mustn't run concurrently with itself.
final class ScriptHandlerRunner: @unchecked Sendable {
    enum RunnerError: Error {
        case automationNotAllowed
        case timedOut
        case scriptFailed(String)
    }

    private let scriptSource: String
    private let scriptQueue: DispatchQueue
    /// Compiled once, on the script queue, the first time it's needed.
    private var compiledScript: NSAppleScript?

    init(scriptSource: String, queueLabel: String) {
        self.scriptSource = scriptSource
        self.scriptQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    func callHandler(named handlerName: String, parameters: [String]) async throws -> NSAppleEventDescriptor {
        try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                do {
                    continuation.resume(returning: try self.callHandlerOnScriptQueue(named: handlerName, parameters: parameters))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func callHandlerOnScriptQueue(named handlerName: String, parameters: [String]) throws -> NSAppleEventDescriptor {
        if compiledScript == nil {
            guard let script = NSAppleScript(source: scriptSource) else { throw RunnerError.scriptFailed("script could not be prepared") }
            var compileErrorInfo: NSDictionary?
            guard script.compileAndReturnError(&compileErrorInfo) else {
                throw RunnerError.scriptFailed((compileErrorInfo?[NSAppleScript.errorMessage] as? String) ?? "compile error")
            }
            compiledScript = script
        }
        guard let compiledScript else { throw RunnerError.scriptFailed("script missing") }

        let handlerParameters = NSAppleEventDescriptor.list()
        for (parameterIndex, parameterValue) in parameters.enumerated() {
            handlerParameters.insert(NSAppleEventDescriptor(string: parameterValue), at: parameterIndex + 1)
        }
        let handlerCallEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        handlerCallEvent.setDescriptor(NSAppleEventDescriptor(string: handlerName), forKeyword: AEKeyword(keyASSubroutineName))
        handlerCallEvent.setDescriptor(handlerParameters, forKeyword: AEKeyword(keyDirectObject))

        var scriptErrorInfo: NSDictionary?
        let scriptResult: NSAppleEventDescriptor? = compiledScript.executeAppleEvent(handlerCallEvent, error: &scriptErrorInfo)
        if let scriptErrorInfo {
            let scriptErrorNumber = (scriptErrorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if scriptErrorNumber == -1743 { throw RunnerError.automationNotAllowed }
            if scriptErrorNumber == -1712 { throw RunnerError.timedOut }
            throw RunnerError.scriptFailed("\((scriptErrorInfo[NSAppleScript.errorMessage] as? String) ?? "error") (\(scriptErrorNumber))")
        }
        return scriptResult ?? NSAppleEventDescriptor.list()
    }
}

/// Reads a list of rows (each a list of fields) from a handler's reply.
private func rowsOfFields(from replyDescriptor: NSAppleEventDescriptor) -> [[NSAppleEventDescriptor]] {
    guard replyDescriptor.numberOfItems > 0 else { return [] }
    return (1...replyDescriptor.numberOfItems).compactMap { rowIndex in
        guard let rowDescriptor = replyDescriptor.atIndex(rowIndex), rowDescriptor.numberOfItems > 0 else { return nil }
        return (1...rowDescriptor.numberOfItems).compactMap { rowDescriptor.atIndex($0) }
    }
}

private func shortDateText(_ date: Date) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.setLocalizedDateFormatFromTemplate("MMMd")
    return dateFormatter.string(from: date)
}

/// Mail's inbox, searched by subject and sender, with the opening of the
/// best few messages as excerpts.
enum MailSearchBridge {
    static let mailBundleIdentifier = "com.apple.mail"

    /// Mail answers `whose` searches on a large inbox in a second or two;
    /// past this the search gives up rather than hold the turn.
    private static let scriptSource = """
    on searchwispmail(searchTerm, maximumCount)
        with timeout of 4 seconds
            tell application "Mail"
                set matchingMessages to (every message of inbox whose subject contains searchTerm or sender contains searchTerm)
                if (count of matchingMessages) > (maximumCount as integer) then set matchingMessages to items 1 thru (maximumCount as integer) of matchingMessages
                set resultRows to {}
                repeat with matchingMessage in matchingMessages
                    set end of resultRows to {(id of matchingMessage) as text, subject of matchingMessage, sender of matchingMessage, date received of matchingMessage}
                end repeat
                return resultRows
            end tell
        end timeout
    end searchwispmail

    on wispmailexcerpt(messageIdentifier)
        with timeout of 3 seconds
            tell application "Mail"
                set matchingMessages to (every message of inbox whose id is (messageIdentifier as integer))
                if (count of matchingMessages) is 0 then return ""
                set messageContent to content of item 1 of matchingMessages
                if (length of messageContent) > 600 then set messageContent to text 1 thru 600 of messageContent
                return messageContent
            end tell
        end timeout
    end wispmailexcerpt
    """

    private static let scriptRunner = ScriptHandlerRunner(scriptSource: scriptSource, queueLabel: "wisp.personal-context.mail")

    static func personalContextHits(matchingAnyOf searchTerms: [String], maximumHitCount: Int) async -> [PersonalContextHit] {
        var hitsByMessageID: [String: PersonalContextHit] = [:]
        // The two most specific words: each is one round trip to Mail.
        for searchTerm in searchTerms.prefix(2) {
            guard let replyDescriptor = try? await scriptRunner.callHandler(named: "searchwispmail", parameters: [searchTerm, "25"]) else { continue }
            for rowFields in rowsOfFields(from: replyDescriptor) where rowFields.count == 4 {
                guard let messageID = rowFields[0].stringValue else { continue }
                let receivedDate = rowFields[3].dateValue
                let senderText = rowFields[2].stringValue ?? ""
                hitsByMessageID[messageID] = PersonalContextHit(
                    id: "mail:\(messageID)",
                    sourceKind: .mail,
                    title: rowFields[1].stringValue ?? "(no subject)",
                    detail: ["from \(senderText)", receivedDate.map(shortDateText) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                    excerpt: nil,
                    relevantDate: receivedDate
                )
            }
        }
        // Newest first, then the opening of the top two for the answer itself
        // ("when is the flight" is in the body, not the subject).
        var newestHits = hitsByMessageID.values
            .sorted { ($0.relevantDate ?? .distantPast) > ($1.relevantDate ?? .distantPast) }
            .prefix(maximumHitCount)
            .map { $0 }
        for hitIndex in newestHits.indices.prefix(2) {
            let messageID = String(newestHits[hitIndex].id.dropFirst("mail:".count))
            guard let excerptDescriptor = try? await scriptRunner.callHandler(named: "wispmailexcerpt", parameters: [messageID]),
                  let excerptText = excerptDescriptor.stringValue, !excerptText.isEmpty else { continue }
            let existingHit = newestHits[hitIndex]
            newestHits[hitIndex] = PersonalContextHit(
                id: existingHit.id,
                sourceKind: existingHit.sourceKind,
                title: existingHit.title,
                detail: existingHit.detail,
                excerpt: excerptText,
                relevantDate: existingHit.relevantDate
            )
        }
        return newestHits
    }
}

/// Apple Notes, searched by title and text.
enum NotesSearchBridge {
    static let notesBundleIdentifier = "com.apple.Notes"

    private static let scriptSource = """
    on searchwispnotes(searchTerm, maximumCount, searchesText)
        with timeout of 4 seconds
            tell application "Notes"
                if searchesText is "yes" then
                    set matchingNotes to (every note whose name contains searchTerm or plaintext contains searchTerm)
                else
                    set matchingNotes to (every note whose name contains searchTerm)
                end if
                set resultRows to {}
                set rowCount to 0
                repeat with matchingNote in matchingNotes
                    if rowCount ≥ (maximumCount as integer) then exit repeat
                    if name of container of matchingNote is not "Recently Deleted" and not (password protected of matchingNote) then
                        set noteText to plaintext of matchingNote
                        if (length of noteText) > 400 then set noteText to text 1 thru 400 of noteText
                        set end of resultRows to {(id of matchingNote) as text, name of matchingNote, modification date of matchingNote, noteText}
                        set rowCount to rowCount + 1
                    end if
                end repeat
                return resultRows
            end tell
        end timeout
    end searchwispnotes
    """

    private static let scriptRunner = ScriptHandlerRunner(scriptSource: scriptSource, queueLabel: "wisp.personal-context.notes")

    static func personalContextHits(matchingAnyOf searchTerms: [String], maximumHitCount: Int) async -> [PersonalContextHit] {
        var hitsByNoteID: [String: PersonalContextHit] = [:]
        for searchTerm in searchTerms.prefix(2) {
            // Searching note text is slow on a large library; when it times
            // out, titles alone still answer quickly.
            var replyDescriptor = try? await scriptRunner.callHandler(named: "searchwispnotes", parameters: [searchTerm, "8", "yes"])
            if replyDescriptor == nil {
                replyDescriptor = try? await scriptRunner.callHandler(named: "searchwispnotes", parameters: [searchTerm, "8", "no"])
            }
            guard let replyDescriptor else { continue }
            for rowFields in rowsOfFields(from: replyDescriptor) where rowFields.count == 4 {
                guard let noteID = rowFields[0].stringValue else { continue }
                let modifiedDate = rowFields[2].dateValue
                let noteName = rowFields[1].stringValue ?? "Untitled"
                var noteText = rowFields[3].stringValue ?? ""
                // A note's plaintext starts with its title; don't repeat it.
                if noteText.hasPrefix(noteName) { noteText = String(noteText.dropFirst(noteName.count)) }
                let trimmedNoteText = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                hitsByNoteID[noteID] = PersonalContextHit(
                    id: "notes:\(noteID)",
                    sourceKind: .notes,
                    title: noteName,
                    detail: modifiedDate.map { "edited \(shortDateText($0))" } ?? "",
                    excerpt: trimmedNoteText.isEmpty ? nil : trimmedNoteText,
                    relevantDate: modifiedDate
                )
            }
        }
        return Array(hitsByNoteID.values.prefix(maximumHitCount * 2))
    }
}

// MARK: - Files (Spotlight)

/// The user's own documents, found through Spotlight's index.
///
/// Documents, Desktop, Downloads and iCloud Drive are privacy-protected: the
/// first time an app reads one, macOS asks. A Spotlight query scoped to them
/// raised that prompt mid-search, so file search stays off until the user
/// presses Allow in Settings → Your Data — `requestFolderAccess` touches each
/// folder then, so the prompts appear when the user expects them, and later
/// searches never prompt (an answered prompt isn't asked again). There's no
/// API to read a folder's permission without risking the prompt, so the
/// setup is remembered instead.
@MainActor
enum SpotlightFileSearch {

    private static let folderAccessSetUpDefaultsKey = "personalContext.filesFolderAccessSetUp"

    nonisolated static var hasUserSetUpFolderAccess: Bool {
        UserDefaults.standard.bool(forKey: folderAccessSetUpDefaultsKey)
    }

    /// Reads each folder's listing once, which shows macOS's prompt for any
    /// not yet answered. Only from Settings' Allow button.
    static func requestFolderAccess() async {
        let folderPaths = searchFolderURLs.map(\.path)
        await Task.detached(priority: .userInitiated) {
            for folderPath in folderPaths {
                _ = try? FileManager.default.contentsOfDirectory(atPath: folderPath)
            }
        }.value
        UserDefaults.standard.set(true, forKey: folderAccessSetUpDefaultsKey)
    }

    /// The folders searched — where people keep their own documents.
    static var searchFolderURLs: [URL] {
        let homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let candidateFolderURLs = [
            homeDirectoryURL.appendingPathComponent("Documents"),
            homeDirectoryURL.appendingPathComponent("Desktop"),
            homeDirectoryURL.appendingPathComponent("Downloads"),
            homeDirectoryURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
        ]
        return candidateFolderURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Files whose name — or text, for any word longer than three letters —
    /// matches a search term, most recently used first.
    static func personalContextHits(
        matchingAnyOf searchTerms: [String],
        maximumHitCount: Int,
        timeLimitSeconds: Double
    ) async -> [PersonalContextHit] {
        let searchableTerms = searchTerms.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        guard !searchableTerms.isEmpty, !searchFolderURLs.isEmpty else { return [] }
        let termClauses = searchableTerms.map { searchTerm in
            searchTerm.count > 3
                ? "(kMDItemDisplayName == \"*\(searchTerm)*\"cd || kMDItemTextContent == \"\(searchTerm)*\"cdw)"
                : "(kMDItemDisplayName == \"*\(searchTerm)*\"cd)"
        }
        guard let searchPredicate = NSPredicate(fromMetadataQueryString: termClauses.joined(separator: " || ")) else { return [] }

        let metadataQuery = NSMetadataQuery()
        metadataQuery.predicate = searchPredicate
        metadataQuery.searchScopes = searchFolderURLs
        metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]

        await waitForGathering(of: metadataQuery, timeLimitSeconds: timeLimitSeconds)
        metadataQuery.disableUpdates()
        defer { metadataQuery.stop() }

        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let resultCount = min(metadataQuery.resultCount, maximumHitCount * 4)
        guard resultCount > 0 else { return [] }
        return (0..<resultCount).compactMap { resultIndex -> PersonalContextHit? in
            guard let metadataItem = metadataQuery.result(at: resultIndex) as? NSMetadataItem,
                  let filePath = metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let displayName = (metadataItem.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? (filePath as NSString).lastPathComponent
            let lastUsedDate = (metadataItem.value(forAttribute: "kMDItemLastUsedDate") as? Date)
                ?? (metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)
            var folderPath = (filePath as NSString).deletingLastPathComponent
            if folderPath.hasPrefix(homeDirectoryPath) { folderPath = String(folderPath.dropFirst(homeDirectoryPath.count + 1)) }
            folderPath = folderPath.replacingOccurrences(of: "Library/Mobile Documents/com~apple~CloudDocs", with: "iCloud Drive")
            let detailParts = [folderPath, lastUsedDate.map { "used \(shortDateText($0))" } ?? ""].filter { !$0.isEmpty }
            return PersonalContextHit(
                id: "files:\(filePath)",
                sourceKind: .files,
                title: displayName,
                detail: detailParts.joined(separator: " · "),
                excerpt: nil,
                relevantDate: lastUsedDate
            )
        }
    }

    /// Starts the query and returns when Spotlight has gathered its results
    /// or the time limit passes, whichever is first.
    private static func waitForGathering(of metadataQuery: NSMetadataQuery, timeLimitSeconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var hasResumed = false
            var gatheringObserver: NSObjectProtocol?
            let resumeOnce = {
                guard !hasResumed else { return }
                hasResumed = true
                if let gatheringObserver { NotificationCenter.default.removeObserver(gatheringObserver) }
                continuation.resume()
            }
            gatheringObserver = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { resumeOnce() }
            }
            if !metadataQuery.start() { resumeOnce(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeLimitSeconds) {
                MainActor.assumeIsolated { resumeOnce() }
            }
        }
    }
}

// MARK: - Messages (opt-in, Full Disk Access)

/// The Messages history database, read-only. Wisp can open it only after
/// the user grants Full Disk Access in System Settings, and only searches it
/// when the user has switched Messages on in Settings.
enum MessagesHistoryReader {

    nonisolated static var databasePath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    }

    /// Whether the database can be opened — false without Full Disk Access,
    /// which is how macOS protects it.
    nonisolated static var isDatabaseReadable: Bool {
        guard let databaseFileHandle = FileHandle(forReadingAtPath: databasePath) else { return false }
        try? databaseFileHandle.close()
        return true
    }

    /// Messages from the last `recentMessageLimit` whose text or sender's name
    /// contains a term, newest first. `displayNamesByNormalizedHandle` turns a
    /// number into the contact's name when Contacts allows it.
    nonisolated static func personalContextHits(
        matchingAnyOf searchTerms: [String],
        displayNamesByNormalizedHandle: [String: String],
        maximumHitCount: Int,
        recentMessageLimit: Int = 5000
    ) -> [PersonalContextHit] {
        guard !searchTerms.isEmpty else { return [] }
        var databaseConnection: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &databaseConnection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(databaseConnection)
            return []
        }
        defer { sqlite3_close(databaseConnection) }
        sqlite3_busy_timeout(databaseConnection, 500)

        // Tapbacks and other reactions have a non-zero associated type.
        let recentMessagesSQL = """
            SELECT message.ROWID, message.text, message.attributedBody, message.date, message.is_from_me, handle.id
            FROM message LEFT JOIN handle ON message.handle_id = handle.ROWID
            WHERE message.associated_message_type = 0
            ORDER BY message.date DESC
            LIMIT ?
            """
        var preparedStatement: OpaquePointer?
        guard sqlite3_prepare_v2(databaseConnection, recentMessagesSQL, -1, &preparedStatement, nil) == SQLITE_OK else {
            sqlite3_finalize(preparedStatement)
            return []
        }
        defer { sqlite3_finalize(preparedStatement) }
        sqlite3_bind_int(preparedStatement, 1, Int32(recentMessageLimit))

        var hits: [PersonalContextHit] = []
        while sqlite3_step(preparedStatement) == SQLITE_ROW, hits.count < maximumHitCount * 3 {
            let messageRowID = sqlite3_column_int64(preparedStatement, 0)
            var messageText = sqlite3_column_text(preparedStatement, 1).map { String(cString: $0) } ?? ""
            if messageText.isEmpty, let attributedBodyBytes = sqlite3_column_blob(preparedStatement, 2) {
                let attributedBodyLength = Int(sqlite3_column_bytes(preparedStatement, 2))
                let attributedBodyData = Data(bytes: attributedBodyBytes, count: attributedBodyLength)
                messageText = MessagesHistoryDecoding.plainText(fromAttributedBody: attributedBodyData) ?? ""
            }
            guard !messageText.isEmpty else { continue }

            let isFromUser = sqlite3_column_int(preparedStatement, 4) == 1
            let rawHandle = sqlite3_column_text(preparedStatement, 5).map { String(cString: $0) } ?? ""
            let otherPersonName = displayNamesByNormalizedHandle[MessagesHistoryDecoding.normalizedHandle(rawHandle)]
                ?? (rawHandle.isEmpty ? "a group" : rawHandle)
            guard PersonalContextTextMatching.text("\(messageText) \(otherPersonName)", containsAnyOf: searchTerms) else { continue }

            let sentDate = MessagesHistoryDecoding.date(fromMessagesTimestamp: sqlite3_column_int64(preparedStatement, 3))
            hits.append(PersonalContextHit(
                id: "messages:\(messageRowID)",
                sourceKind: .messages,
                title: messageText,
                detail: [isFromUser ? "you to \(otherPersonName)" : "from \(otherPersonName)", shortDateText(sentDate)]
                    .joined(separator: " · "),
                excerpt: nil,
                relevantDate: sentDate
            ))
        }
        return hits
    }
}
