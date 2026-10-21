//
//  AutomationLiveWiring.swift
//  leanring-buddy
//
//  The real adapters behind `AutomationEngineDependencies`: the model (through
//  `CompanionManager.startAutomationRun`), EventKit, notifications, the notch, JobsEngine and the
//  screen watchers. Kept out of AutomationEngine.swift so Tests/AutomationEngine can compile the
//  engine alone.
//
//  Reading is fine for an unattended run (source data, calendar, reminders) but it never opens
//  a permission prompt on its own: a missing permission is reported as a reason instead.
//

import AppKit
import Combine
import EventKit
import Foundation
import UserNotifications

extension AutomationEngine {
    /// Wires the live adapters. Called once from `CompanionManager.start()`.
    func configureLive(companionManager: CompanionManager) {
        // An automation saved without an owner belongs to the day's buddy, else the Planner.
        AutomationStore.shared.defaultBuddyIDProvider = {
            BuddyStore.shared.dayBuddy(on: Date())?.id
                ?? BuddyStore.shared.buddy(withID: StarterBuddyDefinition.plannerBuddyID)?.id
        }
        setDependencies(LiveAutomationDependencies(companionManager: companionManager))
        migrationHook = { AutomationMigrationRunner.migrateIfNeeded() }
        // Started on the next main-actor turn: `CompanionManager.start()` has not finished
        // wiring `ScreenWatcherStore.onWatcherEnded` yet, and the screen-text watches chain onto it.
        Task { @MainActor [weak self] in self?.start() }
    }
}

// MARK: - Reminders

/// Writes an automation's checklist into a Reminders list whose name starts with "Wisp". It
/// creates that list if missing, adds only items that are not already there, and never touches
/// another list. The "Wisp Today" list is also JobsEngine's; its own reminders are tracked by
/// id there and are left alone here.
actor AutomationRemindersWriter {
    static let shared = AutomationRemindersWriter()

    private let eventStore = EKEventStore()

    func writeChecklist(listTitle: String, titles: [String], mayAskForAccess: Bool) async -> AutomationOutputWriteResult {
        guard listTitle.hasPrefix("Wisp") else { return .failed("Reminders lists must start with \"Wisp\".") }

        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            break
        case .notDetermined:
            guard mayAskForAccess, (try? await eventStore.requestFullAccessToReminders()) == true else {
                return .failed("Reminders access isn't on yet. Run it once yourself to allow it.")
            }
        default:
            return .failed("Reminders access is off. Turn it on in System Settings > Privacy.")
        }

        let targetList: EKCalendar
        if let existingList = eventStore.calendars(for: .reminder).first(where: { $0.title == listTitle && $0.allowsContentModifications }) {
            targetList = existingList
        } else {
            guard let reminderSource = eventStore.defaultCalendarForNewReminders()?.source
                    ?? eventStore.sources.first(where: { $0.sourceType == .local }) else {
                return .failed("Reminders has nowhere to put a new list.")
            }
            let newList = EKCalendar(for: .reminder, eventStore: eventStore)
            newList.title = listTitle
            newList.source = reminderSource
            do {
                try eventStore.saveCalendar(newList, commit: true)
            } catch {
                return .failed("Wisp couldn't create the \(listTitle) list.")
            }
            targetList = newList
        }

        let incompletePredicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: [targetList]
        )
        let existingTitles: Set<String> = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: incompletePredicate) { reminders in
                continuation.resume(returning: Set((reminders ?? []).compactMap { $0.title?.lowercased() }))
            }
        }

        var addedCount = 0
        let todayComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        for title in titles where !existingTitles.contains(title.lowercased()) {
            let reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = targetList
            reminder.title = title
            reminder.dueDateComponents = todayComponents
            reminder.notes = "Added by a Wisp automation."
            do {
                try eventStore.save(reminder, commit: false)
                addedCount += 1
            } catch {
                return .failed("Wisp couldn't add that to Reminders.")
            }
        }
        do {
            if addedCount > 0 { try eventStore.commit() }
        } catch {
            return .failed("Wisp couldn't save to Reminders.")
        }
        return .written(addedCount)
    }
}

// MARK: - Live dependencies

@MainActor
final class LiveAutomationDependencies: AutomationEngineDependencies {
    private weak var companionManager: CompanionManager?

