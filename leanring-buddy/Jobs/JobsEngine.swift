//
//  JobsEngine.swift
//  leanring-buddy
//
//  The one main-actor object the Jobs window page and the notch read. It owns the
//  schedule (launch sync, then at most hourly; one checklist rebuild per morning)
//  and glues the pure pieces together: feed -> diff -> "Wisp" calendar -> study
//  block proposals -> daily checklist -> "Wisp Today" reminders.
//
//  No model call anywhere on this path. Everything outside Foundation is behind the
//  small protocols below so Tests/JobsEngine can drive the whole flow with fakes;
//  the real adapters (Keychain, EventKit actors, confirmation coordinator,
//  notifications) live in JobsEngineLiveDependencies.swift.
//
//  The Canvas feed URL is a secret: nothing here ever holds it, logs it or puts it
//  in an error message. Only the feed store reads it, from the Keychain.
//

import Combine
import Foundation

// MARK: - Tool name

nonisolated enum JobsToolNames {
    /// The name the study-block approval is asked under. It is on
    /// `ToolCallSafety.alwaysAskBareToolNames`, so session auto-approve can never
    /// skip it: writing to the user's calendar is always their call.
    static let applyStudyBlocks = "wisp_jobs_apply_study_blocks"
}

// MARK: - Dependencies (injectable so tests need no Keychain, network or EventKit)
//
// Marked `nonisolated` because the app builds with main-actor default isolation and
// the real conformers are actors / plain structs that must not be pinned to main.

nonisolated protocol JobsFeedProviding: Sendable {
    func fetchCurrentItems(now: Date, calendar: Calendar) async throws -> [CanvasItem]
    func loadSnapshot() async -> CanvasSnapshot?
    func saveSnapshot(_ snapshot: CanvasSnapshot) async throws
    func clearSnapshot() async
}

/// The Keychain side of the feed link, kept apart from fetching.
nonisolated protocol JobsFeedConfiguring: Sendable {
    func hasFeedURL() -> Bool
    func saveFeedURL(_ feedURL: URL) throws
    func deleteFeedURL()
}

nonisolated protocol JobsCalendarWriting: Sendable {
    func authorizationState() async -> JobsAccessState
    func requestAccessIfNeeded() async throws
    func ensureWispCalendarExists() async throws
    func apply(diff: CanvasDiff) async throws -> (created: Int, updated: Int, deleted: Int)
    func writeStudyBlocks(_ proposals: [StudyBlockProposal]) async throws -> Int
    func busyIntervals(from startDate: Date, to endDate: Date) async throws -> [BusyInterval]
    func calendarEvents(onDay day: Date, calendar: Calendar) async throws -> [ChecklistCalendarEvent]
}

nonisolated protocol JobsReminderWriting: Sendable {
    func authorizationState() async -> JobsAccessState
    func requestAccessIfNeeded() async throws
    func rebuild(with items: [ChecklistItem]) async throws
    func readBackCompletion() async throws -> [String: (isCompleted: Bool, completionDate: Date?)]
    func setCompleted(itemID: String, isCompleted: Bool) async throws
}

/// Shows the single approval card for a batch of study blocks and says whether the
/// user allowed it.
nonisolated protocol JobsStudyBlockApproving: Sendable {
    func askToWriteStudyBlocks(_ proposals: [StudyBlockProposal]) async -> Bool
}

/// The "something changed" moment: a notification (unless quiet mode is on) and the
/// island's success flash. Only ever called with a non-empty diff.
nonisolated protocol JobsChangeAnnouncing: Sendable {
    func announceCanvasChange(title: String, body: String) async
}

struct JobsEngineDependencies {
    var feed: any JobsFeedProviding
    var feedConfiguration: any JobsFeedConfiguring
    var calendarWriter: any JobsCalendarWriting
    var reminders: any JobsReminderWriting
    var studyBlockApprover: any JobsStudyBlockApproving
    var announcer: any JobsChangeAnnouncing
    var userDefaults: UserDefaults
    var stateFileURL: URL
    var now: @Sendable () -> Date
    var calendar: Calendar
}

