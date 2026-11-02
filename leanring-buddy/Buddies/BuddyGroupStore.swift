//
//  BuddyGroupStore.swift
//  leanring-buddy
//
//  Saves group chats and their shared transcripts to
//  `~/Library/Application Support/Wisp/buddy-groups.json` (0600, local only,
//  text only), and `BuddyGroupEngine`, which turns a message in a group into
//  runs: it routes (`BuddyGroupPolicy`), starts the owner's run, files the
//  answer in the transcript when the run ends, and follows a handoff to the
//  next teammate up to the hop cap.
//

import Combine
import Foundation

@MainActor
final class BuddyGroupStore: ObservableObject {
    static let shared = BuddyGroupStore()

    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/buddy-groups.json")

    @Published private(set) var groups: [BuddyGroup] = []
    @Published private(set) var messagesByGroupID: [UUID: [BuddyGroupMessage]] = [:]

    private let fileURL: URL

    private struct StoredFile: Codable {
        var groups: [BuddyGroup]
        var messages: [String: [BuddyGroupMessage]]
    }

    init(fileURL: URL = BuddyGroupStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Reading

    func group(withID groupID: UUID) -> BuddyGroup? { groups.first { $0.id == groupID } }

    func messages(ofGroupWithID groupID: UUID) -> [BuddyGroupMessage] { messagesByGroupID[groupID] ?? [] }

    /// Whether an id names a group; the buddy thread strip uses it to keep a
    /// group's runs out of a buddy's own thread tabs.
    func isGroupID(_ id: UUID) -> Bool { groups.contains { $0.id == id } }

    /// Most recently active first.
    func orderedGroups(includingArchived: Bool = false) -> [BuddyGroup] {
        groups
            .filter { includingArchived || !$0.isArchivedInList }
            .sorted { first, second in
                let firstDate = messages(ofGroupWithID: first.id).last?.createdAt ?? first.createdAt
                let secondDate = messages(ofGroupWithID: second.id).last?.createdAt ?? second.createdAt
                return firstDate > secondDate
            }
    }

    // MARK: Changing

    @discardableResult
    func createGroup(name: String, memberIDs: [UUID], leadID: UUID?) -> BuddyGroup {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newGroup = BuddyGroup(
            id: UUID(),
            name: trimmedName.isEmpty ? "New group" : trimmedName,
            memberIDs: memberIDs,
            leadID: leadID.flatMap { memberIDs.contains($0) ? $0 : nil },
            createdAt: Date(),
            isArchived: nil
        )
        groups.insert(newGroup, at: 0)
        save()
        return newGroup
    }

    func updateGroup(withID groupID: UUID, name: String, memberIDs: [UUID], leadID: UUID?) {
        mutate(groupID) { group in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty { group.name = trimmedName }
            group.memberIDs = memberIDs
            group.leadID = leadID.flatMap { memberIDs.contains($0) ? $0 : nil }
        }
    }

    func setArchived(_ isArchived: Bool, groupWithID groupID: UUID) {
        mutate(groupID) { $0.isArchived = isArchived ? true : nil }
    }

    func deleteGroup(withID groupID: UUID) {
        guard let group = group(withID: groupID) else { return }
        for memberID in group.memberIDs {
            BuddyThreadStore.shared.deleteSideThread(groupID, ofBuddyWithID: memberID)
            BuddySessionStore.shared.forgetSession(for: BuddySessionKey(buddyID: memberID, conversationID: groupID))
        }
        groups.removeAll { $0.id == groupID }
        messagesByGroupID[groupID] = nil
        save()
    }

    /// A deleted buddy leaves every group it was in.
    func removeBuddy(withID buddyID: UUID) {
        for group in groups where group.memberIDs.contains(buddyID) {
            mutate(group.id) { group in
                group.memberIDs.removeAll { $0 == buddyID }
                if group.leadID == buddyID { group.leadID = nil }
            }
        }
    }

    func append(_ message: BuddyGroupMessage, toGroupWithID groupID: UUID) {
        guard group(withID: groupID) != nil else { return }
        messagesByGroupID[groupID] = BuddyGroupPolicy.appending(message, to: messages(ofGroupWithID: groupID))
        save()
    }

    func clearMessages(ofGroupWithID groupID: UUID) {
        messagesByGroupID[groupID] = nil
        // A member's kept session would still remember the cleared chat.
        for memberID in group(withID: groupID)?.memberIDs ?? [] {
            BuddySessionStore.shared.forgetSession(for: BuddySessionKey(buddyID: memberID, conversationID: groupID))
        }
        save()
    }

    private func mutate(_ groupID: UUID, _ change: (inout BuddyGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        change(&groups[index])
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(StoredFile.self, from: data) else { return }
        groups = stored.groups
        messagesByGroupID = Dictionary(uniqueKeysWithValues: stored.messages.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save() {
        let stored = StoredFile(
            groups: groups,
            messages: Dictionary(uniqueKeysWithValues: messagesByGroupID.map { ($0.key.uuidString, $0.value) })
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

// MARK: - Engine

/// Runs group chats. One owner answers each message; each answer goes into the
/// shared transcript when its run ends. A buddy still does one thing at a time,
/// so an assignment for a busy buddy waits and is tried again on every change
/// to the task registry (the same clock `BuddyStore`'s message line uses).
@MainActor
final class BuddyGroupEngine: ObservableObject {
    static let shared = BuddyGroupEngine()

    struct Assignment: Identifiable, Equatable {
        let id = UUID()
        let groupID: UUID
        let ownerID: UUID
        /// What the owner is asked.
        let requestText: String
        /// The teammate who handed it over, for a handoff.
        let handedOffByName: String?
        /// How many times this user message has been passed on so far.
        let handoffCount: Int
    }

    /// Waiting for a free buddy, oldest first.
    @Published private(set) var pendingAssignments: [Assignment] = []
    /// Started: the run's task id → what it is doing.
    @Published private(set) var activeAssignments: [UUID: Assignment] = [:]

    private let groupStore: BuddyGroupStore
    private let buddyStore: BuddyStore
    private var registryObservation: AnyCancellable?

    init(groupStore: BuddyGroupStore = .shared, buddyStore: BuddyStore = .shared) {
        self.groupStore = groupStore
        self.buddyStore = buddyStore
    }

    /// Starts watching run endings. Called once at launch.
    func start() {
        guard registryObservation == nil else { return }
        registryObservation = AgentTaskRegistry.shared.$records
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.process() }
            }
    }

    // MARK: Asking

    /// Posts the user's message and assigns it to its owner. False when the
    /// group is gone, empty, or the text is blank.
    @discardableResult
    func send(_ userText: String, inGroupWithID groupID: UUID) -> Bool {
        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, let group = groupStore.group(withID: groupID) else { return false }
        let members = members(of: group)
        guard let routing = BuddyGroupPolicy.route(
            userText: trimmedText,
            members: members,
            leadID: group.leadID,
            lastOwnerID: BuddyGroupPolicy.lastOwnerID(in: groupStore.messages(ofGroupWithID: groupID))
        ) else { return false }
        groupStore.append(
            BuddyGroupMessage(id: UUID(), author: .user, text: trimmedText, createdAt: Date(), taskID: nil),
            toGroupWithID: groupID
        )
        pendingAssignments.append(Assignment(
            groupID: groupID, ownerID: routing.ownerID, requestText: routing.text, handedOffByName: nil, handoffCount: 0
        ))
        process()
        return true
    }

    /// Stops every run of this group and drops what was waiting.
    func stop(groupWithID groupID: UUID) {
        let hadWork = isWorking(inGroupWithID: groupID)
        pendingAssignments.removeAll { $0.groupID == groupID }
        for (taskID, assignment) in activeAssignments where assignment.groupID == groupID {
            AgentTaskRegistry.shared.cancelTask(taskID)
        }
        if hadWork { postNotice("Stopped.", inGroupWithID: groupID) }
    }

    /// Gives the user's latest message to a different member (OpenBot's Reassign).
    func reassignLatestMessage(inGroupWithID groupID: UUID, toBuddyWithID newOwnerID: UUID) {
        guard let group = groupStore.group(withID: groupID), group.memberIDs.contains(newOwnerID),
              let latestUserMessage = groupStore.messages(ofGroupWithID: groupID).last(where: { $0.author == .user }) else { return }
        pendingAssignments.removeAll { $0.groupID == groupID }
        for (taskID, assignment) in activeAssignments where assignment.groupID == groupID {
            AgentTaskRegistry.shared.cancelTask(taskID)
        }
        let requestText = BuddyGroupPolicy.leadingAddress(in: latestUserMessage.text, members: members(of: group))?.remainingText
            .nonEmpty ?? latestUserMessage.text
        pendingAssignments.append(Assignment(
            groupID: groupID, ownerID: newOwnerID, requestText: requestText, handedOffByName: nil, handoffCount: 0
        ))
        process()
    }

    // MARK: Reading

    func isWorking(inGroupWithID groupID: UUID) -> Bool {
        pendingAssignments.contains { $0.groupID == groupID } || activeAssignments.values.contains { $0.groupID == groupID }
    }

    /// Buddies with a run going or waiting in this group, started first.
    func workingBuddyIDs(inGroupWithID groupID: UUID) -> [UUID] {
        let active = activeAssignments.values.filter { $0.groupID == groupID }.map(\.ownerID)
        let waiting = pendingAssignments.filter { $0.groupID == groupID }.map(\.ownerID)
        var seen = Set<UUID>()
        return (active + waiting).filter { seen.insert($0).inserted }
    }

    // MARK: Running

    private func members(of group: BuddyGroup) -> [BuddyGroupMember] {
        group.memberIDs.compactMap { memberID in
            buddyStore.buddy(withID: memberID).map { BuddyGroupMember(id: $0.id, name: $0.name) }
        }
    }

    private func process() {
        finishEndedRuns()
        startWaitingAssignments()
    }

    private func finishEndedRuns() {
        for (taskID, assignment) in activeAssignments {
            guard let record = AgentTaskRegistry.shared.records.first(where: { $0.id == taskID }),
                  record.status.isTerminal else { continue }
            activeAssignments[taskID] = nil
            guard let group = groupStore.group(withID: assignment.groupID) else { continue }
            let ownerName = buddyStore.buddy(withID: assignment.ownerID)?.name ?? "A buddy"
            switch record.status {
            case .succeeded:
                let answerText = AnswerDisplayText.cleaned(record.finalText ?? "")
                let members = members(of: group)
                let (visibleText, handoff) = BuddyGroupPolicy.parseHandoff(
                    in: answerText, members: members, senderID: assignment.ownerID
                )
                groupStore.append(
                    BuddyGroupMessage(
                        id: UUID(), author: .buddy(assignment.ownerID),
                        text: visibleText.isEmpty ? "Done." : visibleText, createdAt: Date(), taskID: taskID
                    ),
                    toGroupWithID: group.id
                )
                guard let handoff else { break }
                if assignment.handoffCount >= BuddyGroupPolicy.maximumHandoffsPerMessage {
                    postNotice("\(ownerName) tried to hand this on again; stopping here.", inGroupWithID: group.id)
                } else {
                    postNotice("\(ownerName) handed this to \(handoff.target.name).", inGroupWithID: group.id)
                    pendingAssignments.append(Assignment(
                        groupID: group.id, ownerID: handoff.target.id, requestText: handoff.request,
                        handedOffByName: ownerName, handoffCount: assignment.handoffCount + 1
                    ))
                }
            case .failed(let reason):
                postNotice("\(ownerName) couldn't answer: \(reason)", inGroupWithID: group.id)
            case .cancelled, .interrupted, .running, .waitingForApproval:
                break
            }
        }
    }

    private func startWaitingAssignments() {
        var stillWaiting: [Assignment] = []
        for assignment in pendingAssignments {
            guard let group = groupStore.group(withID: assignment.groupID),
                  group.memberIDs.contains(assignment.ownerID),
                  let owner = buddyStore.buddy(withID: assignment.ownerID) else { continue }   // gone: drop it
            if buddyStore.isRunning(owner) || startRun(for: assignment, in: group, owner: owner) == false {
                stillWaiting.append(assignment)
            }
        }
        pendingAssignments = stillWaiting
    }

    /// True when the run started.
    private func startRun(for assignment: Assignment, in group: BuddyGroup, owner: WispBuddy) -> Bool {
        let members = members(of: group)
        let context = BuddyGroupPolicy.turnContext(
            in: groupStore.messages(ofGroupWithID: group.id), members: members
        )
        let (history, leadIn) = BuddyGroupPolicy.historyAndLeadIn(for: owner.id, in: context.prior, members: members)
        let request = BuddyRunRequest(
            origin: .message,
            text: BuddyGroupPolicy.runRequestText(
                requestText: assignment.requestText, context: context,
                handedOffBy: assignment.handedOffByName, leadIn: leadIn
            ),
            displayText: assignment.requestText,
            threadID: group.id,
            groupID: group.id,
            historyOverride: history,
            extraSystemPrompt: BuddyGroupPolicy.systemPromptAddendum(groupName: group.name, members: members, buddyID: owner.id)
        )
        guard let taskID = buddyStore.startGroupRun(ofBuddyWithID: owner.id, request: request) else { return false }
        activeAssignments[taskID] = assignment
        return true
    }

    private func postNotice(_ text: String, inGroupWithID groupID: UUID) {
        groupStore.append(
            BuddyGroupMessage(id: UUID(), author: .notice, text: text, createdAt: Date(), taskID: nil),
            toGroupWithID: groupID
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