    /// Screen watches started for automations: how to call back when each one ends.
    private var ownedWatchCallbacksByWatcherID: [UUID: @MainActor () -> Void] = [:]
    private var sharedWatchCallbacksByWatcherID: [UUID: @MainActor () -> Void] = [:]
    private var hasChainedWatcherEndedHandler = false

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    var currentDate: Date { Date() }
    var calendar: Calendar { .current }
    var isSettledAfterWake: Bool { SystemReadinessMonitor.shared.isSettledAfterWake() }
    var isNetworkReachable: Bool { SystemReadinessMonitor.shared.isNetworkReachable }
    var isVoiceModeOn: Bool { VoiceOutputPreference.shared.isReplySpeechEnabled }

    // MARK: Buddies and the model

    /// Always a descriptor: with no buddy (or a deleted one) the run uses Wisp's own model, and
    /// whether that model is a cloud one still decides what data it may be given.
    func buddyDescriptor(forBuddyID buddyID: UUID?) -> AutomationBuddyDescriptor? {
        let buddy = buddyID.flatMap { BuddyStore.shared.buddy(withID: $0) }
        return AutomationBuddyDescriptor(
            id: buddy?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            name: buddy?.name ?? "Wisp",
            sendsDataOffThisMachine: companionManager?.automationRunSendsDataOffThisMachine(buddy: buddy) ?? true
        )
    }

    func canStartModelRun(for buddy: AutomationBuddyDescriptor?) -> Bool {
        BackgroundTaskLauncher.canStartAnotherTask(runsOffThisMachine: buddy?.sendsDataOffThisMachine ?? false)
    }

    func resolveInstruction(_ instruction: String, parameterValues: [String: String]?) -> String {
        let parameters = RoutineParameters.parameters(in: instruction)
        let clipboardText = RoutineParameters.usesClipboard(instruction) ? NSPasteboard.general.string(forType: .string) : nil
        return RoutineParameters.resolve(
            instruction: instruction,
            values: RoutineParameters.initialValues(for: parameters, lastValues: parameterValues),
            clipboardText: clipboardText
        )
    }