/// A sync refused by Wisp's own sanity checks (not a network or EventKit failure).
nonisolated enum JobsSyncGuardError: Error, Equatable, Sendable {
    case emptyFeedOverExistingItems
}

// MARK: - Persisted state

/// What has to survive a relaunch besides the flags in UserDefaults. Kept in a 0600
/// JSON file because it holds the user's own assignment and event titles.
nonisolated struct JobsPersistedState: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` of the day `checklist` was built for.
    var checklistDayKey: String?
    var checklist: [ChecklistItem] = []
    /// The list from before `checklistDayKey`: the rollover source. Kept so a
    /// same-day "Rebuild today" rolls the same items once, not twice.
    var previousDayChecklist: [ChecklistItem] = []
    var approvedStudyBlocks: [StudyBlockProposal] = []
    /// Proposal ids already approved or dismissed, so they are never proposed again.
    var handledStudyBlockIDs: [String] = []
}

// MARK: - Engine

@MainActor
final class JobsEngine: ObservableObject {

    enum SyncState: Equatable {
        case notConfigured
        case idle
        case syncing
        /// Never contains the feed URL.
        case failed(message: String)
    }

    // MARK: Published state

    @Published private(set) var syncState: SyncState
    @Published private(set) var lastSyncedAt: Date?
    /// The last non-empty diff; nil once dismissed.
    @Published private(set) var latestDiff: CanvasDiff?
    @Published private(set) var pendingStudyBlocks: [StudyBlockProposal] = []
    @Published private(set) var todayChecklist: [ChecklistItem] = []
    @Published private(set) var calendarAccess: JobsAccessState = .notDetermined
    @Published private(set) var remindersAccess: JobsAccessState = .notDetermined
    @Published private(set) var itemCountInFeed: Int = 0
    /// A short, URL-free note about the last study-block or checklist action that
    /// failed, for the Jobs page to show. Cleared on the next success.
    @Published private(set) var lastActionProblemMessage: String?

    @Published var isCanvasJobEnabled: Bool {
        didSet { dependencies.userDefaults.set(isCanvasJobEnabled, forKey: Self.canvasJobEnabledKey) }
    }
    @Published var isDailyChecklistEnabled: Bool {
        didSet { dependencies.userDefaults.set(isDailyChecklistEnabled, forKey: Self.dailyChecklistEnabledKey) }
    }
    @Published var studyBlockSettings: StudyBlockSettings {
        didSet {
            if let encodedSettings = try? JSONEncoder().encode(studyBlockSettings) {
                dependencies.userDefaults.set(encodedSettings, forKey: Self.studyBlockSettingsKey)
            }
        }
    }

    var hasChecklist: Bool { !todayChecklist.isEmpty && isDailyChecklistEnabled }
    /// Study blocks the user approved (already in the "Wisp" calendar). Read by Chrome focus
    /// mode, which can start when one begins.
    var approvedStudyBlocks: [StudyBlockProposal] { persistedState.approvedStudyBlocks }
    var hasCanvasFeed: Bool { dependencies.feedConfiguration.hasFeedURL() }

    // MARK: Constants

    static let canvasJobEnabledKey = "wisp.jobs.canvas.enabled"
    static let dailyChecklistEnabledKey = "wisp.jobs.checklist.enabled"
    static let studyBlockSettingsKey = "wisp.jobs.studyBlocks.settings"
    static let lastBuiltDayKey = "wisp.jobs.checklist.lastBuiltDay"
    static let lastSyncedAtKey = "wisp.jobs.canvas.lastSyncedAt"

    /// Even the Sync now button will not hit the school's server more often than this.
    static let minimumSecondsBetweenSyncs: TimeInterval = 15 * 60
    static let scheduledSyncIntervalSeconds: TimeInterval = 60 * 60
    static let maximumChecklistItems = 12
    /// Same window as `MorningBriefingSchedule`: a checklist built at 9pm is stale.
    static let morningWindowHours = 5..<17
    private static let maximumRememberedHandledIDs = 500
    private static let studyBlockLookaheadPaddingDays = 1

    // MARK: Private state

    private let dependencies: JobsEngineDependencies
    private var persistedState: JobsPersistedState
    private var clockTimer: Timer?
    private var hasStarted = false
    private var lastSyncAttemptAt: Date?
    private var lastSyncAttemptFailed = false
    private var isSyncing = false
    /// Bumped whenever the feed link is replaced or removed. A sync that started under an
    /// older value is for a feed that no longer exists, so it must not write anything back.
    private var feedGeneration = 0
    private var isRebuildingChecklist = false
    private var storeChangeObserver: NSObjectProtocol?
    private var pendingCompletionRefreshTask: Task<Void, Never>?

    init(dependencies: JobsEngineDependencies) {
        self.dependencies = dependencies
        let defaults = dependencies.userDefaults

        // The Canvas job is on by default once a feed exists; the checklist is on by default.
        isCanvasJobEnabled = defaults.object(forKey: Self.canvasJobEnabledKey) as? Bool ?? true
        isDailyChecklistEnabled = defaults.object(forKey: Self.dailyChecklistEnabledKey) as? Bool ?? true
        if let storedSettingsData = defaults.data(forKey: Self.studyBlockSettingsKey),
           let storedSettings = try? JSONDecoder().decode(StudyBlockSettings.self, from: storedSettingsData) {
            studyBlockSettings = storedSettings
        } else {
            studyBlockSettings = .default
        }
        if let storedLastSyncedAt = defaults.object(forKey: Self.lastSyncedAtKey) as? Date {
            lastSyncedAt = storedLastSyncedAt
        }

        persistedState = JobsPrivateJSONFile.load(JobsPersistedState.self, from: dependencies.stateFileURL)
            ?? JobsPersistedState()
        syncState = dependencies.feedConfiguration.hasFeedURL() ? .idle : .notConfigured

        // Only today's list is shown; an older one is kept as the rollover source.
        let todayKey = DayChecklistBuilder.dayKey(for: dependencies.now(), calendar: dependencies.calendar)
        if persistedState.checklistDayKey == todayKey {
            todayChecklist = persistedState.checklist
        }
    }

    // MARK: - Lifecycle

    /// Syncs once now, then checks every 60s whether an hourly sync or the morning
    /// checklist is due. A plain `Timer` like `BuddyStore.start`, not a model task.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let clockTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.clockTick() }
        }
        clockTimer.tolerance = 10
        RunLoop.main.add(clockTimer, forMode: .common)
        self.clockTimer = clockTimer

        // Reminders is the source of truth for ticks, so a tick made in the Reminders
        // app shows up in the notch. The writes this engine makes also post this
        // notification, which is harmless: the refresh only reads.
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("EKEventStoreChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDebouncedCompletionRefresh() }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshAccessStates()
            await self.syncNow()
            await self.buildChecklistIfDue()
        }
    }

    private func clockTick() async {
        let now = dependencies.now()
        if isCanvasJobEnabled, hasCanvasFeed {
            let secondsSinceLastAttempt = lastSyncAttemptAt.map { now.timeIntervalSince($0) } ?? .infinity
            if secondsSinceLastAttempt >= Self.scheduledSyncIntervalSeconds {
                await syncNow()
            }
        }
        await buildChecklistIfDue()
    }

    private func scheduleDebouncedCompletionRefresh() {
        pendingCompletionRefreshTask?.cancel()
        pendingCompletionRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshChecklistCompletion()
        }
    }

    // MARK: - Canvas setup

    func saveCanvasFeed(urlText: String) -> Result<Void, CanvasFeedURLValidationError> {
        switch CanvasFeedURLValidator.validate(urlText) {
        case .failure(let validationError):
            return .failure(validationError)
        case .success(let validatedFeedURL):
            do {
                try dependencies.feedConfiguration.saveFeedURL(validatedFeedURL)
            } catch {
                // The Keychain refused. `CanvasFeedURLValidationError` has no case for
                // that, so the page gets a generic failure and the reason goes here.
                // The previous link (if any) is untouched, so the sync state is left alone.
                lastActionProblemMessage = "Wisp couldn't save the link to your Keychain."
                return .failure(.couldNotSaveToKeychain)
            }
            isCanvasJobEnabled = true
            // A new link starts fresh: no throttle, no old snapshot to diff against.
            feedGeneration += 1
            let feedGenerationOfThisLink = feedGeneration
            lastSyncAttemptAt = nil
            lastSyncAttemptFailed = false
            lastSyncedAt = nil
            syncState = .idle
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.dependencies.feed.clearSnapshot()
                // A sync for the old link may still be running; it discards itself, but
                // `syncNow` would refuse to start while it is, so wait for it to finish.
                while self.isSyncing {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                // Another save or a removal since then owns what happens next.
                guard self.feedGeneration == feedGenerationOfThisLink else { return }
                await self.syncNow()
            }
            return .success(())
        }
    }

    /// Deletes the Keychain URL and the snapshot. Events already in the "Wisp"
    /// calendar are left alone: they are the user's now.
    func removeCanvasFeed() {
        feedGeneration += 1
        dependencies.feedConfiguration.deleteFeedURL()
        latestDiff = nil
        pendingStudyBlocks = []
        itemCountInFeed = 0
        lastSyncedAt = nil
        dependencies.userDefaults.removeObject(forKey: Self.lastSyncedAtKey)
        syncState = .notConfigured
        Task { await dependencies.feed.clearSnapshot() }
    }

    /// The only place Calendar and Reminders permission is requested: an explicit
    /// button on the Jobs page, never at launch.
    func requestCalendarAndRemindersAccess() async {
        try? await dependencies.calendarWriter.requestAccessIfNeeded()
        try? await dependencies.reminders.requestAccessIfNeeded()
        await refreshAccessStates()
        if calendarAccess == .granted {
            try? await dependencies.calendarWriter.ensureWispCalendarExists()
        }
        if hasCanvasFeed, isCanvasJobEnabled {
            // Access just arrived, so whatever was fetched before was never written.
            lastSyncAttemptAt = nil
            lastSyncedAt = nil
            await syncNow()
        }
        await buildChecklistIfDue()
    }

    private func refreshAccessStates() async {
        calendarAccess = await dependencies.calendarWriter.authorizationState()
        remindersAccess = await dependencies.reminders.authorizationState()
    }

    // MARK: - Sync

    func syncNow() async {
        guard !isSyncing else { return }
        guard hasCanvasFeed, isCanvasJobEnabled else {
            if !hasCanvasFeed { syncState = .notConfigured }
            return
        }

        let now = dependencies.now()
        // The 15 minute floor applies after a success; a failed attempt may be retried.
        if !lastSyncAttemptFailed, let lastAttempt = lastSyncAttemptAt,
           now.timeIntervalSince(lastAttempt) < Self.minimumSecondsBetweenSyncs {
            return
        }

        isSyncing = true
        syncState = .syncing
        lastSyncAttemptAt = now
        let feedGenerationAtStart = feedGeneration
        defer { isSyncing = false }

        do {
            try await performSync(now: now, feedGenerationAtStart: feedGenerationAtStart)
            // A link replaced or removed mid-sync already set the state it wants.
            if feedGenerationAtStart == feedGeneration {
                lastSyncAttemptFailed = false
                syncState = .idle
            }
        } catch {
            if feedGenerationAtStart == feedGeneration {
                lastSyncAttemptFailed = true
                // The previous snapshot is untouched: it is only saved after every write succeeded.
                syncState = .failed(message: Self.safeMessage(for: error))
            }
        }
    }

    private func performSync(now: Date, feedGenerationAtStart: Int) async throws {
        let calendar = dependencies.calendar
        let currentItems = try await dependencies.feed.fetchCurrentItems(now: now, calendar: calendar)
        let previousSnapshot = await dependencies.feed.loadSnapshot()
        guard feedGenerationAtStart == feedGeneration else { return }

        // A valid but empty calendar over a non-empty snapshot is far more likely a reset
        // link or a backend hiccup than every assignment vanishing; diffing it would delete
        // every mirrored event. Keep what is there and say so.
        if currentItems.isEmpty, let previousItems = previousSnapshot?.items, !previousItems.isEmpty {
            throw JobsSyncGuardError.emptyFeedOverExistingItems
        }
        itemCountInFeed = currentItems.count

        await refreshAccessStates()
        guard calendarAccess == .granted else {
            // Without calendar access nothing can be written, and saving the snapshot
            // would make a later grant look like "nothing changed". So no snapshot, no
            // diff card; the page shows the access prompt instead.
            return
        }

        let canvasDiff = CanvasSyncPlanner.diff(previous: previousSnapshot?.items, current: currentItems)
        try await dependencies.calendarWriter.ensureWispCalendarExists()
        if !canvasDiff.isEmpty {
            _ = try await dependencies.calendarWriter.apply(diff: canvasDiff)
        }
        // The feed was removed or replaced during the writes: save no snapshot for it.
        guard feedGenerationAtStart == feedGeneration else { return }
        let sortedItems = currentItems.sorted { ($0.startDate, $0.uid) < ($1.startDate, $1.uid) }
        try await dependencies.feed.saveSnapshot(CanvasSnapshot(fetchedAt: now, items: sortedItems))
        guard feedGenerationAtStart == feedGeneration else {
            // The removal's own clear may have run before this save landed.
            await dependencies.feed.clearSnapshot()
            return
        }

        lastSyncedAt = now
        dependencies.userDefaults.set(now, forKey: Self.lastSyncedAtKey)

        if !canvasDiff.isEmpty {
            latestDiff = canvasDiff
            let title = "Canvas calendar updated"
            let body = canvasDiff.isFirstSync
                ? "Added \(canvasDiff.added.count) Canvas items to Wisp"
                : canvasDiff.summaryLine
            await dependencies.announcer.announceCanvasChange(title: title, body: body)
        }

        await proposeStudyBlocks(for: currentItems, now: now)
        await refreshChecklistCompletion()
    }

    // MARK: - Study blocks

    private func proposeStudyBlocks(for items: [CanvasItem], now: Date) async {
        guard studyBlockSettings.isEnabled else {
            pendingStudyBlocks = []
            return
        }
        let calendar = dependencies.calendar
        let lookaheadEnd = calendar.date(
            byAdding: .day,
            value: studyBlockSettings.lookaheadDays + Self.studyBlockLookaheadPaddingDays,
            to: now
        ) ?? now.addingTimeInterval(8 * 24 * 3600)
        var busyIntervals = (try? await dependencies.calendarWriter.busyIntervals(from: now, to: lookaheadEnd)) ?? []
        // The calendar writer leaves the "Wisp" calendar out of busy time, so blocks the
        // user already approved are added here or another item could take the same slot.
        busyIntervals.append(contentsOf: persistedState.approvedStudyBlocks.map {
            BusyInterval(start: $0.start, end: $0.end)
        })
        pendingStudyBlocks = StudyBlockPlanner.propose(
            items: items,
            busyIntervals: busyIntervals,
            alreadyProposedOrCreatedIDs: Set(persistedState.handledStudyBlockIDs),
            settings: studyBlockSettings,
            now: now,
            calendar: calendar
        )
    }

    func dismissLatestDiff() {
        latestDiff = nil
    }

    /// One confirmation card for the whole batch, then a write to "Wisp" only.
    func approvePendingStudyBlocks() async {
        let proposalsToWrite = pendingStudyBlocks
        guard !proposalsToWrite.isEmpty else { return }

        guard await dependencies.studyBlockApprover.askToWriteStudyBlocks(proposalsToWrite) else {
            // Declined or timed out: they stay pending so the user can try again.
            return
        }
        do {
            _ = try await dependencies.calendarWriter.writeStudyBlocks(proposalsToWrite)
        } catch {
            lastActionProblemMessage = "Wisp couldn't add the study blocks to your calendar."
            return
        }
        lastActionProblemMessage = nil

        let writtenIDs = Set(proposalsToWrite.map(\.id))
        persistedState.approvedStudyBlocks.append(contentsOf: proposalsToWrite)
        rememberHandledStudyBlockIDs(writtenIDs)
        pendingStudyBlocks.removeAll { writtenIDs.contains($0.id) }
        persistState()

        // A block approved for today belongs on today's checklist.
        let blockStartsToday = proposalsToWrite.contains {
            dependencies.calendar.isDate($0.start, inSameDayAs: dependencies.now())
        }
        if blockStartsToday, isDailyChecklistEnabled, !todayChecklist.isEmpty {
            await rebuildChecklistNow()
        }
    }

    /// Remembers the ids so the same blocks are not proposed again tomorrow.
    func dismissPendingStudyBlocks() {
        rememberHandledStudyBlockIDs(Set(pendingStudyBlocks.map(\.id)))
        pendingStudyBlocks = []
        persistState()
    }

    private func rememberHandledStudyBlockIDs(_ newIDs: Set<String>) {
        var knownIDs = persistedState.handledStudyBlockIDs
        for newID in newIDs.sorted() where !knownIDs.contains(newID) { knownIDs.append(newID) }
        if knownIDs.count > Self.maximumRememberedHandledIDs {
            knownIDs.removeFirst(knownIDs.count - Self.maximumRememberedHandledIDs)
        }
        persistedState.handledStudyBlockIDs = knownIDs
    }

    // MARK: - Checklist

    /// Builds today's list if it is the morning window and it has not been built today.
    func buildChecklistIfDue() async {
        guard isDailyChecklistEnabled else { return }
        let now = dependencies.now()
        let calendar = dependencies.calendar
        guard Self.morningWindowHours.contains(calendar.component(.hour, from: now)) else { return }
        let todayKey = DayChecklistBuilder.dayKey(for: now, calendar: calendar)
        guard dependencies.userDefaults.string(forKey: Self.lastBuiltDayKey) != todayKey else { return }
        await rebuildChecklistNow()
    }

    /// The "Rebuild today" button. Also what the morning build calls.
    func rebuildChecklistNow() async {
        guard isDailyChecklistEnabled, !isRebuildingChecklist else { return }
        isRebuildingChecklist = true
        defer { isRebuildingChecklist = false }

        let now = dependencies.now()
        let calendar = dependencies.calendar
        let todayKey = DayChecklistBuilder.dayKey(for: now, calendar: calendar)

        // Reminders is the source of truth for ticks: merge them in before deciding
        // what is unfinished.
        await refreshAccessStates()
        var storedChecklist = persistedState.checklist
        if remindersAccess == .granted,
           let readBack = try? await dependencies.reminders.readBackCompletion() {
            storedChecklist = DayChecklistBuilder.applyingCompletion(readBack, to: storedChecklist)
        }

        // `build` must be handed the list from *before* today, or a second build on
        // the same day would roll items over twice.
        var previousChecklist: [ChecklistItem]
        var completedRolledOverItemsToKeep: [ChecklistItem] = []
        if let storedDayKey = persistedState.checklistDayKey, storedDayKey != todayKey {
            persistedState.previousDayChecklist = storedChecklist
            previousChecklist = storedChecklist
        } else {
            // Ticks already made today are kept; today's unfinished items are
            // deliberately not passed or they would roll over.
            let completedTodayItems = storedChecklist.filter(\.isCompleted)
            // A rolled-over item ticked today keeps its id from the earlier day, so the
            // earlier unfinished copy must go or the builder would revive it unticked.
            let completedTodayItemIDs = Set(completedTodayItems.map(\.id))
            previousChecklist = persistedState.previousDayChecklist.filter { !completedTodayItemIDs.contains($0.id) }
            previousChecklist.append(contentsOf: completedTodayItems)
            completedRolledOverItemsToKeep = completedTodayItems.filter { $0.origin == .rolledOver }
        }

        let canvasItems = await dependencies.feed.loadSnapshot()?.items ?? []
        var calendarEvents: [ChecklistCalendarEvent] = []
        if calendarAccess == .granted {
            calendarEvents = (try? await dependencies.calendarWriter.calendarEvents(onDay: now, calendar: calendar)) ?? []
        }

        let builtChecklist = DayChecklistBuilder.build(
            day: now,
            canvasItems: canvasItems,
            calendarEvents: calendarEvents,
            approvedStudyBlocks: persistedState.approvedStudyBlocks,
            previousChecklist: previousChecklist,
            completedRolledOverItemsToKeep: completedRolledOverItemsToKeep,
            maximumItems: Self.maximumChecklistItems,
            now: now,
            calendar: calendar
        )

        if remindersAccess == .granted {
            do {
                try await dependencies.reminders.rebuild(with: builtChecklist)
                lastActionProblemMessage = nil
            } catch {
                // Degrade to the in-memory list rather than showing nothing.
                lastActionProblemMessage = "Wisp couldn't update your Wisp Today reminders list."
            }
        }

        todayChecklist = builtChecklist
        persistedState.checklistDayKey = todayKey
        persistedState.checklist = builtChecklist
        persistState()
        dependencies.userDefaults.set(todayKey, forKey: Self.lastBuiltDayKey)
    }

    /// Optimistic: the tick shows at once, Reminders is written, and a failed write
    /// puts it back.
    func setChecklistItem(id: String, isCompleted: Bool) async {
        guard let itemIndex = todayChecklist.firstIndex(where: { $0.id == id }) else { return }
        let originalItem = todayChecklist[itemIndex]
        guard originalItem.isCompleted != isCompleted else { return }

        todayChecklist[itemIndex].isCompleted = isCompleted
        todayChecklist[itemIndex].completionDate = isCompleted ? dependencies.now() : nil

        await refreshAccessStates()
        if remindersAccess == .granted {
            do {
                try await dependencies.reminders.setCompleted(itemID: id, isCompleted: isCompleted)
            } catch {
                // The list or the reminder is gone (the user deleted it). Recreate today's
                // list from the in-memory checklist, which already holds this tick.
                let reminderWasMissing = (error as? WispEventKitError).map { $0 == .itemMissing || $0 == .calendarMissing } ?? false
                let recreatedReminders: Bool
                if reminderWasMissing {
                    recreatedReminders = (try? await dependencies.reminders.rebuild(with: todayChecklist)) != nil
                } else {
                    recreatedReminders = false
                }
                if !recreatedReminders {
                    if let revertIndex = todayChecklist.firstIndex(where: { $0.id == id }) {
                        todayChecklist[revertIndex] = originalItem
                    }
                    lastActionProblemMessage = "Wisp couldn't update that reminder."
                    return
                }
            }
        }
        lastActionProblemMessage = nil
        persistedState.checklist = todayChecklist
        persistState()
    }

    /// Reads ticks made in Reminders back into the list (on notch open, after a
    /// sync, and when the event store changes).
    func refreshChecklistCompletion() async {
        guard isDailyChecklistEnabled, !todayChecklist.isEmpty else { return }
        remindersAccess = await dependencies.reminders.authorizationState()
        guard remindersAccess == .granted else { return }
        guard let readBack = try? await dependencies.reminders.readBackCompletion() else { return }

        let mergedChecklist = DayChecklistBuilder.applyingCompletion(readBack, to: todayChecklist)
        guard mergedChecklist != todayChecklist else { return }
        todayChecklist = mergedChecklist
        persistedState.checklist = mergedChecklist
        persistState()
    }

    // MARK: - Helpers

    private func persistState() {
        // Study blocks older than two days no longer matter to any checklist.
        let cutoffDate = dependencies.now().addingTimeInterval(-2 * 24 * 3600)
        persistedState.approvedStudyBlocks.removeAll { $0.end < cutoffDate }
        try? JobsPrivateJSONFile.save(persistedState, to: dependencies.stateFileURL)
    }

    /// Error text safe to show: the fetch errors already avoid the URL; anything else
    /// gets a fixed sentence rather than `localizedDescription`, which could echo it.
    nonisolated static func safeMessage(for error: Error) -> String {
        if let fetchError = error as? CanvasFeedFetchError {
            return fetchError.errorDescription ?? "Wisp couldn't read your Canvas feed."
        }
        if error is JobsSyncGuardError {
            return "Your Canvas feed came back empty, so Wisp kept your existing calendar items. It will check again later."
        }
        if let eventKitError = error as? WispEventKitError {
            switch eventKitError {
            case .accessDenied:
                return "Wisp needs Calendar access to keep your Canvas dates up to date."
            case .noWritableSource:
                return "Wisp couldn't find a calendar account it can write to."
            case .calendarMissing, .itemMissing:
                return "Wisp couldn't find its calendar. Try syncing again."
            }
        }
        return "Wisp couldn't finish syncing your Canvas feed."
    }
}
