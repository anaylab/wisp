//
//  JobsEngineLiveDependencies.swift
//  leanring-buddy
//
//  The real adapters behind JobsEngine's protocols: the Keychain, the feed store,
//  the two EventKit actors, the confirmation coordinator and notifications. Kept
//  out of JobsEngine.swift so Tests/JobsEngine can compile the engine alone.
//
//  The adapters are small `nonisolated` structs that forward to the shared actors,
//  rather than extensions on the actors, because the app builds with main-actor
//  default isolation and an extension conformance would be pinned to the main actor.
//

import Foundation
import UserNotifications

// MARK: - Feed and Keychain

nonisolated struct LiveJobsFeed: JobsFeedProviding {
    func fetchCurrentItems(now: Date, calendar: Calendar) async throws -> [CanvasItem] {
        try await CanvasFeedStore.shared.fetchCurrentItems(now: now, calendar: calendar)
    }
    func loadSnapshot() async -> CanvasSnapshot? { await CanvasFeedStore.shared.loadSnapshot() }
    func saveSnapshot(_ snapshot: CanvasSnapshot) async throws {
        try await CanvasFeedStore.shared.saveSnapshot(snapshot)
    }
    func clearSnapshot() async { await CanvasFeedStore.shared.clearSnapshot() }
}

nonisolated struct LiveJobsFeedConfiguration: JobsFeedConfiguring {
    func hasFeedURL() -> Bool { CanvasFeedKeychainStore.hasFeedURL() }
    func saveFeedURL(_ feedURL: URL) throws { try CanvasFeedKeychainStore.save(feedURL) }
    func deleteFeedURL() { CanvasFeedKeychainStore.delete() }
}

// MARK: - EventKit

nonisolated struct LiveJobsCalendarWriter: JobsCalendarWriting {
    func authorizationState() async -> JobsAccessState { await WispCalendarWriter.shared.authorizationState() }
    func requestAccessIfNeeded() async throws { try await WispCalendarWriter.shared.requestAccessIfNeeded() }
    func ensureWispCalendarExists() async throws { try await WispCalendarWriter.shared.ensureWispCalendarExists() }
    func apply(diff: CanvasDiff) async throws -> (created: Int, updated: Int, deleted: Int) {
        try await WispCalendarWriter.shared.apply(diff: diff)
    }
    func writeStudyBlocks(_ proposals: [StudyBlockProposal]) async throws -> Int {
        try await WispCalendarWriter.shared.writeStudyBlocks(proposals)
    }
    func busyIntervals(from startDate: Date, to endDate: Date) async throws -> [BusyInterval] {
        try await WispCalendarWriter.shared.busyIntervals(from: startDate, to: endDate)
    }
    func calendarEvents(onDay day: Date, calendar: Calendar) async throws -> [ChecklistCalendarEvent] {
        try await WispCalendarWriter.shared.calendarEvents(onDay: day, calendar: calendar)
    }
}

nonisolated struct LiveJobsReminderWriter: JobsReminderWriting {
    func authorizationState() async -> JobsAccessState { await WispTodayReminders.shared.authorizationState() }
    func requestAccessIfNeeded() async throws { try await WispTodayReminders.shared.requestAccessIfNeeded() }
    func rebuild(with items: [ChecklistItem]) async throws { try await WispTodayReminders.shared.rebuild(with: items) }
    func readBackCompletion() async throws -> [String: (isCompleted: Bool, completionDate: Date?)] {
        try await WispTodayReminders.shared.readBackCompletion()
    }
    func setCompleted(itemID: String, isCompleted: Bool) async throws {
        try await WispTodayReminders.shared.setCompleted(itemID: itemID, isCompleted: isCompleted)
    }
}

// MARK: - Approval card

/// Asks through the same coordinator every other consequential action uses. The tool
/// name is on `ToolCallSafety.alwaysAskBareToolNames`, so session auto-approve cannot
/// answer for the user.
nonisolated struct LiveJobsStudyBlockApprover: JobsStudyBlockApproving {
    func askToWriteStudyBlocks(_ proposals: [StudyBlockProposal]) async -> Bool {
        let toolInput = Self.toolInput(for: proposals)
        let decision = await ToolConfirmationCoordinator.shared.requestApproval(
            toolName: JobsToolNames.applyStudyBlocks,
            toolInput: toolInput
        )
        return decision.isApproved
    }

    /// `{"blocks": [{"title", "start", "end"}]}` with ISO 8601 times. The card builder
    /// (`ToolConfirmationCardBuilder.studyBlocksCard`) reads exactly these keys.
    static func toolInput(for proposals: [StudyBlockProposal]) -> JSONValue {
        let timestampFormatter = ISO8601DateFormatter()
        let blockValues: [JSONValue] = proposals.map { proposal in
            .object([
                "title": .string(proposal.title),
                "start": .string(timestampFormatter.string(from: proposal.start)),
                "end": .string(timestampFormatter.string(from: proposal.end))
            ])
        }
        return .object(["blocks": .array(blockValues)])
    }
}

// MARK: - Announcements

/// A notification (silent in quiet mode) and the island's success flash. Called only
/// for a non-empty diff, so an unchanged sync stays completely quiet.
nonisolated struct LiveJobsChangeAnnouncer: JobsChangeAnnouncing {
    /// Set by `NotchWindowController`, which holds the `CompanionManager`.
    @MainActor static var flashSuccessOnIsland: (() -> Void)?

    func announceCanvasChange(title: String, body: String) async {
        let isQuiet = await MainActor.run { QuietModeMonitor.shared.isQuiet }
        await MainActor.run { Self.flashSuccessOnIsland?() }
        guard !isQuiet else { return }

        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Shared instance

extension JobsEngine {
    static let shared = JobsEngine(dependencies: JobsEngineDependencies(
        feed: LiveJobsFeed(),
        feedConfiguration: LiveJobsFeedConfiguration(),
        calendarWriter: LiveJobsCalendarWriter(),
        reminders: LiveJobsReminderWriter(),
        studyBlockApprover: LiveJobsStudyBlockApprover(),
        announcer: LiveJobsChangeAnnouncer(),
        userDefaults: .standard,
        stateFileURL: JobsPrivateJSONFile.fileURL(named: "jobs-engine-state.json"),
        now: { Date() },
        calendar: .current
    ))
}
