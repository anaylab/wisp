//
//  BuddyStore.swift
//  leanring-buddy
//
//  Buddies (modeled on HeyClicky's "Clickys"): named, coloured agents that
//  each own one job — "Every morning, summarize what's new on Hacker News" —
//  and keep one continuous thread (`BuddyThreadStore`) of what they were asked
//  and answered, which each run continues. A buddy doesn't hold a model
//  or a loop of its own: each run is an ordinary background task
//  (`BackgroundTaskLauncher`, via `CompanionManager.startBuddyRun`), so it
//  queues behind the one local model like any other background work and its
//  record lives in `AgentTaskRegistry` (and so in History). The buddy keeps the
//  ids of its runs, its schedule, and its identity.
//
//  Runs repeat on a schedule (`BuddySchedule`) checked once a minute while Wisp
//  is running. A run that was due while the Mac was asleep or Wisp was closed
//  runs once when Wisp next checks — not once per missed day.
//
//  Stored at `~/Library/Application Support/Wisp/buddies.json`.
//

import Combine
import Foundation

/// When a buddy runs its job.
enum BuddySchedule: Codable, Equatable {
    /// Only when asked (created, or "Run now").
    case once
    /// Every day at a local time.
    case daily(hour: Int, minute: Int)
    /// Every week on a weekday (1 = Sunday … 7 = Saturday, as `Calendar`) at a local time.
    case weekly(weekday: Int, hour: Int, minute: Int)

    /// The first run strictly after `date`, or nil for `.once`.
    func nextRunDate(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .once:
            return nil
        case .daily(let hour, let minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, second: 0),
                matchingPolicy: .nextTime
            )
        case .weekly(let weekday, let hour, let minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                matchingPolicy: .nextTime
            )
        }
    }

    var isRepeating: Bool { self != .once }

    /// "Runs when you ask", "Every day at 9:00 AM", "Every Monday at 9:00 AM".
    func summary(calendar: Calendar = .current) -> String {
        switch self {
        case .once:
            return "Runs when you ask"
        case .daily(let hour, let minute):
            return "Every day at \(Self.timeText(hour: hour, minute: minute, calendar: calendar))"
        case .weekly(let weekday, let hour, let minute):
            let weekdayName = calendar.weekdaySymbols[(weekday - 1 + 7) % 7]
            return "Every \(weekdayName) at \(Self.timeText(hour: hour, minute: minute, calendar: calendar))"
        }
    }

    private static func timeText(hour: Int, minute: Int, calendar: Calendar) -> String {
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
        return referenceDate.formatted(date: .omitted, time: .shortened)
    }

    /// A best guess at the schedule a job's own wording asks for — "every
    /// morning …" is daily, "every Monday …" weekly — so the new-buddy form
    /// can pre-select it. Conservative: anything unclear stays `.once`.
    static func inferred(fromInstruction instruction: String) -> BuddySchedule {
        let lowercasedInstruction = instruction.lowercased()

        let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (weekdayIndex, weekdayName) in weekdayNames.enumerated() {
            if lowercasedInstruction.contains("every \(weekdayName)") || lowercasedInstruction.contains("on \(weekdayName)s") {
                return .weekly(weekday: weekdayIndex + 1, hour: 9, minute: 0)
            }
        }
        if ["every week", "each week", "weekly"].contains(where: lowercasedInstruction.contains) {
            return .weekly(weekday: 2, hour: 9, minute: 0)
        }
        if ["every evening", "each evening", "every night", "each night", "nightly"].contains(where: lowercasedInstruction.contains) {
            return .daily(hour: 18, minute: 0)
        }
        if ["every morning", "each morning", "every day", "each day", "daily"].contains(where: lowercasedInstruction.contains) {
            return .daily(hour: 9, minute: 0)
        }
        return .once
    }
}

/// What one run of a buddy is for: its standing job, or a message from the user.
struct BuddyRunRequest {
    let origin: BuddyThreadExchange.Origin
    let text: String
    /// The buddy that asked, for a `.delegated` run.
    var requesterName: String? = nil
}

