//
//  Automation.swift
//  leanring-buddy
//
//  The one model that replaces Routines, buddy jobs and the Jobs page:
//  Trigger -> Source -> Action -> Output -> Notify, owned by a buddy.
//
//  Foundation only and `nonisolated` (the app builds with main-actor default
//  isolation) so the pure suites in Tests/AutomationDraft, AutomationSchedule and
//  AutomationMigration compile it without the rest of the app.
//
//  Nothing in here ever holds the Canvas feed link or a key: an automation names
//  *what* to do, never a secret.
//

import Foundation

nonisolated struct Automation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// The owning buddy. Nil only transiently (a draft before a buddy is chosen); the store
    /// assigns the day's Planner/Briefer when saving without one.
    var buddyID: UUID?
    var trigger: AutomationTrigger
    var source: AutomationSource
    var action: AutomationAction
    /// At least one; `[.notchCard]` is the default.
    var outputs: [AutomationOutput]
    var notify: AutomationNotifyPolicy
    /// False = paused.
    var isEnabled: Bool
    /// SF Symbol, from `RoutineStore.availableSymbolNames` or the template.
    var symbolName: String
    /// Manual triggers only: the Talk-chord digit (1...9). Informational for a migrated routine,
    /// whose digit keeps firing through RoutineStore (so it never fires twice).
    var shortcutDigit: Int?
    /// Blank values (`{topic|default}`) remembered between manual runs.
    var parameterValues: [String: String]?
    let createdAt: Date
    var lastRunAt: Date?
    /// Cached from the schedule; nil for manual and event triggers.
    var nextRunAt: Date?
    /// Set by migration, nil otherwise.
    var legacyOrigin: AutomationLegacyOrigin?
    var schemaVersion: Int
    /// Added beyond the contract. Scheduled slots at or before this moment are not "missed": the
    /// store sets it when an automation is switched back on or its schedule is edited, so
    /// resuming after a long pause does not fire a stale slot at once.
    var scheduleBaselineAt: Date?
    /// Added beyond the contract. True once the draft card showed "this leaves your Mac" for a
    /// private source (reminders, clipboard, screen text, folder files) read by a cloud-model
    /// buddy. Without it the engine refuses to hand that data to a cloud model.
    var acknowledgedSourceLeavesMac: Bool?
    /// Added beyond the contract. Why Wisp paused this automation itself (three unattended
    /// failures in a row), shown on its row until the user resumes it; nil when it is running
    /// or the user paused it.
    var pausedReason: String?

    static let currentSchemaVersion = 1

    init(
        id: UUID = UUID(),
        name: String,
        buddyID: UUID?,
        trigger: AutomationTrigger,
        source: AutomationSource = .nothing,
        action: AutomationAction,
        outputs: [AutomationOutput] = [.notchCard],
        notify: AutomationNotifyPolicy = .always,
        isEnabled: Bool = true,
        symbolName: String = "sparkles",
        shortcutDigit: Int? = nil,
        parameterValues: [String: String]? = nil,
        createdAt: Date,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        legacyOrigin: AutomationLegacyOrigin? = nil,
        schemaVersion: Int = Automation.currentSchemaVersion,
        scheduleBaselineAt: Date? = nil,
        acknowledgedSourceLeavesMac: Bool? = nil,
        pausedReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.buddyID = buddyID
        self.trigger = trigger
        self.source = source
        self.action = action
        self.outputs = outputs
        self.notify = notify
        self.isEnabled = isEnabled
        self.symbolName = symbolName
        self.shortcutDigit = shortcutDigit
        self.parameterValues = parameterValues
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.legacyOrigin = legacyOrigin
        self.schemaVersion = schemaVersion
        self.scheduleBaselineAt = scheduleBaselineAt
        self.acknowledgedSourceLeavesMac = acknowledgedSourceLeavesMac
        self.pausedReason = pausedReason
    }

    /// Whether this automation is a view onto JobsEngine's own timers (Canvas sync, morning
    /// checklist). The engine must never schedule those a second time.
    var isDrivenByJobsEngine: Bool {
        switch action {
        case .syncCanvas, .buildDailyChecklist: return true
        case .askBuddy, .proposeStudyBlocks, .replayLearnedShortcut: return false
        }
    }

    /// The reasons this automation cannot be saved or run, in plain words. Empty = valid.
    func validationProblems() -> [String] {
        var problems: [String] = []

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Give it a name.")
        }
        if outputs.isEmpty {
            problems.append("Pick at least one place for the result to go.")
        }
        if outputs.contains(.calendarBlock) && !allowsCalendarBlockOutput {
            problems.append("Calendar blocks only work with study blocks, or an instruction that says to schedule something.")
        }

        switch trigger {
        case .schedule(let schedule):
            problems.append(contentsOf: schedule.validationProblems())
        case .event(let event):
            problems.append(contentsOf: event.validationProblems())
        case .manual:
            break
        }

        if case .askBuddy(let instruction) = action {
            if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("Say what it should do.")
            }
            // No one is there to answer a blank on a scheduled or event run.
            if trigger != .manual {
                for blankName in AutomationInstructionBlanks.namesOfBlanksWithoutDefaults(in: instruction) {
                    let rememberedValue = parameterValues?[blankName.lowercased()] ?? ""
                    if rememberedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                        problems.append("Needs a value for {\(blankName)} because nobody is there to answer.")
                    }
                }
            }
        }

        if case .replayLearnedShortcut = action, source != .nothing {
            problems.append("Replaying a shortcut doesn't read a source.")
        }

        switch source {
        case .canvasDeadlines(let withinDays):
            if !(1...60).contains(withinDays) { problems.append("Canvas look-ahead must be 1 to 60 days.") }
        case .folderFiles(let path):
            if path.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pick a folder.") }
        case .nothing, .todaysCalendar, .reminders, .clipboard, .screenText:
            break
        }

        if let shortcutDigit, !(1...9).contains(shortcutDigit) {
            problems.append("The shortcut digit must be 1 to 9.")
        }
        return problems
    }

    var isValid: Bool { validationProblems().isEmpty }

    private var allowsCalendarBlockOutput: Bool {
        switch action {
        case .proposeStudyBlocks:
            return true
        case .askBuddy(let instruction):
            return instruction.lowercased().contains("schedule")
        case .syncCanvas, .buildDailyChecklist, .replayLearnedShortcut:
            return false
        }
    }
}

