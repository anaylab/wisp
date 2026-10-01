//
//  BrainNotesImportAppleNotes.swift
//  leanring-buddy
//
//  Reads Apple Notes through AppleScript for `BrainNotesImporter`. Two steps:
//  a cheap listing (id, name, modification date, locked, in Recently Deleted —
//  bulk property reads, one Apple Event each) and then bodies only for the
//  notes that are new or changed, fetched by id.
//
//  The script source is fixed. Note ids go in as handler parameters (Apple
//  Event descriptors), never spliced into source, so nothing a note contains
//  can become script. Runs on its own serial queue: NSAppleScript blocks
//  while Notes answers, which can take seconds for a large library, and must
//  not run concurrently with itself.
//

import Carbon
import Foundation

nonisolated enum AppleNotesScriptBridge {
    enum BridgeError: LocalizedError, Equatable {
        /// -1743: the user hasn't allowed Wisp to control Notes.
        case automationNotAllowed
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .automationNotAllowed:
                return "Wisp isn't allowed to read Apple Notes — allow it under System Settings → Privacy & Security → Automation → Notes, then import again."
            case .scriptFailed(let reason):
                return "Apple Notes couldn't be read: \(reason)"
            }
        }
    }

    private static let scriptQueue = DispatchQueue(label: "wisp.brain.apple-notes-script", qos: .utility)

    /// "Recently Deleted" is looked up by name, which is English-only; in
    /// other languages deleted notes are imported too (a known gap).
    private static let scriptSource = """
    on listwispnotes()
        with timeout of 600 seconds
            tell application "Notes"
                set noteIDs to id of every note
                set noteNames to name of every note
                set noteDates to modification date of every note
                set noteLocks to password protected of every note
                set deletedNoteIDs to {}
                repeat with deletedFolder in (every folder whose name is "Recently Deleted")
                    set deletedNoteIDs to deletedNoteIDs & (id of every note of deletedFolder)
                end repeat
                return {noteIDs, noteNames, noteDates, noteLocks, deletedNoteIDs}
            end tell
        end timeout
    end listwispnotes

    on wispnotebody(noteID)
        with timeout of 120 seconds
            tell application "Notes"
                return body of note id noteID
            end tell
        end timeout
    end wispnotebody
    """

    /// Every note's listing entry. Launches Notes if it isn't running.
    static func listNotes() async throws -> [AppleNoteListingEntry] {
        try await runOnScriptQueue {
            let script = try compiledScript()
            let listingDescriptor = try callHandler(named: "listwispnotes", parameters: [], in: script)
            return try listingEntries(from: listingDescriptor)
        }
    }

    /// Bodies (HTML) by note id. A note that fails to read (deleted between
    /// listing and fetching) is left out rather than failing the batch —
    /// except a permission error, which fails everything.
    static func fetchBodies(noteIDs: [String]) async throws -> [String: String] {
        try await runOnScriptQueue {
            let script = try compiledScript()
            var bodiesByNoteID: [String: String] = [:]
            for noteID in noteIDs {
                do {
                    let bodyDescriptor = try callHandler(named: "wispnotebody", parameters: [noteID], in: script)
                    bodiesByNoteID[noteID] = bodyDescriptor.stringValue ?? ""
                } catch BridgeError.automationNotAllowed {
                    throw BridgeError.automationNotAllowed
                } catch {
                    print("⚠️ Brain notes: couldn't read one Apple Note: \(error.localizedDescription)")
                }
            }
            return bodiesByNoteID
        }
    }

    // MARK: - Private

    private static func runOnScriptQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func compiledScript() throws -> NSAppleScript {
        guard let script = NSAppleScript(source: scriptSource) else {
            throw BridgeError.scriptFailed("the Notes script could not be prepared")
        }
        var compileErrorInfo: NSDictionary?
        guard script.compileAndReturnError(&compileErrorInfo) else {
            let compileErrorMessage = (compileErrorInfo?[NSAppleScript.errorMessage] as? String) ?? "compile error"
            throw BridgeError.scriptFailed(compileErrorMessage)
        }
        return script
    }

    private static func callHandler(named handlerName: String, parameters: [String], in script: NSAppleScript) throws -> NSAppleEventDescriptor {
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
        // AppleScript handler names are case-insensitive and stored lowercased.
        handlerCallEvent.setDescriptor(NSAppleEventDescriptor(string: handlerName), forKeyword: AEKeyword(keyASSubroutineName))
        handlerCallEvent.setDescriptor(handlerParameters, forKeyword: AEKeyword(keyDirectObject))

        var scriptErrorInfo: NSDictionary?
        // Declared non-null but nil on failure, hence the explicit optional.
        let scriptResult: NSAppleEventDescriptor? = script.executeAppleEvent(handlerCallEvent, error: &scriptErrorInfo)
        if let scriptErrorInfo {
            let scriptErrorNumber = (scriptErrorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let scriptErrorMessage = (scriptErrorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            if scriptErrorNumber == -1743 { throw BridgeError.automationNotAllowed }
            throw BridgeError.scriptFailed("\(scriptErrorMessage) (\(scriptErrorNumber))")
        }
        guard let scriptResult else { throw BridgeError.scriptFailed("Notes returned nothing") }
        return scriptResult
    }

    /// Zips the five parallel lists the listing handler returns.
    private static func listingEntries(from listingDescriptor: NSAppleEventDescriptor) throws -> [AppleNoteListingEntry] {
        guard listingDescriptor.numberOfItems == 5,
              let idsDescriptor = listingDescriptor.atIndex(1),
              let namesDescriptor = listingDescriptor.atIndex(2),
              let datesDescriptor = listingDescriptor.atIndex(3),
              let locksDescriptor = listingDescriptor.atIndex(4),
              let deletedIDsDescriptor = listingDescriptor.atIndex(5) else {
            throw BridgeError.scriptFailed("unexpected reply from Notes")
        }
        var deletedNoteIDs = Set<String>()
        if deletedIDsDescriptor.numberOfItems > 0 {
            for itemIndex in 1...deletedIDsDescriptor.numberOfItems {
                if let deletedNoteID = deletedIDsDescriptor.atIndex(itemIndex)?.stringValue {
                    deletedNoteIDs.insert(deletedNoteID)
                }
            }
        }
        let noteCount = idsDescriptor.numberOfItems
        guard noteCount > 0 else { return [] }
        var entries: [AppleNoteListingEntry] = []
        for itemIndex in 1...noteCount {
            guard let noteID = idsDescriptor.atIndex(itemIndex)?.stringValue else { continue }
            entries.append(AppleNoteListingEntry(
                noteID: noteID,
                name: namesDescriptor.atIndex(itemIndex)?.stringValue ?? "Untitled",
                modificationDate: datesDescriptor.atIndex(itemIndex)?.dateValue ?? Date(),
                isPasswordProtected: locksDescriptor.atIndex(itemIndex)?.booleanValue ?? false,
                isInRecentlyDeleted: deletedNoteIDs.contains(noteID)
            ))
        }
        return entries
    }
}