    func runModel(_ request: AutomationModelRunRequest) async -> AutomationModelRunResult {
        guard let companionManager else { return .failed(reason: "Wisp is shutting down.", taskID: nil) }
        let buddy = request.automation.buddyID.flatMap { BuddyStore.shared.buddy(withID: $0) }

        var answerFromCallback: String?
        guard let taskID = companionManager.startAutomationRun(
            automation: request.automation,
            buddy: buddy,
            resolvedInstruction: request.prompt,
            isUnattended: request.isUnattended,
            onSucceeded: { _, answerText in answerFromCallback = answerText }
        ) else { return .couldNotStart }

        // The run is an ordinary background task; wait for it to reach an end state.
        let giveUpAt = Date().addingTimeInterval(10 * 60)
        while true {
            if Task.isCancelled {
                AgentTaskRegistry.shared.cancelTask(taskID)
                return .failed(reason: "Cancelled.", taskID: taskID)
            }
            guard let record = AgentTaskRegistry.shared.records.first(where: { $0.id == taskID }) else {
                return .failed(reason: "The run disappeared from History.", taskID: taskID)
            }
            switch record.status {
            case .succeeded:
                return .succeeded(text: record.finalText ?? answerFromCallback ?? "", taskID: taskID)
            case .failed(let message):
                return .failed(reason: message, taskID: taskID)
            case .cancelled:
                return .failed(reason: "Cancelled.", taskID: taskID)
            case .interrupted:
                return .failed(reason: "Wisp quit before this finished.", taskID: taskID)
            case .running, .waitingForApproval:
                break
            }
            if Date() > giveUpAt {
                AgentTaskRegistry.shared.cancelTask(taskID)
                return .failed(reason: "It took too long, so Wisp stopped it.", taskID: taskID)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func previewModel(_ request: AutomationModelRunRequest) async -> AutomationModelRunResult {
        guard let companionManager else { return .failed(reason: "Wisp is shutting down.", taskID: nil) }
        let buddy = request.automation.buddyID.flatMap { BuddyStore.shared.buddy(withID: $0) }
        do {
            let answerText = try await companionManager.previewAutomationRun(
                automation: request.automation, buddy: buddy, resolvedInstruction: request.prompt
            )
            return .succeeded(text: answerText, taskID: nil)
        } catch {
            return .failed(reason: error.localizedDescription, taskID: nil)
        }
    }

    // MARK: Source data

    func fetchSourceText(for source: AutomationSource) async -> AutomationSourceFetchResult {
        switch source {
        case .nothing:
            return .noData("")
        case .todaysCalendar:
            return await Self.todaysCalendarText(now: currentDate, calendar: calendar)
        case .canvasDeadlines(let withinDays):
            return await Self.canvasDeadlinesText(withinDays: withinDays, now: currentDate, calendar: calendar)
        case .reminders(let listName):
            return await Self.remindersText(listName: listName, now: currentDate)
        case .clipboard:
            let clipboardText = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return clipboardText.isEmpty ? .noData("(the clipboard is empty)") : .data(String(clipboardText.prefix(4000)))
        case .screenText:
            return await Self.screenText()
        case .folderFiles(let folderPath):
            guard let fileNames = fileNames(inFolderPath: folderPath) else { return .unavailable("Wisp can't read that folder.") }
            return fileNames.isEmpty ? .noData("(the folder is empty)") : .data(fileNames.sorted().prefix(60).joined(separator: "\n"))
        }
    }

    private static func timeText(_ date: Date, calendar: Calendar, includesWeekday: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = includesWeekday ? "EEE h:mm a" : "h:mm a"
        return formatter.string(from: date)
    }

    private static func todaysCalendarText(now: Date, calendar: Calendar) async -> AutomationSourceFetchResult {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .unavailable("Calendar access isn't on. Turn it on in Settings > General.")
        }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return .noData("(no events)") }
        guard let events = try? await CalendarDataProvider.shared.events(from: startOfToday, to: startOfTomorrow, maximumEventCount: 25) else {
            return .unavailable("Wisp couldn't read your calendar.")
        }
        guard !events.isEmpty else { return .noData("(no events today)") }
        let lines = events.map { event -> String in
            let whenText = event.isAllDay
                ? "all day"
                : "\(timeText(event.startDate, calendar: calendar, includesWeekday: false))-\(timeText(event.endDate, calendar: calendar, includesWeekday: false))"
            return "\(whenText): \(event.title)" + (event.location.map { " (\($0))" } ?? "")
        }
        return .data(lines.joined(separator: "\n"))
    }

    private static func canvasDeadlinesText(withinDays: Int, now: Date, calendar: Calendar) async -> AutomationSourceFetchResult {
        guard let snapshot = await CanvasFeedStore.shared.loadSnapshot() else {
            return .unavailable("Canvas isn't connected yet, or hasn't synced.")
        }
        let startOfToday = calendar.startOfDay(for: now)
        guard let windowEnd = calendar.date(byAdding: .day, value: max(withinDays, 1), to: startOfToday) else { return .noData("(nothing due)") }
        let dueItems = snapshot.items
            .filter { $0.startDate >= startOfToday && $0.startDate < windowEnd && ($0.kind == .assignment || $0.kind == .quiz) }
            .sorted { $0.startDate < $1.startDate }
        guard !dueItems.isEmpty else { return .noData("(nothing due in the next \(withinDays) day\(withinDays == 1 ? "" : "s"))") }
        let lines = dueItems.prefix(25).map { item -> String in
            let courseText = item.courseCode.map { " [\($0)]" } ?? ""
            let dueText = item.isAllDay
                ? timeText(item.startDate, calendar: calendar, includesWeekday: true).components(separatedBy: " ").first ?? ""
                : timeText(item.startDate, calendar: calendar, includesWeekday: true)
            return "\(item.title)\(courseText), due \(dueText)"
        }
        return .data(lines.joined(separator: "\n"))
    }

    private static func remindersText(listName: String?, now: Date) async -> AutomationSourceFetchResult {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return .unavailable("Reminders access isn't on. Turn it on in Settings > General.")
        }
        guard let snapshot = try? await RemindersDataProvider.shared.snapshot(listName: listName, filter: .all, now: now) else {
            return .unavailable("Wisp couldn't read your reminders.")
        }
        guard !snapshot.reminders.isEmpty else { return .noData("(no open reminders)") }
        let lines = snapshot.reminders.prefix(30).map { reminder -> String in
            let dueText = reminder.dueDate.map { ", due \(timeText($0, calendar: .current, includesWeekday: true))" } ?? ""
            return "\(reminder.title)\(dueText) [\(reminder.listName)]"
        }
        return .data(lines.joined(separator: "\n"))
    }

    private static func screenText() async -> AutomationSourceFetchResult {
        guard let screenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() else {
            return .unavailable("Wisp can't read the screen. Screen recording may be off.")
        }
        guard let screenTextSnapshot = await ScreenTextRecognizer.shared.snapshot(
            for: screenCaptures,
            waitingAtMost: ScreenTextRecognizer.toolWaitBudgetSeconds,
            maximumLineCount: 150,
            maximumCharacterCount: 4000
        ) else { return .noData("(no readable text on screen)") }
        return .data(screenTextSnapshot.plainText())
    }