struct WispBuddy: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// The job, sent as the run's request.
    var instruction: String
    /// Index into `BuddyAppearance.palette`.
    var colorIndex: Int
    var schedule: BuddySchedule
    let createdAt: Date
    /// The background task ids of its runs, oldest first.
    var runTaskIDs: [UUID]
    /// When a repeating buddy runs next; nil for `.once`.
    var nextScheduledRunAt: Date?

    /// The model this buddy runs on; nil follows whatever Wisp itself uses.
    /// Optional so a buddies.json from before this existed still loads.
    var modelChoice: BuddyModelChoice?
    /// The tool groups this buddy is limited to; nil means every tool, as
    /// before. Optional for the same reason as `modelChoice`.
    var toolAccess: BuddyToolAccess?

    // List state, as Rakazo's bot list. All optional so older files still load.
    /// Kept at the top of the list.
    var isPinned: Bool?
    /// When the user last had this buddy's thread open; runs that finish
    /// after it make the buddy unread.
    var lastReadAt: Date?
    /// The user marked it unread by hand; cleared when they open it.
    var isMarkedUnread: Bool?
    /// Whether a finished run posts a notification; nil means yes.
    var notifiesWhenFinished: Bool?

    /// The most runs a buddy remembers (older ones stay in History).
    static let maximumRememberedRuns = 20

    /// Nil (older files, or never pinned) reads as not pinned.
    var isPinnedInList: Bool { isPinned ?? false }
    var postsNotificationWhenFinished: Bool { notifiesWhenFinished ?? true }
}

/// Names a buddy from its job: a subject from the instruction plus a role —
/// "summarize my Gmail every morning" → "Gmail Digest". Deterministic (no
/// model call), and the user can rename it.
enum BuddyNameGenerator {
    /// Role words keyed by the verbs that suggest them, checked in order.
    private static let rolesByVerb: [(verbs: [String], role: String)] = [
        (["summarize", "summarise", "digest", "recap", "brief"], "Digest"),
        (["watch", "monitor", "check", "keep an eye", "track"], "Watch"),
        (["find", "search", "look for", "look up", "research", "scout"], "Scout"),
        (["remind", "nudge"], "Nudge"),
        (["draft", "write", "reply", "compose"], "Writer"),
        (["organize", "organise", "clean", "tidy", "sort", "file"], "Tidy"),
        (["plan", "schedule", "prepare", "prep"], "Planner"),
    ]

    /// Words that never make a good subject.
    private static let ignoredWords: Set<String> = [
        "every", "each", "morning", "evening", "night", "day", "daily", "week", "weekly",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "please", "what", "whats", "what's", "that", "this", "these", "those", "with", "from",
        "into", "about", "anything", "something", "things", "stuff", "latest", "new",
        "summarize", "summarise", "check", "watch", "monitor", "find", "search", "look", "tell",
        "give", "send", "make", "keep", "track", "remind", "draft", "write", "reply", "organize",
        "organise", "clean", "tidy", "sort", "plan", "prepare", "research", "list", "show",
        "the", "and", "for", "my", "me", "any", "all", "out", "on", "in", "at", "of", "to", "a", "an",
        "then", "when", "there", "their", "them", "have", "has", "been", "which", "worth", "using",
        "most", "only", "just", "also", "some", "your", "our", "i", "i'll", "it",
    ]

    static func name(forInstruction instruction: String, existingNames: [String]) -> String {
        let lowercasedInstruction = instruction.lowercased()
        let role = rolesByVerb.first { roleEntry in
            roleEntry.verbs.contains(where: lowercasedInstruction.contains)
        }?.role ?? "Helper"

        let baseName = subject(from: instruction).map { "\($0) \(role)" } ?? "\(role) Buddy"
        return uniqueName(baseName, avoiding: existingNames)
    }

    /// A proper noun phrase from the middle of the instruction ("Hacker News",
    /// "Gmail"), else the first meaningful word, capitalized.
    static func subject(from instruction: String) -> String? {
        let words = instruction
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }

        // Capitalized words that aren't the first word (sentence case says
        // nothing there), joined while consecutive: "Hacker News".
        var properNounPhrase: [String] = []
        for (wordIndex, word) in words.enumerated() where wordIndex > 0 {
            let isCapitalized = word.first?.isUppercase == true
            let isIgnored = ignoredWords.contains(word.lowercased())
            if isCapitalized && !isIgnored {
                properNounPhrase.append(word)
                if properNounPhrase.count == 2 { break }
            } else if !properNounPhrase.isEmpty {
                break
            }
        }
        if !properNounPhrase.isEmpty {
            return properNounPhrase.joined(separator: " ")
        }

        guard let meaningfulWord = words.first(where: { word in
            word.count > 3 && !ignoredWords.contains(word.lowercased())
        }) else { return nil }
        return meaningfulWord.prefix(1).uppercased() + meaningfulWord.dropFirst().lowercased()
    }

    private static func uniqueName(_ baseName: String, avoiding existingNames: [String]) -> String {
        let takenNames = Set(existingNames.map { $0.lowercased() })
        guard takenNames.contains(baseName.lowercased()) else { return baseName }
        var suffixNumber = 2
        while takenNames.contains("\(baseName) \(suffixNumber)".lowercased()) {
            suffixNumber += 1
        }
        return "\(baseName) \(suffixNumber)"
    }
}

@MainActor
final class BuddyStore: ObservableObject {
    static let shared = BuddyStore()

    static let defaultBuddiesFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/buddies.json")

    private static let scheduleCheckIntervalSeconds: TimeInterval = 60

    /// Newest first.
    @Published private(set) var buddies: [WispBuddy] = []

    private let buddiesFileURL: URL
    private var scheduleCheckTimer: Timer?

    /// Starts one run for a buddy — its job, or a message the user sent it —
    /// and returns its background task id, or nil when it couldn't start (e.g.
    /// the background-task limit is reached). The run is recorded in the buddy's
    /// thread by whoever starts it. Set by `start(runStarter:)`; the store never
    /// talks to the model itself.
    private var runStarter: ((WispBuddy, BuddyRunRequest) -> UUID?)?

    /// The app uses `shared`, backed by the real file. Tests make their own
    /// store on a temporary file.
    init(buddiesFileURL: URL = BuddyStore.defaultBuddiesFileURL) {
        self.buddiesFileURL = buddiesFileURL
        buddies = loadBuddies()
    }

    // MARK: - Scheduling

