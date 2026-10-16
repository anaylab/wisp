//
//  WispShareBundle.swift
//  leanring-buddy
//
//  Sharing routines and buddies as a file (`.wisp`, JSON). A bundle carries the
//  *setup* — a routine's name, instruction and icon; a buddy's job, colour,
//  specialty, model and tool limits — and nothing personal: no conversation, no
//  notes or files, no memory, no keyboard shortcut, no schedule, and never a key
//  (those aren't in these types to begin with). Importing one is a hand-off from
//  someone else, so the file is treated as untrusted: size and count caps, text
//  trimmed and capped, an icon outside the allowed set replaced, and the review
//  (`WispShareReview`) tells the user what an imported buddy could do before
//  anything is added. An imported buddy arrives with its schedule off.
//
//  Pure: reading and writing the file and adding the items are
//  `WispShareImporter`'s job.
//

import Foundation

struct SharedRoutine: Codable, Equatable {
    var name: String
    var instruction: String
    var symbolName: String
    var suggestedAppBundleIdentifiers: [String]
    var suggestedAppNames: [String]
}

struct SharedBuddy: Codable, Equatable {
    var name: String
    var instruction: String
    var colorIndex: Int
    var specialty: BuddySpecialty?
    var modelChoice: BuddyModelChoice?
    var toolAccess: BuddyToolAccess?
    /// How often it ran for its author, as words ("Every day at 9:00 AM") — shown
    /// on import, which leaves the buddy's schedule off.
    var scheduleSummary: String?
}

struct WispShareBundle: Codable, Equatable {
    static let formatIdentifier = "wisp-share"
    static let currentVersion = 1

    var format: String = WispShareBundle.formatIdentifier
    var version: Int = WispShareBundle.currentVersion
    var routines: [SharedRoutine]?
    var buddies: [SharedBuddy]?

    var itemCount: Int { (routines?.count ?? 0) + (buddies?.count ?? 0) }
}

enum WispShareBundleCodec {
    static let maximumFileBytes = 1_000_000
    static let maximumItemsPerKind = 50
    static let maximumNameCharacters = 80
    static let maximumInstructionCharacters = 4000
    static let maximumAppEntries = 20
    static let maximumToolGroups = 40
    static let fileExtension = "wisp"

    enum DecodeFailure: Error, Equatable {
        case tooLarge
        case notAWispFile
        case newerThanThisWisp
        case nothingToImport

        var message: String {
            switch self {
            case .tooLarge: return "That file is too large to be a Wisp share."
            case .notAWispFile: return "That isn't a Wisp share file."
            case .newerThanThisWisp: return "That file was made by a newer version of Wisp. Update Wisp to import it."
            case .nothingToImport: return "There's nothing in that file to import."
            }
        }
    }

    // MARK: Export

    /// What leaves this Mac for a routine: its setup only.
    static func sharedRoutine(from routine: WispRoutine) -> SharedRoutine {
        SharedRoutine(
            name: routine.name,
            instruction: routine.instruction,
            symbolName: routine.symbolName,
            suggestedAppBundleIdentifiers: routine.suggestedAppBundleIdentifiers,
            suggestedAppNames: routine.suggestedAppNames
        )
    }

    /// What leaves this Mac for a buddy: its setup only — not its thread,
    /// notes, files, runs or schedule.
    static func sharedBuddy(from buddy: WispBuddy) -> SharedBuddy {
        SharedBuddy(
            name: buddy.name,
            instruction: buddy.instruction,
            colorIndex: buddy.colorIndex,
            specialty: buddy.specialty,
            modelChoice: buddy.modelChoice,
            toolAccess: buddy.toolAccess,
            scheduleSummary: buddy.schedule.isRepeating ? buddy.schedule.summary() : nil
        )
    }

