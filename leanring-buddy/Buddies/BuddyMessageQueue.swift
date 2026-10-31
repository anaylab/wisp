//
//  BuddyMessageQueue.swift
//  A first-in-first-out line of messages waiting for a buddy that is mid-run.
//
//  Until now a message sent to a busy buddy was refused. The line keeps it
//  instead: one run at a time per buddy, messages answered in the order sent,
//  and the user can pause the line or take a message back out. The idea (a
//  FIFO per agent with pause, resume and cancel) is OpenBot's.
//
//  Pure and Codable so it can be tested with plain swiftc and saved to disk.
//  Text only: attached files and pictures are read when sent, and can't wait.
//

import Foundation

struct QueuedBuddyMessage: Codable, Identifiable, Equatable {
    let id: UUID
    /// What the model receives.
    let text: String
    let queuedAt: Date
}

struct BuddyMessageQueue: Codable, Equatable {
    /// More than this waiting for one buddy is a sign the user is talking to a
    /// wall; the next message is refused so the line can't grow without bound.
    static let maximumWaitingMessagesPerBuddy = 10

    private(set) var waitingMessagesByBuddyID: [UUID: [QueuedBuddyMessage]] = [:]
    private(set) var pausedBuddyIDs: Set<UUID> = []

    // MARK: - Reading

    func waitingMessages(forBuddyWithID buddyID: UUID) -> [QueuedBuddyMessage] {
        waitingMessagesByBuddyID[buddyID] ?? []
    }

    func isPaused(buddyWithID buddyID: UUID) -> Bool {
        pausedBuddyIDs.contains(buddyID)
    }

    /// Buddies with at least one message waiting, for the drain pass.
    var buddyIDsWithWaitingMessages: [UUID] {
        waitingMessagesByBuddyID.filter { !$0.value.isEmpty }.map(\.key)
    }

    // MARK: - Changing

    /// Puts a message at the back of the line. Nil when the line is full or the
    /// text is empty.
    @discardableResult
    mutating func enqueue(
        _ messageText: String,
        forBuddyWithID buddyID: UUID,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> QueuedBuddyMessage? {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              waitingMessages(forBuddyWithID: buddyID).count < Self.maximumWaitingMessagesPerBuddy else {
            return nil
        }
        let queuedMessage = QueuedBuddyMessage(id: id, text: trimmedText, queuedAt: now)
        waitingMessagesByBuddyID[buddyID, default: []].append(queuedMessage)
        return queuedMessage
    }

    /// The message at the front, unless the line is paused or empty. Does not
    /// remove it: it leaves the line only once its run has actually started
    /// (`removeFront`), so a run that can't start (the background limit) loses
    /// nothing.
    func front(forBuddyWithID buddyID: UUID) -> QueuedBuddyMessage? {
        guard !isPaused(buddyWithID: buddyID) else { return nil }
        return waitingMessages(forBuddyWithID: buddyID).first
    }

    mutating func removeFront(forBuddyWithID buddyID: UUID) {
        guard var messages = waitingMessagesByBuddyID[buddyID], !messages.isEmpty else { return }
        messages.removeFirst()
        waitingMessagesByBuddyID[buddyID] = messages.isEmpty ? nil : messages
    }

    /// Takes one message back out of the line. Returns whether it was there.
    @discardableResult
    mutating func cancel(messageWithID messageID: UUID, forBuddyWithID buddyID: UUID) -> Bool {
        guard var messages = waitingMessagesByBuddyID[buddyID],
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        messages.remove(at: index)
        waitingMessagesByBuddyID[buddyID] = messages.isEmpty ? nil : messages
        return true
    }

    mutating func setPaused(_ isPaused: Bool, forBuddyWithID buddyID: UUID) {
        if isPaused { pausedBuddyIDs.insert(buddyID) } else { pausedBuddyIDs.remove(buddyID) }
    }

    /// Forgets everything about a buddy (it was deleted, or its conversation cleared).
    mutating func removeAll(forBuddyWithID buddyID: UUID) {
        waitingMessagesByBuddyID[buddyID] = nil
        pausedBuddyIDs.remove(buddyID)
    }
}