    func fileNames(inFolderPath folderPath: String) -> [String]? {
        let expandedPath = (folderPath as NSString).expandingTildeInPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: expandedPath) else { return nil }
        // Hidden files (.DS_Store, partial downloads) are not news.
        return names.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".crdownload") && !$0.hasSuffix(".download") }
    }

    // MARK: Outputs

    func showInNotch(text: String, buddyID: UUID?, automationName: String) {
        companionManager?.presentAutomationResult(text)
    }

    func writeRemindersChecklist(listTitle: String, titles: [String], isAttended: Bool) async -> AutomationOutputWriteResult {
        await AutomationRemindersWriter.shared.writeChecklist(listTitle: listTitle, titles: titles, mayAskForAccess: isAttended)
    }

    /// The same flow as Jobs' study blocks: propose, ask on the always-ask card, write to the Wisp
    /// calendar only. An unanswered card is a decline.
    func proposeAndAskToWriteStudyBlocks() async -> AutomationStudyBlockResult {
        let jobsEngine = JobsEngine.shared
        if jobsEngine.pendingStudyBlocks.isEmpty, jobsEngine.hasCanvasFeed {
            await jobsEngine.syncNow()
        }
        let pendingCountBefore = jobsEngine.pendingStudyBlocks.count
        guard pendingCountBefore > 0 else { return .nothingToPropose }
        let problemBefore = jobsEngine.lastActionProblemMessage

        await jobsEngine.approvePendingStudyBlocks()

        let writtenCount = pendingCountBefore - jobsEngine.pendingStudyBlocks.count
        if writtenCount > 0 { return .written(writtenCount) }
        if let problemAfter = jobsEngine.lastActionProblemMessage, problemAfter != problemBefore { return .failed(problemAfter) }
        return .notApproved
    }

    func previewStudyBlockSummary() async -> String {
        let proposals = JobsEngine.shared.pendingStudyBlocks
        guard !proposals.isEmpty else { return "" }
        let lines = proposals.prefix(6).map { proposal in
            "\(proposal.title): \(Self.timeText(proposal.start, calendar: calendar, includesWeekday: true))"
        }
        return "\(proposals.count) study block\(proposals.count == 1 ? "" : "s") to propose:\n" + lines.joined(separator: "\n")
    }

    func postNotification(title: String, body: String) {
        // Silent while another app is using the mic or camera (quiet mode), like finished tasks.
        guard !QuietModeMonitor.shared.isQuiet else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func fileMessageInBuddyThread(buddyID: UUID, automationName: String, text: String) {
        let threadStore = BuddyThreadStore.shared
        let exchangeTaskID = UUID()
        threadStore.beginExchange(forBuddyWithID: buddyID, taskID: exchangeTaskID, origin: .job, userText: automationName)
        threadStore.completeExchange(forBuddyWithID: buddyID, taskID: exchangeTaskID, answerText: text)
    }

    func speak(line: String) {
        companionManager?.speakAutomationLine(line)
    }

    // MARK: JobsEngine

    func syncCanvasNow() async -> AutomationJobsResult {
        let jobsEngine = JobsEngine.shared
        guard jobsEngine.hasCanvasFeed else {
            return AutomationJobsResult(summary: "", hasNews: false, problem: "Canvas isn't connected yet. Add your link in the Canvas page.")
        }
        guard jobsEngine.isCanvasJobEnabled else {
            return AutomationJobsResult(summary: "", hasNews: false, problem: "The Canvas job is paused.")
        }
        let syncedAtBefore = jobsEngine.lastSyncedAt
        await jobsEngine.syncNow()
        if case .failed(let message) = jobsEngine.syncState {
            return AutomationJobsResult(summary: "", hasNews: false, problem: message)
        }
        guard jobsEngine.lastSyncedAt != syncedAtBefore else {
            return AutomationJobsResult(summary: "Canvas was checked a moment ago.", hasNews: false, problem: nil)
        }
        if let latestDiff = jobsEngine.latestDiff, !latestDiff.isEmpty {
            return AutomationJobsResult(summary: "Canvas: \(latestDiff.summaryLine)", hasNews: true, problem: nil)
        }
        return AutomationJobsResult(summary: "Canvas is up to date.", hasNews: false, problem: nil)
    }

    func rebuildChecklistNow() async -> AutomationJobsResult {
        let jobsEngine = JobsEngine.shared
        guard jobsEngine.isDailyChecklistEnabled else {
            return AutomationJobsResult(summary: "", hasNews: false, problem: "The daily checklist is paused.")
        }
        await jobsEngine.rebuildChecklistNow()
        let itemCount = jobsEngine.todayChecklist.count
        if itemCount == 0, let problem = jobsEngine.lastActionProblemMessage {
            return AutomationJobsResult(summary: "", hasNews: false, problem: problem)
        }
        return AutomationJobsResult(
            summary: itemCount == 0 ? "Nothing on today's checklist." : "Your checklist for today has \(itemCount) item\(itemCount == 1 ? "" : "s").",
            hasNews: itemCount > 0,
            problem: nil
        )
    }

    func jobsSwitchIsOn(for action: AutomationAction) -> Bool? {
        switch action {
        case .syncCanvas: return JobsEngine.shared.isCanvasJobEnabled
        case .buildDailyChecklist: return JobsEngine.shared.isDailyChecklistEnabled
        case .askBuddy, .proposeStudyBlocks: return nil
        }
    }

    func setJobsSwitch(_ isOn: Bool, for action: AutomationAction) {
        switch action {
        case .syncCanvas: JobsEngine.shared.isCanvasJobEnabled = isOn
        case .buildDailyChecklist: JobsEngine.shared.isDailyChecklistEnabled = isOn
        case .askBuddy, .proposeStudyBlocks: break
        }
    }

    func nextJobsRunDate(for action: AutomationAction, after date: Date) -> Date? {
        switch action {
        case .syncCanvas:
            guard let lastSyncedAt = JobsEngine.shared.lastSyncedAt else { return nil }
            // JobsEngine checks hourly; a due sync happens within the next minute.
            return max(lastSyncedAt.addingTimeInterval(JobsEngine.scheduledSyncIntervalSeconds), date.addingTimeInterval(60))
        case .buildDailyChecklist, .askBuddy, .proposeStudyBlocks:
            return nil
        }
    }

    // MARK: Events

    var newCanvasItemTitlesPublisher: AnyPublisher<[String], Never> {
        JobsEngine.shared.$latestDiff
            // The value present at subscription is old news.
            .dropFirst()
            .compactMap { diff -> [String]? in
                guard let diff, !diff.isFirstSync, !diff.added.isEmpty else { return nil }
                return diff.added.map(\.title)
            }
            .eraseToAnyPublisher()
    }

    func meetingsStarting(withinMinutes minutes: Int, now: Date) async -> [AutomationMeetingInfo] {
        // Never prompts: without Calendar access this is simply empty.
        guard let imminentEvent = await CalendarDataProvider.shared.imminentTimedEventIfAuthorized(
            now: now,
            lookAheadInterval: TimeInterval(minutes * 60),
            recentlyStartedInterval: 0
        ), imminentEvent.startDate > now else { return [] }
        return [AutomationMeetingInfo(id: imminentEvent.id, title: imminentEvent.title, start: imminentEvent.startDate)]
    }

    func startScreenWatch(forText text: String, onMet: @escaping @MainActor () -> Void) -> (() -> Void)? {
        chainWatcherEndedHandlerIfNeeded()
        switch ScreenWatcherStore.shared.startWatching(.textAppears(text)) {
        case .started(let watcher):
            ownedWatchCallbacksByWatcherID[watcher.id] = onMet
            return { [weak self] in
                self?.ownedWatchCallbacksByWatcherID[watcher.id] = nil
                ScreenWatcherStore.shared.stopWatching(watcherID: watcher.id)
            }
        case .alreadyWatching(let watcher):
            // The user's own identical watch: ride along, and leave it running when we stop.
            sharedWatchCallbacksByWatcherID[watcher.id] = onMet
            return { [weak self] in self?.sharedWatchCallbacksByWatcherID[watcher.id] = nil }
        case .tooManyWatchers:
            return nil
        }
    }

    /// `ScreenWatcherStore` has one end-of-watch callback, owned by `CompanionManager`. A watch
    /// that belongs to an automation is answered by the automation alone; every other watch still
    /// reaches the original handler.
    private func chainWatcherEndedHandlerIfNeeded() {
        guard !hasChainedWatcherEndedHandler else { return }
        hasChainedWatcherEndedHandler = true
        let previousHandler = ScreenWatcherStore.shared.onWatcherEnded
        ScreenWatcherStore.shared.onWatcherEnded = { [weak self] endedWatcher, ending in
            Task { @MainActor in
                guard let self else { previousHandler?(endedWatcher, ending); return }
                if let ownedCallback = self.ownedWatchCallbacksByWatcherID.removeValue(forKey: endedWatcher.id) {
                    if case .conditionMet = ending { ownedCallback() }
                    return
                }
                if let sharedCallback = self.sharedWatchCallbacksByWatcherID.removeValue(forKey: endedWatcher.id) {
                    if case .conditionMet = ending { sharedCallback() }
                }
                previousHandler?(endedWatcher, ending)
            }
        }
    }
}
