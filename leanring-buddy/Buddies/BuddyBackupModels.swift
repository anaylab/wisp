//
//  BuddyBackupModels.swift
//  leanring-buddy
//
//  Backup models for a buddy (phase 6 of docs/openbot-buddies-plan.md;
//  OpenBot's backup models and failover).
//
//  A buddy can list up to three backups after its own model. When a run's
//  first model call fails with a provider-side problem — a usage limit, the
//  service down, a missing or rejected key, no network, a timeout — and the
//  run hasn't done anything yet (no text streamed, no tool run), the call is
//  made again on the next backup, with no error shown. The model that failed
//  is passed over for 10 minutes, so the buddy's next runs start on the backup
//  straight away; a call that succeeds on it ends that early.
//
//  A run that already wrote text or ran a tool fails with its error, as with
//  no backup: replaying half a turn on another model would show the user the
//  start of one answer and the rest of another, or run a tool twice.
//
//  Privacy: a backup off this Mac counts from the start of the run. A local
//  buddy with a cloud backup is treated as a cloud buddy for what it may read
//  (no brain or personal memory) and for asking another buddy, because any of
//  its calls might end up there (`BuddyFailoverPolicy.runMaySendDataOffThisMachine`).
//

import Foundation

nonisolated enum BuddyFailoverPolicy {
    static let maximumBackupModels = 3
    /// How long a model that failed is passed over.
    static let holdSeconds: TimeInterval = 10 * 60

    /// Whether an error is the provider's problem, which another model may not
    /// have — as opposed to the request's (too long, needs vision) or the user's
    /// (stopped it), which a backup can't fix.
    static func isFailoverError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let chatError = error as? BuddyChatError {
            switch chatError {
            case .rateLimited, .authenticationFailed, .providerUnavailable: return true
            default: return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return false
            case .timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                return true
            default: return false
            }
        }
        return false
    }

    /// The order to try models in: the first not passed over, then the rest
    /// in their listed order; when every one is passed over, the listed order.
    static func attemptOrder(memberCount: Int, isHeld: (Int) -> Bool) -> [Int] {
        let allIndices = Array(0..<memberCount)
        let readyIndices = allIndices.filter { !isHeld($0) }
        guard !readyIndices.isEmpty else { return allIndices }
        return readyIndices + allIndices.filter(isHeld)
    }

    /// The backups worth keeping: not the buddy's own model, no repeats, capped.
    static func cleanedBackups(_ backups: [BuddyModelChoice], primary: BuddyModelChoice?) -> [BuddyModelChoice] {
        var cleaned: [BuddyModelChoice] = []
        for backup in backups where backup != primary && !cleaned.contains(backup) {
            cleaned.append(backup)
        }
        return Array(cleaned.prefix(maximumBackupModels))
    }

    static func runMaySendDataOffThisMachine(primarySendsDataOffThisMachine: Bool, backups: [BuddyModelChoice]) -> Bool {
        primarySendsDataOffThisMachine || backups.contains(where: \.sendsDataOffThisMachine)
    }

    /// The step a run's history shows when it switched.
    static func switchStepSummary(fromModelName: String, toModelName: String) -> String {
        "\(fromModelName) didn't answer, so \(toModelName) took over"
    }
}

/// Models passed over after a failure, by provider identifier. Shared by every
/// buddy, since a usage limit or an outage is the provider's, not one buddy's.
/// Lock-guarded: providers run off the main actor.
nonisolated final class BuddyModelHolds: @unchecked Sendable {
    static let shared = BuddyModelHolds()

    private let lock = NSLock()
    private var heldUntilByIdentifier: [String: Date] = [:]

    func isHeld(_ identifier: String, at date: Date = Date()) -> Bool {
        lock.withLock { (heldUntilByIdentifier[identifier] ?? .distantPast) > date }
    }

    func hold(_ identifier: String, from date: Date = Date()) {
        lock.withLock { heldUntilByIdentifier[identifier] = date.addingTimeInterval(BuddyFailoverPolicy.holdSeconds) }
    }

    func release(_ identifier: String) {
        lock.withLock { _ = heldUntilByIdentifier.removeValue(forKey: identifier) }
    }
}

/// A buddy's own model followed by its backups, presented as one provider so
/// the agent loop, the usage log and everything else see a single model: the
/// one answering. It may switch only on a run's first call; after that it
/// stays on whichever model answered.
final class FailoverModelProvider: ModelProvider, @unchecked Sendable {
    private let members: [any ModelProvider]
    private let memberNames: [String]
    private let holds: BuddyModelHolds
    /// Told when a backup takes over (from the failed model's name, to the backup's).
    private let onSwitch: @MainActor @Sendable (String, String) -> Void

    private let lock = NSLock()
    private var activeMemberIndex = 0
    private var hasAnsweredOnce = false

    init(
        members: [any ModelProvider],
        memberNames: [String],
        holds: BuddyModelHolds = .shared,
        onSwitch: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in }
    ) {
        precondition(!members.isEmpty && members.count == memberNames.count)
        self.members = members
        self.memberNames = memberNames
        self.holds = holds
        self.onSwitch = onSwitch
        // A run that starts while the buddy's own model is passed over starts on the backup.
        activeMemberIndex = BuddyFailoverPolicy.attemptOrder(memberCount: members.count) { holds.isHeld(members[$0].identifier) }.first ?? 0
    }

    private var activeMember: any ModelProvider { lock.withLock { members[activeMemberIndex] } }

    var identifier: String { activeMember.identifier }
    var capabilities: ModelCapabilities { activeMember.capabilities }
    var deployment: ModelDeployment { activeMember.deployment }

    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        let (alreadyAnswered, startIndex) = lock.withLock { (hasAnsweredOnce, activeMemberIndex) }
        if alreadyAnswered { return try await members[startIndex].streamTurn(request, onTextDelta: onTextDelta) }

        let attemptOrder = [startIndex] + BuddyFailoverPolicy.attemptOrder(memberCount: members.count) {
            holds.isHeld(members[$0].identifier)
        }.filter { $0 != startIndex }
        var lastError: Error?
        for (attemptNumber, memberIndex) in attemptOrder.enumerated() {
            let member = members[memberIndex]
            let streamedText = StreamedTextFlag()
            do {
                let turn = try await member.streamTurn(request) { delta in
                    streamedText.didStream = true
                    onTextDelta(delta)
                }
                holds.release(member.identifier)
                lock.withLock {
                    activeMemberIndex = memberIndex
                    hasAnsweredOnce = true
                }
                if attemptNumber > 0 {
                    await onSwitch(memberNames[attemptOrder[0]], memberNames[memberIndex])
                }
                return turn
            } catch {
                // Text already on screen can't be taken back, so no switch then.
                guard !streamedText.didStream, BuddyFailoverPolicy.isFailoverError(error) else { throw error }
                holds.hold(member.identifier)
                print("🔁 \(memberNames[memberIndex]) failed (\(error.localizedDescription)); trying the next model")
                lastError = error
            }
        }
        throw lastError ?? BuddyChatError.providerUnavailable(providerName: memberNames[0], underlyingDescription: nil)
    }
}

/// Whether a member streamed any text before failing.
private final class StreamedTextFlag: @unchecked Sendable {
    var didStream = false
}