    static func encode(_ bundle: WispShareBundle) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(bundle)
    }

    // MARK: Import

    /// Reads a file's bytes into a cleaned bundle, or says why it can't.
    static func decode(_ data: Data) -> Result<WispShareBundle, DecodeFailure> {
        guard data.count <= maximumFileBytes else { return .failure(.tooLarge) }
        guard let bundle = try? JSONDecoder().decode(WispShareBundle.self, from: data),
              bundle.format == WispShareBundle.formatIdentifier else { return .failure(.notAWispFile) }
        guard bundle.version <= WispShareBundle.currentVersion else { return .failure(.newerThanThisWisp) }

        var cleaned = WispShareBundle()
        cleaned.routines = bundle.routines?.prefix(maximumItemsPerKind).compactMap(cleanedRoutine)
        cleaned.buddies = bundle.buddies?.prefix(maximumItemsPerKind).compactMap(cleanedBuddy)
        if cleaned.routines?.isEmpty == true { cleaned.routines = nil }
        if cleaned.buddies?.isEmpty == true { cleaned.buddies = nil }
        return cleaned.itemCount == 0 ? .failure(.nothingToImport) : .success(cleaned)
    }

    private static func trimmed(_ text: String, limit: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func cleanedRoutine(_ routine: SharedRoutine) -> SharedRoutine? {
        let name = trimmed(routine.name, limit: maximumNameCharacters)
        let instruction = trimmed(routine.instruction, limit: maximumInstructionCharacters)
        guard !name.isEmpty, !instruction.isEmpty else { return nil }
        let appCount = min(routine.suggestedAppBundleIdentifiers.count, routine.suggestedAppNames.count, maximumAppEntries)
        return SharedRoutine(
            name: name,
            instruction: instruction,
            symbolName: RoutineStore.availableSymbolNames.contains(routine.symbolName) ? routine.symbolName : "bolt",
            suggestedAppBundleIdentifiers: routine.suggestedAppBundleIdentifiers.prefix(appCount).map { trimmed($0, limit: 120) },
            suggestedAppNames: routine.suggestedAppNames.prefix(appCount).map { trimmed($0, limit: maximumNameCharacters) }
        )
    }

    private static func cleanedBuddy(_ buddy: SharedBuddy) -> SharedBuddy? {
        let name = trimmed(buddy.name, limit: maximumNameCharacters)
        let instruction = trimmed(buddy.instruction, limit: maximumInstructionCharacters)
        guard !name.isEmpty, !instruction.isEmpty else { return nil }

        var cleanedToolAccess = buddy.toolAccess
        if var toolAccess = cleanedToolAccess {
            toolAccess.allowedGroupIDs = Set(toolAccess.allowedGroupIDs.prefix(maximumToolGroups).map { trimmed($0, limit: 80) })
            toolAccess.allowedAppSlugs = toolAccess.allowedAppSlugs.map { Set($0.prefix(maximumToolGroups).map { trimmed($0, limit: 80) }) }
            cleanedToolAccess = toolAccess
        }
        return SharedBuddy(
            name: name,
            instruction: instruction,
            colorIndex: ((buddy.colorIndex % BuddyAppearance.paletteCount) + BuddyAppearance.paletteCount) % BuddyAppearance.paletteCount,
            specialty: buddy.specialty,
            modelChoice: buddy.modelChoice,
            toolAccess: cleanedToolAccess,
            scheduleSummary: buddy.scheduleSummary.map { trimmed($0, limit: 80) }
        )
    }

    /// A name that doesn't clash with `existingNames`: "Inbox" → "Inbox 2".
    static func uniqueName(_ name: String, avoiding existingNames: [String]) -> String {
        BuddyNameGenerator.uniqueName(name, avoiding: existingNames)
    }
}

/// Plain-words account of what importing a bundle adds, shown before it does.
enum WispShareReview {
    static func lines(for bundle: WispShareBundle) -> [String] {
        var lines: [String] = []
        for routine in bundle.routines ?? [] {
            var line = "Routine “\(routine.name)”: \(oneLine(routine.instruction))"
            let blanks = RoutineParameters.parameters(in: routine.instruction)
            if !blanks.isEmpty { line += " — asks for \(RoutineParameters.summary(of: blanks))" }
            if RoutineParameters.usesClipboard(routine.instruction) { line += " — reads your clipboard when run" }
            lines.append(line)
        }
        for buddy in bundle.buddies ?? [] {
            lines.append("Buddy “\(buddy.name)”: \(oneLine(buddy.instruction))")
            lines.append("    " + capabilityText(of: buddy))
        }
        return lines
    }

    /// What the buddy could do once it runs: where its data goes and what it may use.
    static func capabilityText(of buddy: SharedBuddy) -> String {
        var parts: [String] = []
        if let modelChoice = buddy.modelChoice {
            parts.append(modelChoice.sendsDataOffThisMachine
                         ? "runs on \(modelChoice.displayName) — what it sees leaves your Mac"
                         : "runs on \(modelChoice.displayName)")
        } else {
            parts.append("runs on whichever model Wisp uses")
        }
        if let toolAccess = buddy.toolAccess {
            parts.append("limited to \(toolAccess.allowedGroupIDs.count) tool group\(toolAccess.allowedGroupIDs.count == 1 ? "" : "s")")
        } else {
            parts.append("can use every tool Wisp has")
        }
        if let scheduleSummary = buddy.scheduleSummary {
            parts.append("was “\(scheduleSummary)” — imported with its schedule off")
        }
        return parts.joined(separator: "; ")
    }

    private static func oneLine(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        return flattened.count > 140 ? String(flattened.prefix(140)) + "…" : flattened
    }
}