nonisolated enum AutomationTrigger: Codable, Equatable, Sendable {
    case schedule(AutomationSchedule)
    case event(AutomationEvent)
    case manual
}

nonisolated enum AutomationEvent: Codable, Equatable, Sendable {
    case newCanvasItem
    /// 1...120.
    case meetingStarting(minutesBefore: Int)
    /// Backed by ScreenWatcherStore, one watch per automation.
    case screenTextAppears(text: String)
    /// A polled folder; files added since the last look.
    case fileDropped(folderPath: String)

    static let meetingMinutesRange = 1...120

    func validationProblems() -> [String] {
        switch self {
        case .newCanvasItem:
            return []
        case .meetingStarting(let minutesBefore):
            return Self.meetingMinutesRange.contains(minutesBefore)
                ? [] : ["Minutes before a meeting must be 1 to 120."]
        case .screenTextAppears(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ["Say which text to wait for."] : []
        case .fileDropped(let folderPath):
            return folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ["Pick a folder to watch."] : []
        }
    }
}

/// What data the run starts from. Fetched by Wisp (no model) and put in front of the model as DATA.
nonisolated enum AutomationSource: Codable, Equatable, Sendable {
    case nothing
    case todaysCalendar
    case canvasDeadlines(withinDays: Int)
    case reminders(listName: String?)
    case clipboard
    case screenText
    case folderFiles(path: String)

    /// Whether fetching this reads something private that a cloud model must not receive
    /// unless the user was shown "this leaves your Mac" (see the privacy checklist).
    var isSensitiveForCloudModels: Bool {
        switch self {
        case .reminders, .clipboard, .screenText, .folderFiles, .todaysCalendar, .canvasDeadlines: return true
        case .nothing: return false
        }
    }
}

nonisolated enum AutomationAction: Codable, Equatable, Sendable {
    /// A model turn: the instruction (with `{blank|default}` blanks) plus the source data.
    case askBuddy(instruction: String)
    /// Existing JobsEngine work, no model. The automation is DRIVEN BY JobsEngine.
    case syncCanvas
    case buildDailyChecklist
    /// Existing StudyBlockPlanner proposals; writing them always asks.
    case proposeStudyBlocks
    /// Replays a learned shortcut's recorded tool calls, no model (see
    /// docs/learned-shortcuts-plan.md). Names the shortcut by id so this file stays free of tool
    /// types; the shortcut's blanks use the values it was learned with. Unattended runs are
    /// limited by `AutomationToolPolicy.permitsRecordedShortcutStepInUnattendedRun`.
    case replayLearnedShortcut(shortcutID: UUID)
}

nonisolated enum AutomationOutput: Codable, Equatable, Hashable, Sendable {
    /// Reply in the notch + glance card if the answer carries one.
    case notchCard
    /// Default list title "Wisp Today"; only Wisp's own lists.
    case remindersChecklist(listTitle: String)
    /// ALWAYS asks, even attended.
    case calendarBlock
    case notification
    /// Filed in the buddy's thread (BuddyThreadStore).
    case buddyThreadMessage
    /// The [SAY: ...] line, only in voice mode.
    case spokenLine

    static let defaultChecklistListTitle = "Wisp Today"
}

nonisolated enum AutomationNotifyPolicy: String, Codable, CaseIterable, Sendable {
    case always, onlyWhenSomethingNew, onlyOnFailure, never
}

nonisolated enum AutomationLegacyOrigin: Codable, Equatable, Hashable, Sendable {
    /// `WispRoutine.id`.
    case routine(UUID)
    /// `WispBuddy.id`.
    case buddyJob(UUID)
    case jobsCanvas
    case jobsDailyChecklist
}

// MARK: - Blanks

/// `{name}` / `{name|default}` blanks in an instruction, same syntax as `RoutineParameters`. A
/// small pure copy because `RoutineParameters` is main-actor isolated and these rules must run in
/// the Foundation-only suites. Resolution at run time still goes through `RoutineParameters`.
nonisolated enum AutomationInstructionBlanks {
    private static let builtInKeys: Set<String> = ["clipboard", "date", "time"]

    private static let placeholderPattern = try! NSRegularExpression(
        pattern: #"\{([A-Za-z][A-Za-z0-9 _-]{0,30})(?:\|([^{}\n]{0,200}))?\}"#
    )

    /// Whether the instruction contains `{clipboard}`, which reads the pasteboard at run time.
    static func usesClipboard(in instruction: String) -> Bool {
        let fullRange = NSRange(instruction.startIndex..., in: instruction)
        return placeholderPattern.matches(in: instruction, range: fullRange).contains { match in
            guard let nameRange = Range(match.range(at: 1), in: instruction) else { return false }
            return instruction[nameRange].trimmingCharacters(in: .whitespaces).lowercased() == "clipboard"
        }
    }

    /// Names (as first written) of blanks the user would have to fill and that have no default.
    static func namesOfBlanksWithoutDefaults(in instruction: String) -> [String] {
        var namesWithDefaults: Set<String> = []
        var orderedNames: [String] = []
        let fullRange = NSRange(instruction.startIndex..., in: instruction)
        for match in placeholderPattern.matches(in: instruction, range: fullRange) {
            guard let nameRange = Range(match.range(at: 1), in: instruction) else { continue }
            let name = String(instruction[nameRange])
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !builtInKeys.contains(key) else { continue }
            if match.range(at: 2).location != NSNotFound {
                namesWithDefaults.insert(key)
            }
            if !orderedNames.contains(where: { $0.lowercased() == key }) {
                orderedNames.append(name)
            }
        }
        return orderedNames.filter { !namesWithDefaults.contains($0.lowercased()) }
    }
}


/// The one rule for "would this run hand private data to the model?". The declared source is not
/// the only way in: an event trigger puts meeting titles, Canvas items, file names or watched
/// screen text into the prompt, and `{clipboard}` in the instruction reads the pasteboard.
nonisolated enum AutomationCloudPrivacy {
    static func readsPrivateDataForModel(source: AutomationSource, trigger: AutomationTrigger, action: AutomationAction) -> Bool {
        guard case .askBuddy(let instruction) = action else { return false }
        if source.isSensitiveForCloudModels { return true }
        if case .event = trigger { return true }
        return AutomationInstructionBlanks.usesClipboard(in: instruction)
    }
}
