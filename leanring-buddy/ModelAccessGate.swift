//
//  ModelAccessGate.swift
//  leanring-buddy
//
//  Serializes access to the local model, and lets the conversation cut ahead
//  of background work.
//
//  Two separate reasons make this necessary, and the second is the one that
//  actually bites.
//
//  The obvious reason: the server runs a single copy of a multi-gigabyte model
//  on a machine with no room for another, so concurrent requests queue up
//  somewhere regardless. Better to queue here, where the order can be chosen.
//
//  The subtle reason: the server keeps a cached prompt prefix for whichever
//  conversation it saw last. Interleaving a background request between two
//  steps of a live one displaces that cache, and the next step re-encodes the
//  screenshot — around six seconds of work that produces nothing new, and
//  appears to the user as the assistant randomly stalling mid-sentence. The
//  same effect made an unrelated ninety-second heartbeat a latency bug earlier
//  in this project.
//
//  So: one holder at a time, and a background holder yields between steps
//  whenever someone is waiting to talk.
//

import Foundation

actor ModelAccessGate {
    static let shared = ModelAccessGate()

    enum Priority {
        /// The user is waiting. Always served first.
        case interactive
        /// Nobody is waiting. Yields whenever a conversation needs the model.
        case background
    }

    private var isHeld = false
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether a conversation is queued behind the current holder.
    ///
    /// Background work checks this between steps: finishing the current step
    /// and standing aside costs one step of delay, while holding on costs the
    /// user a visible pause mid-conversation.
    var hasInteractiveWorkWaiting: Bool {
        !interactiveWaiters.isEmpty
    }

    /// Runs `operation` with exclusive use of the model.
    func withAccess<T>(
        priority: Priority,
        operation: () async throws -> T
    ) async rethrows -> T {
        await acquire(priority: priority)
        defer { release() }
        return try await operation()
    }

    private func acquire(priority: Priority) async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            switch priority {
            case .interactive: interactiveWaiters.append(continuation)
            case .background: backgroundWaiters.append(continuation)
            }
        }
    }

    private func release() {
        // Conversations first, always. Background work waits as long as talking
        // continues, which is the correct trade for something nobody is
        // watching.
        if !interactiveWaiters.isEmpty {
            let next = interactiveWaiters.removeFirst()
            next.resume()
            return
        }

        if !backgroundWaiters.isEmpty {
            let next = backgroundWaiters.removeFirst()
            next.resume()
            return
        }

        isHeld = false
    }

    /// Stands aside if a conversation is waiting, then reacquires.
    ///
    /// Called by background work between steps. Returns immediately when
    /// nothing is waiting, so the common case costs nothing.
    func yieldToInteractiveWorkIfNeeded() async {
        guard hasInteractiveWorkWaiting else { return }
        release()
        await acquire(priority: .background)
    }
}
