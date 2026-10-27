//
//  AgentTaskRegistry.swift
//  leanring-buddy
//
//  Tracks agent tasks — what ran, what it did, and how it ended.
//
//  Today every interaction is a single model call, so a "task" is a single
//  step. The registry still exists at this stage because the dashboard needs
//  something to show, and because recording turns now means the history is
//  already there when multi-step tool calling arrives.
//
//  The important structural choice is that tasks are keyed rather than
//  singular. The app previously held one `currentResponseTask`, which meant
//  starting anything long-running guaranteed it would be cancelled by the
//  next thing the user said. Keying by id allows an interactive turn to be
//  cancelled on its own without disturbing background work.
//

import Combine
import Foundation

@MainActor
final class AgentTaskRegistry: ObservableObject {
    static let shared = AgentTaskRegistry()

    private static let maximumRetainedRecords = 100

    /// Newest first, so the dashboard reads top-down.
    @Published private(set) var records: [AgentTaskRecord] = []

    /// The task driving the current conversation, if any. Only this one is
    /// cancelled when the user starts speaking again.
    private(set) var currentInteractiveTaskID: UUID?

    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    /// Saves the history to disk shortly after it changes. Debounced because a
    /// single turn mutates its record several times (steps, durations, status)
    /// and one write per burst is plenty.
    private var historyPersistenceObserver: AnyCancellable?

    private init() {
        records = AgentTaskHistoryStore.loadRecords()
        trimIfNeeded()

        historyPersistenceObserver = $records
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { changedRecords in
                AgentTaskHistoryStore.saveRecords(changedRecords)
            }
    }

    /// Writes the history synchronously. Called on quit so the last turn isn't
    /// lost to the save debounce.
    func saveHistoryImmediately() {
        AgentTaskHistoryStore.saveRecordsImmediately(records)
    }

    // MARK: - Lifecycle

    @discardableResult
    func beginTask(title: String, kind: AgentTaskRecord.Kind = .interactive) -> UUID {
        let record = AgentTaskRecord(title: title, kind: kind)
        records.insert(record, at: 0)
        trimIfNeeded()

        if kind == .interactive {
            currentInteractiveTaskID = record.id
        }
        return record.id
    }

    /// Associates a cancellable Swift task with a record, so the registry can
    /// stop the underlying work and not merely mark the row.
    func attachRunningTask(_ task: Task<Void, Never>, to taskID: UUID) {
        runningTasks[taskID] = task
    }

    func appendStep(_ step: AgentStepRecord, to taskID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == taskID }) else { return }
        records[index].steps.append(step)
    }

    /// Updates the most recently appended step, for durations only known once
    /// the step finishes.
    func updateLastStep(of taskID: UUID, mutate: (inout AgentStepRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == taskID }),
              !records[index].steps.isEmpty else { return }
        mutate(&records[index].steps[records[index].steps.count - 1])
    }

    func finishTask(_ taskID: UUID, status: AgentTaskRecord.Status, finalText: String? = nil) {
        guard let index = records.firstIndex(where: { $0.id == taskID }) else { return }
        records[index].status = status
        records[index].finishedAt = Date()
        if let finalText {
            records[index].finalText = finalText
        }

        runningTasks[taskID] = nil
        if currentInteractiveTaskID == taskID {
            currentInteractiveTaskID = nil
        }
    }

    // MARK: - Cancellation

    /// Cancels only the in-flight conversation turn. Background tasks keep
    /// running — that separation is the whole point of the registry.
    func cancelCurrentInteractiveTask() {
        guard let taskID = currentInteractiveTaskID else { return }
        cancelTask(taskID)
    }

    func cancelTask(_ taskID: UUID) {
        runningTasks[taskID]?.cancel()
        runningTasks[taskID] = nil

        if let index = records.firstIndex(where: { $0.id == taskID }),
           !records[index].status.isTerminal {
            records[index].status = .cancelled
            records[index].finishedAt = Date()
        }

        if currentInteractiveTaskID == taskID {
            currentInteractiveTaskID = nil
        }
    }

    /// Used on app shutdown.
    func cancelAllTasks() {
        for taskID in runningTasks.keys {
            cancelTask(taskID)
        }
    }

    // MARK: - Queries

    var runningRecords: [AgentTaskRecord] {
        records.filter { !$0.status.isTerminal }
    }

    var backgroundRunningCount: Int {
        records.filter { $0.kind == .background && !$0.status.isTerminal }.count
    }

    func clearCompleted() {
        records.removeAll { $0.status.isTerminal }
    }

    private func trimIfNeeded() {
        guard records.count > Self.maximumRetainedRecords else { return }
        // Only drop finished rows; a running task must stay visible however
        // long it takes.
        var trimmed = records
        while trimmed.count > Self.maximumRetainedRecords,
              let removableIndex = trimmed.lastIndex(where: { $0.status.isTerminal }) {
            trimmed.remove(at: removableIndex)
        }
        records = trimmed
    }
}
