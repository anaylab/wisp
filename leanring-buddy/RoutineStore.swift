//
//  RoutineStore.swift
//  leanring-buddy
//
//  Routines: saved instructions Wisp runs on demand — from the notch, from the
//  dashboard, or with ⌃⌥ + a number key. A routine can name the apps it is
//  useful in, and the notch then suggests it whenever one of those apps is in
//  front ("Summarize this page" in a browser, "Explain this error" in Xcode).
//
//  Routines differ from skills (`~/.wisp/skills/*.md`): a skill is reference
//  material the model loads on demand; a routine is an instruction the *user*
//  fires. Running one sends its instruction through the ordinary screenshot
//  turn, exactly as if the user had typed it.
//
//  Stored at `~/Library/Application Support/Wisp/routines.json`. The first
//  launch (no file yet) seeds a few starters so app-aware suggestions have
//  something to show; after that the file is the user's, deletions included.
//

import Combine
import Foundation

struct WispRoutine: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// What Wisp is asked to do, sent as the turn's prompt.
    var instruction: String
    /// SF Symbol shown on the routine's chip and row.
    var symbolName: String
    /// 1–9: the routine runs on ⌃⌥ + this digit. Nil for no shortcut.
    var shortcutDigit: Int?
    /// Bundle identifiers of the apps where the notch suggests this routine.
    var suggestedAppBundleIdentifiers: [String]
    /// Display names for those apps, parallel to the identifiers, so the editor
    /// can label them without looking each one up.
    var suggestedAppNames: [String]
    /// Shown in the notch whatever app is in front.
    var isPinnedInNotch: Bool
    var lastRunAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        instruction: String,
        symbolName: String = "bolt",
        shortcutDigit: Int? = nil,
        suggestedAppBundleIdentifiers: [String] = [],
        suggestedAppNames: [String] = [],
        isPinnedInNotch: Bool = false,
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.symbolName = symbolName
        self.shortcutDigit = shortcutDigit
        self.suggestedAppBundleIdentifiers = suggestedAppBundleIdentifiers
        self.suggestedAppNames = suggestedAppNames
        self.isPinnedInNotch = isPinnedInNotch
        self.lastRunAt = lastRunAt
    }
}

