//
//  WispAppIntents.swift
//  leanring-buddy
//
//  Wisp in Siri, Spotlight and Shortcuts (Phase 4 of `docs/siri-style-plan.md`).
//  macOS lists an app's App Intents in the Shortcuts app and Spotlight, and
//  the `AppShortcutsProvider` phrases make them speakable to Siri ("Ask Wisp",
//  "Run Summarize this page in Wisp") with no setup.
//
//  • Ask Wisp — a question in, the answer out (`WispIntentAnswer`): Shortcuts
//    gets it as text, Siri reads it. It runs exactly like a typed question.
//  • Run Routine / Run Buddy — the user's routines and buddies as App Entities,
//    so Siri and Shortcuts can name them.
//  • Add to Brain — a file or a web address onto the brain's ingest queue.
//
//  The intents run inside the menu bar app (macOS starts it in the background
//  if needed) and reach the live `CompanionManager` through App Intents'
//  dependency injection (`AppDependencyManager`, registered by the app
//  delegate). None of them opens a window.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

// MARK: - Ask Wisp

struct AskWispIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Wisp"
    static let description = IntentDescription(
        "Ask Wisp anything — about your screen, your calendar and files, or the world. The answer shows in the notch and is returned as text.",
        categoryName: "Wisp"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Wisp?")
    var question: String

    @Dependency private var companionManager: CompanionManager

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Wisp \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let intentAnswer = await companionManager.answerForIntent(question: question)
        return .result(value: intentAnswer.text, dialog: IntentDialog(stringLiteral: intentAnswer.text))
    }
}

// MARK: - Routines

struct RoutineEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wisp Routine"
    static let defaultQuery = RoutineEntityQuery()

    let id: UUID
    let name: String
    let instruction: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(instruction)",
            image: .init(systemName: symbolName)
        )
    }

    init(routine: WispRoutine) {
        id = routine.id
        name = routine.name
        instruction = routine.instruction
        symbolName = routine.symbolName
    }
}

struct RoutineEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [RoutineEntity] {
        identifiers.compactMap { RoutineStore.shared.routine(withID: $0) }.map(RoutineEntity.init(routine:))
    }

    @MainActor
    func suggestedEntities() async throws -> [RoutineEntity] {
        RoutineStore.shared.routines.map(RoutineEntity.init(routine:))
    }

    @MainActor
    func entities(matching searchText: String) async throws -> [RoutineEntity] {
        RoutineStore.shared.routines
            .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            .map(RoutineEntity.init(routine:))
    }
}

struct RunRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Wisp Routine"
    static let description = IntentDescription(
        "Run one of your Wisp routines on what's on screen, and get its answer.",
        categoryName: "Wisp"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Routine", requestValueDialog: "Which routine?")
    var routine: RoutineEntity

    @Dependency private var companionManager: CompanionManager

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$routine)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let intentAnswer = await companionManager.answerForIntent(runningRoutineWithID: routine.id)
        return .result(value: intentAnswer.text, dialog: IntentDialog(stringLiteral: intentAnswer.text))
    }
}

// MARK: - Buddies

struct BuddyEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wisp Buddy"
    static let defaultQuery = BuddyEntityQuery()

    let id: UUID
    let name: String
    let instruction: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(instruction)", image: .init(systemName: "person.crop.circle"))
    }

    init(buddy: WispBuddy) {
        id = buddy.id
        name = buddy.name
        instruction = buddy.instruction
    }
}

struct BuddyEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [BuddyEntity] {
        identifiers.compactMap { BuddyStore.shared.buddy(withID: $0) }.map(BuddyEntity.init(buddy:))
    }

    @MainActor
    func suggestedEntities() async throws -> [BuddyEntity] {
        BuddyStore.shared.buddies.map(BuddyEntity.init(buddy:))
    }

    @MainActor
    func entities(matching searchText: String) async throws -> [BuddyEntity] {
        BuddyStore.shared.buddies
            .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            .map(BuddyEntity.init(buddy:))
    }
}

