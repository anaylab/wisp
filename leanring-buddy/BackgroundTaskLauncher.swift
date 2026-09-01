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
    /// Ceiling on concurrent background tasks.
    ///
    /// They all queue behind one model anyway, so a larger number would only
    /// lengthen the queue while making the dashboard harder to read.
    private static let maximumConcurrentTasks = 2

    /// Whether another background task can start right now.
    static var canStartAnotherTask: Bool {
        AgentTaskRegistry.shared.backgroundRunningCount < maximumConcurrentTasks
    }

    /// Starts a background agent task.
    ///
    /// - Returns: The task's id, or nil when too many are already running.
    @discardableResult
    static func start(
        request: String,
        modelProvider: any ModelProvider,
        systemPrompt: String,
        speakConfirmation: @escaping @MainActor (String) async -> Void
    ) -> UUID? {
        guard canStartAnotherTask else {
            print("🌙 Background: refused \"\(request.prefix(40))\" — \(maximumConcurrentTasks) already running")
            return nil
        }

        let taskID = AgentTaskRegistry.shared.beginTask(title: request, kind: .background)

        let work = Task { @MainActor in
            let runner = AgentTurnRunner(
                modelProvider: modelProvider,
                priority: .background,
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
                    conversationHistory: [],
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
                notifyCompletion(request: request, result: outcome.terminalText, didSucceed: true)
            } catch is CancellationError {
                AgentTaskRegistry.shared.finishTask(taskID, status: .cancelled)
            } catch {
                AgentTaskRegistry.shared.finishTask(
                    taskID,
                    status: .failed(error.localizedDescription)
                )
                notifyCompletion(request: request, result: error.localizedDescription, didSucceed: false)
            }
        }

        AgentTaskRegistry.shared.attachRunningTask(work, to: taskID)
        print("🌙 Background: started \"\(request.prefix(60))\"")
        return taskID
    }

    // MARK: - Notification

    /// Posts a system notification when a task finishes.
    ///
    /// Notifications rather than speech: a background task finishes at a
    /// moment of its own choosing, and interrupting whatever the user is doing
    /// — possibly another conversation — to announce it would be worse than
    /// useless. The dashboard holds the full result either way.
    private static func notifyCompletion(request: String, result: String, didSucceed: Bool) {
        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound]) { isGranted, _ in
            guard isGranted else { return }

            let content = UNMutableNotificationContent()
            content.title = didSucceed ? "Wisp finished a task" : "A Wisp task failed"
            content.subtitle = String(request.prefix(60))
            content.body = String(result.prefix(200))
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
