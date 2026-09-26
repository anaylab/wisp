//
//  FinishedWorkInbox.swift
//  leanring-buddy
//
//  Background tasks the user hasn't looked at since they finished. The notch
//  shows how many there are ("2 new" beside the notch) so a result that landed
//  while the user was busy — or on a call, when no notification is posted — is
//  waiting for them rather than lost. Opening the notch's full panel shows them
//  under NEW; closing the panel afterwards marks them seen.
//
//  Only ids are kept here; the results themselves live in `AgentTaskRegistry`.
//  Not persisted: after a relaunch the History timeline holds every result, and
//  a stale "new" badge from yesterday would be noise.
//

import Combine
import Foundation

@MainActor
final class FinishedWorkInbox: ObservableObject {
    static let shared = FinishedWorkInbox()

    /// The most results the badge counts and the panel lists.
    static let maximumUnseenResults = 5

    /// Finished background task ids not yet seen, newest first.
    @Published private(set) var unseenTaskIDs: [UUID] = []

    private init() {}

    /// Records a background task that just finished (succeeded or failed —
    /// a failure is just as much something the user should see).
    func recordFinishedTask(_ taskID: UUID) {
        unseenTaskIDs.removeAll { $0 == taskID }
        unseenTaskIDs.insert(taskID, at: 0)
        if unseenTaskIDs.count > Self.maximumUnseenResults {
            unseenTaskIDs.removeLast(unseenTaskIDs.count - Self.maximumUnseenResults)
        }
    }

    /// The unseen tasks' records, dropping any the registry no longer holds.
    func unseenRecords(in taskRegistry: AgentTaskRegistry) -> [AgentTaskRecord] {
        unseenTaskIDs.compactMap { unseenTaskID in
            taskRegistry.records.first { $0.id == unseenTaskID }
        }
    }

    func markAllSeen() {
        guard !unseenTaskIDs.isEmpty else { return }
        unseenTaskIDs.removeAll()
    }
}
