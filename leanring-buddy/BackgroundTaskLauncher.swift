//
//  BackgroundTaskLauncher.swift
//  leanring-buddy
//
//  Starts agent work that outlives the conversation that asked for it.
//
//  An interactive turn is cancelled the moment the user speaks again, which is
//  right: a new question replaces the old one. That rule makes anything slow
//  impossible, though, because the user has to sit in silence until it
//  finishes or lose it. Background tasks are the exception — they keep their
//  own identity in the registry, are not cancelled by the next utterance, and
//  report back when they're done.
//
//  Everything they do still goes through ModelAccessGate at background
//  priority, so a task running quietly never delays a reply the user is
//  actually waiting for.
//

import Foundation
import UserNotifications

@MainActor
enum BackgroundTaskLauncher {
    /// Running tasks whose model is off this machine. They don't share the one
    /// resident local model, so they are counted against their own, higher
    /// ceiling (`BackgroundTaskCapacityPolicy`) instead of the local queue's.
    private static var runningOffMachineTaskIDs: Set<UUID> = []

    /// Whether another background task can start right now, on the model
    /// that runs here (or, with `runsOffThisMachine`, on a cloud model).
    static func canStartAnotherTask(runsOffThisMachine: Bool = false) -> Bool {
        BackgroundTaskCapacityPolicy.canStart(
            runsOffThisMachine: runsOffThisMachine,
            runningTotal: AgentTaskRegistry.shared.backgroundRunningCount,
            runningOffThisMachine: runningOffMachineTaskIDs.count
        )
    }

    /// Whether another task on the local model can start right now.
    static var canStartAnotherTask: Bool { canStartAnotherTask() }

    /// Starts a background agent task.
    ///
    /// - Parameter title: How the task is listed (History, the notch, the
    ///   notification). Defaults to the request itself; a buddy's run passes
    ///   "Buddy · <name>" instead of repeating its whole job.
    /// - Parameter conversationHistory: Earlier exchanges to put in front of the
    ///   model; a buddy passes its thread so a run continues the conversation.
    /// - Parameter onSucceeded: Called with the task id and the answer when the
    ///   task finishes successfully (a buddy files the answer in its thread).
    /// - Parameter completionNotification: How the finish is announced: a buddy
    ///   names itself ("Gmail Digest finished"), and `nil` posts nothing — for a
    ///   buddy the user muted, or a run another buddy asked for.
    /// - Returns: The task's id, or nil when too many are already running.
    @discardableResult
    static func start(
        request: String,
        title: String? = nil,
        modelProvider: any ModelProvider,
        systemPrompt: String,
        conversationHistory: [BuddyChatMessage] = [],
        toolkit: AgentRunToolkit = .none,
        onSucceeded: (@MainActor (UUID, String) -> Void)? = nil,
        completionNotification: CompletionNotificationStyle? = .generic,
        speakConfirmation: @escaping @MainActor (String) async -> Void
    ) -> UUID? {
        let runsOffThisMachine = modelProvider.deployment.sendsDataOffThisMachine
        guard canStartAnotherTask(runsOffThisMachine: runsOffThisMachine) else {
            print("🌙 Background: refused \"\(request.prefix(40))\" — too many already running")
            return nil
        }

        let displayTitle = title ?? request
        let taskID = AgentTaskRegistry.shared.beginTask(title: displayTitle, kind: .background)
        if runsOffThisMachine { runningOffMachineTaskIDs.insert(taskID) }

        let work = Task { @MainActor in
            defer { runningOffMachineTaskIDs.remove(taskID) }
            let runner = AgentTurnRunner(
                modelProvider: modelProvider,
                priority: .background,
                toolkit: toolkit,
                speakConfirmation: speakConfirmation
            )

            do {
                let outcome = try await runner.run(
                    userText: request,
                    // No screenshot: the screen at completion time is not the
                    // screen the request was made about, and attaching one is
                    // the most expensive thing a request can do.
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    onNarration: { narration in
                        print("🌙 Background narration: \(narration)")
                    },
                    onStep: { step in
                        AgentTaskRegistry.shared.appendStep(step, to: taskID)
                    }
                )

                AgentTaskRegistry.shared.finishTask(
                    taskID,
                    status: .succeeded,
                    finalText: outcome.terminalText
                )
                onSucceeded?(taskID, outcome.terminalText)
                FinishedWorkInbox.shared.recordFinishedTask(taskID)
                if let completionNotification {
                    notifyCompletion(style: completionNotification, request: displayTitle, result: outcome.terminalText, didSucceed: true)
                }
            } catch is CancellationError {
                AgentTaskRegistry.shared.finishTask(taskID, status: .cancelled)
            } catch {
                AgentTaskRegistry.shared.finishTask(
                    taskID,
                    status: .failed(error.localizedDescription)
                )
                FinishedWorkInbox.shared.recordFinishedTask(taskID)
                if let completionNotification {
                    notifyCompletion(style: completionNotification, request: displayTitle, result: error.localizedDescription, didSucceed: false)
                }
            }
        }

        AgentTaskRegistry.shared.attachRunningTask(work, to: taskID)
        print("🌙 Background: started \"\(request.prefix(60))\"")
        return taskID
    }

    // MARK: - Notification

    /// Whose finish a notification announces.
    enum CompletionNotificationStyle {
        /// "Wisp finished a task", with the task as the subtitle.
        case generic
        /// "<name> finished", with the buddy's job as the subtitle.
        case buddy(name: String, job: String)
    }

    /// Posts a system notification when a task finishes.
    ///
    /// Notifications rather than speech: a background task finishes at a
    /// moment of its own choosing, and interrupting whatever the user is doing
    /// — possibly another conversation — to announce it would be worse than
    /// useless. The dashboard holds the full result either way.
    ///
    /// On a call (`QuietModeMonitor`) no notification is posted at all — a
    /// banner sliding over a shared screen is exactly what quiet mode is for.
    /// The result waits in the notch's "new" badge (`FinishedWorkInbox`) instead.
    private static func notifyCompletion(style: CompletionNotificationStyle, request: String, result: String, didSucceed: Bool) {
        guard !QuietModeMonitor.shared.isQuiet else {
            print("🌙 Background: finished during a call — holding the notification, badge only")
            return
        }
        let notificationTitle: String
        let notificationSubtitle: String
        switch style {
        case .generic:
            notificationTitle = didSucceed ? "Wisp finished a task" : "A Wisp task failed"
            notificationSubtitle = String(request.prefix(60))
        case .buddy(let name, let job):
            notificationTitle = didSucceed ? "\(name) finished" : "\(name) ran into a problem"
            notificationSubtitle = String(job.prefix(60))
        }
        // Without Wisp's machine tags, which would show up raw in the banner.
        let notificationBody = String(AnswerDisplayText.cleaned(result).prefix(200))
        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound]) { isGranted, _ in
            guard isGranted else { return }

            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.subtitle = notificationSubtitle
            content.body = notificationBody
            content.sound = didSucceed ? .default : nil

            center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
        }
    }
}