    /// Hooks up how runs start and begins the once-a-minute schedule check.
    /// Safe to call more than once.
    func start(runStarter: @escaping (WispBuddy, BuddyRunRequest) -> UUID?) {
        self.runStarter = runStarter
        guard scheduleCheckTimer == nil else { return }
        let timer = Timer(timeInterval: Self.scheduleCheckIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runDueBuddies(now: Date())
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        scheduleCheckTimer = timer
        runDueBuddies(now: Date())
    }

    /// Runs every repeating buddy whose time has come. A buddy already running
    /// is skipped for this slot; one that can't start (the background limit)
    /// keeps its due date and is tried again next minute.
    func runDueBuddies(now: Date) {
        for buddy in buddies {
            guard let nextScheduledRunAt = buddy.nextScheduledRunAt, nextScheduledRunAt <= now else { continue }
            if isRunning(buddy) {
                advanceSchedule(ofBuddyWithID: buddy.id, after: now)
                continue
            }
            if runNow(buddyWithID: buddy.id) {
                advanceSchedule(ofBuddyWithID: buddy.id, after: now)
            }
        }
    }

    private func advanceSchedule(ofBuddyWithID buddyID: UUID, after date: Date) {
        mutateBuddy(withID: buddyID) { buddy in
            buddy.nextScheduledRunAt = buddy.schedule.nextRunDate(after: date, calendar: .current)
        }
    }

    // MARK: - Queries

    func buddy(withID buddyID: UUID) -> WispBuddy? {
        buddies.first { $0.id == buddyID }
    }

    /// The buddy's runs that the registry still holds, oldest first.
    func runRecords(of buddy: WispBuddy, in taskRegistry: AgentTaskRegistry = .shared) -> [AgentTaskRecord] {
        buddy.runTaskIDs.compactMap { runTaskID in
            taskRegistry.records.first { $0.id == runTaskID }
        }
    }

    func isRunning(_ buddy: WispBuddy, in taskRegistry: AgentTaskRegistry = .shared) -> Bool {
        guard let latestRunTaskID = buddy.runTaskIDs.last,
              let latestRunRecord = taskRegistry.records.first(where: { $0.id == latestRunTaskID }) else {
            return false
        }
        return !latestRunRecord.status.isTerminal
    }

    /// The buddy's latest run that the registry still holds.
    func latestRunRecord(of buddy: WispBuddy, in taskRegistry: AgentTaskRegistry = .shared) -> AgentTaskRecord? {
        guard let latestRunTaskID = buddy.runTaskIDs.last else { return nil }
        return taskRegistry.records.first { $0.id == latestRunTaskID }
    }

    /// Whether the buddy finished something the user hasn't seen.
    func isUnread(_ buddy: WispBuddy, in taskRegistry: AgentTaskRegistry = .shared) -> Bool {
        let latestRun = latestRunRecord(of: buddy, in: taskRegistry)
        let latestNewsFinishedAt = latestRun.flatMap { runRecord in
            BuddyListPolicy.isNews(runRecord.status) ? runRecord.finishedAt : nil
        }
        return BuddyListPolicy.isUnread(
            latestFinishedRunAt: latestNewsFinishedAt,
            lastReadAt: buddy.lastReadAt,
            createdAt: buddy.createdAt,
            isMarkedUnread: buddy.isMarkedUnread ?? false
        )
    }

    /// Pinned first, then most recent activity — how every buddy list is ordered.
    func orderedBuddies(in taskRegistry: AgentTaskRegistry = .shared) -> [WispBuddy] {
        BuddyListPolicy.ordered(
            buddies,
            isPinned: \.isPinnedInList,
            lastActivityAt: { buddy in
                self.latestRunRecord(of: buddy, in: taskRegistry)?.startedAt
                    ?? BuddyThreadStore.shared.exchanges(ofBuddyWithID: buddy.id).last?.startedAt
                    ?? buddy.createdAt
            },
            createdAt: \.createdAt
        )
    }

    /// Buddies that are working or have news — what the sidebar badge counts.
    func buddiesNeedingAttentionCount(in taskRegistry: AgentTaskRegistry = .shared) -> Int {
        buddies.filter { isRunning($0, in: taskRegistry) || isUnread($0, in: taskRegistry) }.count
    }

    // MARK: - Changes

    /// Creates a buddy for `instruction`, named from it, in the next colour.
    /// A one-off buddy runs right away; a repeating one waits for its time
    /// unless `runImmediately`.
    @discardableResult
    func createBuddy(
        instruction: String,
        schedule: BuddySchedule,
        modelChoice: BuddyModelChoice? = nil,
        toolAccess: BuddyToolAccess? = nil,
        runImmediately: Bool
    ) -> WispBuddy {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let newBuddy = WispBuddy(
            id: UUID(),
            name: BuddyNameGenerator.name(forInstruction: trimmedInstruction, existingNames: buddies.map(\.name)),
            instruction: trimmedInstruction,
            colorIndex: nextColorIndex(),
            schedule: schedule,
            createdAt: now,
            runTaskIDs: [],
            nextScheduledRunAt: schedule.nextRunDate(after: now, calendar: .current),
            modelChoice: modelChoice,
            toolAccess: toolAccess
        )
        buddies.insert(newBuddy, at: 0)
        saveBuddies()
        if runImmediately || !schedule.isRepeating {
            runNow(buddyWithID: newBuddy.id)
        }
        return newBuddy
    }

    /// Starts a run of the buddy's job now. Returns false when it couldn't start.
    @discardableResult
    func runNow(buddyWithID buddyID: UUID) -> Bool {
        guard let buddy = buddy(withID: buddyID) else { return false }
        return startRun(of: buddy, request: BuddyRunRequest(origin: .job, text: buddy.instruction))
    }

    /// Sends the user's message to the buddy as the next turn of its thread.
    /// Returns false when the buddy is mid-run or the run couldn't start.
    @discardableResult
    func sendMessage(_ messageText: String, toBuddyWithID buddyID: UUID) -> Bool {
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessageText.isEmpty, let buddy = buddy(withID: buddyID) else { return false }
        return startRun(of: buddy, request: BuddyRunRequest(origin: .message, text: trimmedMessageText))
    }

    /// Starts a run of `buddyID` for another buddy's `ask_buddy` request and
    /// returns its task id; nil when the buddy is busy or the queue is full.
    func startDelegatedRun(to buddyID: UUID, message: String, fromBuddyNamed requesterName: String) -> UUID? {
        guard let buddy = buddy(withID: buddyID) else { return nil }
        return startRunReturningTaskID(
            of: buddy,
            request: BuddyRunRequest(origin: .delegated, text: message, requesterName: requesterName)
        )
    }

    private func startRun(of buddy: WispBuddy, request: BuddyRunRequest) -> Bool {
        startRunReturningTaskID(of: buddy, request: request) != nil
    }

    private func startRunReturningTaskID(of buddy: WispBuddy, request: BuddyRunRequest) -> UUID? {
        let buddyID = buddy.id
        guard !isRunning(buddy), let runStarter, let runTaskID = runStarter(buddy, request) else {
            return nil
        }
        mutateBuddy(withID: buddyID) { buddy in
            buddy.runTaskIDs.append(runTaskID)
            if buddy.runTaskIDs.count > WispBuddy.maximumRememberedRuns {
                buddy.runTaskIDs.removeFirst(buddy.runTaskIDs.count - WispBuddy.maximumRememberedRuns)
            }
        }
        return runTaskID
    }

    func stopRun(ofBuddyWithID buddyID: UUID) {
        guard let latestRunTaskID = buddy(withID: buddyID)?.runTaskIDs.last else { return }
        AgentTaskRegistry.shared.cancelTask(latestRunTaskID)
    }

    func rename(buddyWithID buddyID: UUID, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        mutateBuddy(withID: buddyID) { $0.name = trimmedName }
    }

    func updateToolAccess(ofBuddyWithID buddyID: UUID, to newToolAccess: BuddyToolAccess?) {
        mutateBuddy(withID: buddyID) { $0.toolAccess = newToolAccess }
    }

    func updateModelChoice(ofBuddyWithID buddyID: UUID, to newModelChoice: BuddyModelChoice?) {
        mutateBuddy(withID: buddyID) { $0.modelChoice = newModelChoice }
    }

    func updateSchedule(ofBuddyWithID buddyID: UUID, to newSchedule: BuddySchedule) {
        mutateBuddy(withID: buddyID) { buddy in
            buddy.schedule = newSchedule
            buddy.nextScheduledRunAt = newSchedule.nextRunDate(after: Date(), calendar: .current)
        }
    }

    /// The user has the thread open: everything finished so far is seen.
    /// Writes only when something changes, since this runs on every finish.
    func markRead(buddyWithID buddyID: UUID, in taskRegistry: AgentTaskRegistry = .shared) {
        guard let buddy = buddy(withID: buddyID),
              isUnread(buddy, in: taskRegistry) else { return }
        mutateBuddy(withID: buddyID) { buddy in
            buddy.lastReadAt = Date()
            buddy.isMarkedUnread = nil
        }
    }

    func setMarkedUnread(buddyWithID buddyID: UUID, isMarkedUnread: Bool) {
        mutateBuddy(withID: buddyID) { buddy in
            buddy.isMarkedUnread = isMarkedUnread ? true : nil
            if !isMarkedUnread { buddy.lastReadAt = Date() }
        }
    }

    func setPinned(buddyWithID buddyID: UUID, isPinned: Bool) {
        mutateBuddy(withID: buddyID) { $0.isPinned = isPinned ? true : nil }
    }

    func setNotifiesWhenFinished(buddyWithID buddyID: UUID, notifiesWhenFinished: Bool) {
        mutateBuddy(withID: buddyID) { $0.notifiesWhenFinished = notifiesWhenFinished ? nil : false }
    }

    /// Changes the buddy's job. Its thread and notes stay: the next run sees
    /// the new job in its prompt and the earlier exchanges as history.
    func updateInstruction(ofBuddyWithID buddyID: UUID, to newInstruction: String) {
        let trimmedInstruction = newInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else { return }
        mutateBuddy(withID: buddyID) { $0.instruction = trimmedInstruction }
    }

    /// A new buddy with the same job, schedule, model and tools, but a fresh
    /// thread and no notes — the setup is copied, not what it has learned.
    /// It doesn't run until its schedule or the user says so.
    @discardableResult
    func duplicateBuddy(withID buddyID: UUID) -> WispBuddy? {
        guard let originalBuddy = buddy(withID: buddyID) else { return nil }
        let now = Date()
        let duplicatedBuddy = WispBuddy(
            id: UUID(),
            name: BuddyListPolicy.duplicateName(of: originalBuddy.name, existingNames: buddies.map(\.name)),
            instruction: originalBuddy.instruction,
            colorIndex: nextColorIndex(),
            schedule: originalBuddy.schedule,
            createdAt: now,
            runTaskIDs: [],
            nextScheduledRunAt: originalBuddy.schedule.nextRunDate(after: now, calendar: .current),
            modelChoice: originalBuddy.modelChoice,
            toolAccess: originalBuddy.toolAccess,
            notifiesWhenFinished: originalBuddy.notifiesWhenFinished
        )
        buddies.insert(duplicatedBuddy, at: 0)
        saveBuddies()
        return duplicatedBuddy
    }

    /// Starts the buddy's thread over: its next run has no earlier exchanges in
    /// front of it. Its notes (`BuddyMemoryStore`) stay, and every run stays in
    /// History. Stops a run in progress first so its answer doesn't land in the
    /// cleared thread.
    func clearConversation(ofBuddyWithID buddyID: UUID) {
        stopRun(ofBuddyWithID: buddyID)
        BuddyThreadStore.shared.deleteThread(ofBuddyWithID: buddyID)
        mutateBuddy(withID: buddyID) { buddy in
            buddy.runTaskIDs = []
            buddy.isMarkedUnread = nil
            buddy.lastReadAt = Date()
        }
    }

    func deleteBuddy(withID buddyID: UUID) {
        stopRun(ofBuddyWithID: buddyID)
        BuddyThreadStore.shared.deleteThread(ofBuddyWithID: buddyID)
        BuddyMemoryStore.shared.deleteMemory(ofBuddyWithID: buddyID)
        buddies.removeAll { $0.id == buddyID }
        saveBuddies()
    }

    private func mutateBuddy(withID buddyID: UUID, _ mutate: (inout WispBuddy) -> Void) {
        guard let buddyIndex = buddies.firstIndex(where: { $0.id == buddyID }) else { return }
        mutate(&buddies[buddyIndex])
        saveBuddies()
    }

    /// The least-used palette colour, so a handful of buddies all look different.
    func nextColorIndex() -> Int {
        let paletteCount = BuddyAppearance.paletteCount
        let usageCountByColorIndex = Dictionary(grouping: buddies, by: { $0.colorIndex % paletteCount })
            .mapValues(\.count)
        return (0..<paletteCount).min { firstColorIndex, secondColorIndex in
            (usageCountByColorIndex[firstColorIndex] ?? 0, firstColorIndex)
                < (usageCountByColorIndex[secondColorIndex] ?? 0, secondColorIndex)
        } ?? 0
    }

    // MARK: - Persistence

    private func loadBuddies() -> [WispBuddy] {
        guard let fileData = try? Data(contentsOf: buddiesFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WispBuddy].self, from: fileData)) ?? []
    }

    private func saveBuddies() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let fileData = try? encoder.encode(buddies) else { return }
        try? FileManager.default.createDirectory(
            at: buddiesFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileData.write(to: buddiesFileURL, options: .atomic)
    }
}