struct RunBuddyIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Wisp Buddy"
    static let description = IntentDescription(
        "Start one of your Wisp buddies on its job, or send it a message. It works in the background; its answer appears in its thread.",
        categoryName: "Wisp"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Buddy", requestValueDialog: "Which buddy?")
    var buddy: BuddyEntity

    @Parameter(title: "Message", description: "Leave empty to run the buddy's own job.")
    var message: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$buddy)") {
            \.$message
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let didStart = trimmedMessage.isEmpty
            ? BuddyStore.shared.runNow(buddyWithID: buddy.id)
            : BuddyStore.shared.sendMessage(trimmedMessage, toBuddyWithID: buddy.id)
        let replyText = didStart
            ? "\(buddy.name) is on it. Its answer will appear in its thread in Wisp."
            : "\(buddy.name) is busy or the queue is full — try again in a moment."
        return .result(dialog: IntentDialog(stringLiteral: replyText))
    }
}

// MARK: - Brain

struct AddToBrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Wisp Brain"
    static let description = IntentDescription(
        "Add a file or a web page to your Wisp brain. Wisp reads it on this Mac and files what it learns.",
        categoryName: "Wisp"
    )
    static let openAppWhenRun = false

    @Parameter(title: "File", supportedContentTypes: [.item])
    var file: IntentFile?

    @Parameter(title: "Web address")
    var webAddress: URL?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$file) to my Wisp brain") {
            \.$webAddress
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard BrainPreferences.shared.isBrainEnabled else {
            return .result(dialog: "Your Wisp brain is turned off. Turn it on in Wisp → Brain → Settings.")
        }
        var addedNames: [String] = []
        if let file {
            let localFileURL = try Self.localCopy(of: file)
            BrainIngestQueue.shared.enqueue(fileURL: localFileURL)
            addedNames.append(file.filename)
        }
        if let webAddress {
            BrainIngestQueue.shared.enqueue(webPageURL: webAddress)
            addedNames.append(webAddress.host() ?? webAddress.absoluteString)
        }
        guard !addedNames.isEmpty else {
            return .result(dialog: "Give me a file or a web address to add.")
        }
        let addedList = addedNames.map { "“\($0)”" }.joined(separator: " and ")
        return .result(dialog: IntentDialog(stringLiteral: "Added \(addedList) to your brain — Wisp is reading it now."))
    }

    /// The ingest queue reads files later, by path, but an intent's file may
    /// arrive only as data (from another app) or as a URL that's only valid
    /// during this call. A copy in Wisp's own folder is valid for as long as
    /// the queue needs it.
    private static func localCopy(of intentFile: IntentFile) throws -> URL {
        let importFolderURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp/IntentImports/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: importFolderURL, withIntermediateDirectories: true)
        let safeFilename = intentFile.filename.replacingOccurrences(of: "/", with: "-")
        let localFileURL = importFolderURL.appendingPathComponent(safeFilename.isEmpty ? "Imported file" : safeFilename)
        try intentFile.data.write(to: localFileURL)
        return localFileURL
    }
}

// MARK: - Siri and Spotlight

/// The intents Siri and Spotlight offer with no setup, and the phrases Siri
/// listens for. Every phrase has to name the app. Phrases naming a routine or
/// buddy need their current names, so `updateAppShortcutParameters()` is
/// called at launch and whenever routines or buddies are saved.
struct WispAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskWispIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Hey \(.applicationName)",
            ],
            shortTitle: "Ask Wisp",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: RunRoutineIntent(),
            phrases: [
                "Run \(\.$routine) in \(.applicationName)",
                "Run a \(.applicationName) routine",
            ],
            shortTitle: "Run Routine",
            systemImageName: "bolt"
        )
        AppShortcut(
            intent: RunBuddyIntent(),
            phrases: [
                "Run \(\.$buddy) in \(.applicationName)",
                "Start a \(.applicationName) buddy",
            ],
            shortTitle: "Run Buddy",
            systemImageName: "person.2"
        )
        AppShortcut(
            intent: AddToBrainIntent(),
            phrases: [
                "Add to my \(.applicationName) brain",
            ],
            shortTitle: "Add to Brain",
            systemImageName: "brain"
        )
    }
}