@MainActor
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()

    /// The symbols the editor offers. Kept short and general so every choice
    /// reads clearly at chip size.
    static let availableSymbolNames = [
        "bolt", "text.alignleft", "chevron.left.forwardslash.chevron.right",
        "arrowshape.turn.up.left", "globe", "doc.text", "character.bubble",
        "checklist", "sparkles", "magnifyingglass", "envelope", "calendar",
    ]

    /// How a routine's shortcut reads, e.g. "⌃⌥1". Built from the user's
    /// current talk chord (rebindable in the Shortcuts tab), since the digit is
    /// pressed while that chord is held.
    static func shortcutLabel(forDigit shortcutDigit: Int) -> String {
        let chordSymbols = ShortcutBindingStore.shared.primaryHoldChord.keyCapsuleLabels.map { keyName in
            switch keyName {
            case "ctrl", "control": return "⌃"
            case "option": return "⌥"
            case "shift": return "⇧"
            case "space": return "Space+"
            default: return keyName
            }
        }
        return chordSymbols.joined() + "\(shortcutDigit)"
    }

    /// The most routines the notch shows at once, so the panel stays short.
    static let maximumNotchSuggestions = 4

    @Published private(set) var routines: [WispRoutine] = []

    static let defaultRoutinesFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/routines.json")

    private let routinesFileURL: URL

    /// The app uses `shared`, backed by the real file. Tests make their own store
    /// on a temporary file so they never touch the user's routines.
    init(routinesFileURL: URL = RoutineStore.defaultRoutinesFileURL) {
        self.routinesFileURL = routinesFileURL
        routines = loadRoutines()
    }

    // MARK: - Queries

    func routine(withID routineID: UUID) -> WispRoutine? {
        routines.first { $0.id == routineID }
    }

    func routine(forShortcutDigit shortcutDigit: Int) -> WispRoutine? {
        routines.first { $0.shortcutDigit == shortcutDigit }
    }

    /// What the notch offers with `bundleIdentifier` in front: routines made for
    /// that app first, then pinned ones, capped at `maximumNotchSuggestions`.
    func notchSuggestions(forAppBundleIdentifier bundleIdentifier: String?) -> [WispRoutine] {
        let appSpecificRoutines = routines.filter { routine in
            guard let bundleIdentifier else { return false }
            return routine.suggestedAppBundleIdentifiers.contains(bundleIdentifier)
        }
        let pinnedRoutines = routines.filter { routine in
            routine.isPinnedInNotch && !appSpecificRoutines.contains(routine)
        }
        return Array((appSpecificRoutines + pinnedRoutines).prefix(Self.maximumNotchSuggestions))
    }

    /// Whether any routine is suggested for this app specifically (as opposed to
    /// only pinned ones), so the notch can title the section "For Safari".
    func hasAppSpecificSuggestions(forAppBundleIdentifier bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return routines.contains { $0.suggestedAppBundleIdentifiers.contains(bundleIdentifier) }
    }

    // MARK: - Editing

    @discardableResult
    func addRoutine(_ newRoutine: WispRoutine) -> WispRoutine {
        var routineToAdd = newRoutine
        routineToAdd.shortcutDigit = shortcutDigitIfFree(routineToAdd.shortcutDigit, forRoutineID: routineToAdd.id)
        routines.append(routineToAdd)
        saveRoutines()
        return routineToAdd
    }

    /// Saves an edited routine. A shortcut digit another routine already uses is
    /// moved to this one — the most recent choice wins, as in System Settings.
    func updateRoutine(_ updatedRoutine: WispRoutine) {
        guard let index = routines.firstIndex(where: { $0.id == updatedRoutine.id }) else { return }
        if let shortcutDigit = updatedRoutine.shortcutDigit {
            for otherIndex in routines.indices where routines[otherIndex].id != updatedRoutine.id
                && routines[otherIndex].shortcutDigit == shortcutDigit {
                routines[otherIndex].shortcutDigit = nil
            }
        }
        routines[index] = updatedRoutine
        saveRoutines()
    }

    func deleteRoutine(withID routineID: UUID) {
        routines.removeAll { $0.id == routineID }
        saveRoutines()
    }

    func markRoutineRun(withID routineID: UUID) {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[index].lastRunAt = Date()
        saveRoutines()
    }

    private func shortcutDigitIfFree(_ shortcutDigit: Int?, forRoutineID routineID: UUID) -> Int? {
        guard let shortcutDigit else { return nil }
        let isTaken = routines.contains { $0.id != routineID && $0.shortcutDigit == shortcutDigit }
        return isTaken ? nil : shortcutDigit
    }

    // MARK: - Persistence

    private func loadRoutines() -> [WispRoutine] {
        guard let fileData = try? Data(contentsOf: routinesFileURL) else {
            // First launch: start with a few useful routines rather than an
            // empty list, and write them so a deletion sticks.
            let starterRoutines = Self.starterRoutines
            routines = starterRoutines
            saveRoutines()
            return starterRoutines
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([WispRoutine].self, from: fileData)
        } catch {
            // Leave the unreadable file alone (it's the user's) and run without
            // routines rather than overwriting it with starters.
            print("⚠️ RoutineStore: could not read \(routinesFileURL.path): \(error)")
            return []
        }
    }

    private func saveRoutines() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let encodedRoutines = try encoder.encode(routines)
            try FileManager.default.createDirectory(
                at: routinesFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encodedRoutines.write(to: routinesFileURL, options: .atomic)
        } catch {
            print("⚠️ RoutineStore: failed to save routines: \(error)")
        }
    }

    // MARK: - Starters

    private static let browserBundleIdentifiers = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
    ]
    private static let browserNames = ["Chrome", "Safari", "Arc", "Firefox", "Edge", "Brave"]

    static let starterRoutines: [WispRoutine] = [
        WispRoutine(
            name: "Summarize this page",
            instruction: "Summarize the page on my screen in three short bullet points.",
            symbolName: "text.alignleft",
            shortcutDigit: 1,
            suggestedAppBundleIdentifiers: browserBundleIdentifiers,
            suggestedAppNames: browserNames
        ),
        WispRoutine(
            name: "Explain this error",
            instruction: "Look at the error on my screen. Explain the cause in two sentences, then point at what I should change.",
            symbolName: "chevron.left.forwardslash.chevron.right",
            shortcutDigit: 2,
            suggestedAppBundleIdentifiers: ["com.apple.dt.Xcode", "com.apple.Terminal", "com.microsoft.VSCode", "com.googlecode.iterm2"],
            suggestedAppNames: ["Xcode", "Terminal", "VS Code", "iTerm"]
        ),
        WispRoutine(
            name: "Draft a reply",
            instruction: "Read the message on my screen and draft a short, friendly reply I can paste.",
            symbolName: "arrowshape.turn.up.left",
            suggestedAppBundleIdentifiers: ["com.apple.mail", "com.tinyspeck.slackmacgap", "com.apple.MobileSMS"],
            suggestedAppNames: ["Mail", "Slack", "Messages"]
        ),
        WispRoutine(
            name: "What should I click?",
            instruction: "I'm stuck on what's on my screen. Point at the one thing I should click next and say why in a sentence.",
            symbolName: "sparkles",
            isPinnedInNotch: true
        ),
    ]
}
