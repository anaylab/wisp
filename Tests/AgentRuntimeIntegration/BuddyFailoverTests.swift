//
//  BuddyFailoverTests.swift
//
//  Phase 6 of docs/openbot-buddies-plan.md: backup models (when a run fails
//  over, when it mustn't, the 10-minute pass-over) and hidden buddies (no new
//  runs, no messages, no schedule backlog, no peer requests).
//

import Foundation

/// A provider that fails or answers as told, and records what it was asked.
final class FailoverTestProvider: ModelProvider, @unchecked Sendable {
    let identifier: String
    let capabilities = ModelCapabilities(supportsVision: true, supportsTools: true, supportsNativeToolCalls: false,
                                         supportsStreaming: true, contextWindowTokens: 16384)
    let deployment: ModelDeployment
    var failures: [Error] = []
    var deltasBeforeFailing: [String] = []
    var answer = "answer"
    private(set) var callCount = 0

    init(identifier: String, offThisMachine: Bool = false) {
        self.identifier = identifier
        deployment = ModelDeployment(location: offThisMachine ? .remote(serviceName: identifier) : .onThisMachine)
    }

    func streamTurn(_ request: ModelRequest, onTextDelta: @escaping @MainActor @Sendable (String) -> Void) async throws -> BuddyChatTurn {
        callCount += 1
        if !failures.isEmpty {
            for delta in deltasBeforeFailing { await onTextDelta(delta) }
            throw failures.removeFirst()
        }
        await onTextDelta(answer)
        return BuddyChatTurn(text: answer)
    }
}

@MainActor func buddyFailoverSuite() async {
    let request = ModelRequest(systemPrompt: "s", messages: [BuddyChatMessage(role: .user, text: "hi")])

    section("failover: which errors switch")
    check("failover: a usage limit switches", BuddyFailoverPolicy.isFailoverError(BuddyChatError.rateLimited(providerName: "x", retryAfter: nil)))
    check("failover: a missing key switches", BuddyFailoverPolicy.isFailoverError(BuddyChatError.authenticationFailed(providerName: "x")))
    check("failover: an outage switches", BuddyFailoverPolicy.isFailoverError(BuddyChatError.providerUnavailable(providerName: "x", underlyingDescription: nil)))
    check("failover: no network switches", BuddyFailoverPolicy.isFailoverError(URLError(.notConnectedToInternet)))
    check("failover: a timeout switches", BuddyFailoverPolicy.isFailoverError(URLError(.timedOut)))
    check("failover: stopping doesn't", !BuddyFailoverPolicy.isFailoverError(CancellationError()) && !BuddyFailoverPolicy.isFailoverError(URLError(.cancelled)))
    check("failover: a too-long request doesn't (a backup can't fix it)",
          !BuddyFailoverPolicy.isFailoverError(BuddyChatError.contextWindowExceeded(providerName: "x", requestedTokens: nil, limitTokens: 1)))
    check("failover: order skips held models first", BuddyFailoverPolicy.attemptOrder(memberCount: 3) { $0 == 0 } == [1, 2, 0])
    check("failover: when every model is held, the listed order", BuddyFailoverPolicy.attemptOrder(memberCount: 2) { _ in true } == [0, 1])
    let local = BuddyModelChoice(providerKind: .localOllama, claudeModel: nil)
    let claude = BuddyModelChoice(providerKind: .anthropic, claudeModel: .sonnet)
    let gemini = BuddyModelChoice(providerKind: .gemini, claudeModel: nil)
    check("failover: backups drop the buddy's own model and repeats",
          BuddyFailoverPolicy.cleanedBackups([local, claude, claude, gemini], primary: local) == [claude, gemini])
    check("failover: at most three backups", BuddyFailoverPolicy.cleanedBackups(BuddyModelChoice.allChoices, primary: nil).count == 3)

    section("failover: the provider")
    do {
        let holds = BuddyModelHolds()
        let primary = FailoverTestProvider(identifier: "local/qwen")
        primary.failures = [BuddyChatError.providerUnavailable(providerName: "Ollama", underlyingDescription: "not running")]
        let backup = FailoverTestProvider(identifier: "anthropic/sonnet", offThisMachine: true)
        backup.answer = "from the backup"
        final class Switches { var log: [String] = [] }
        let switches = Switches()
        let provider = FailoverModelProvider(members: [primary, backup], memberNames: ["Local", "Sonnet"], holds: holds) { from, to in
            switches.log.append("\(from)→\(to)")
        }
        let turn = try? await provider.streamTurn(request, onTextDelta: { _ in })
        check("provider: the backup answers when the model is down", turn?.text == "from the backup")
        check("provider: the switch is reported", switches.log == ["Local→Sonnet"])
        check("provider: it now reads as the backup (usage, capacity)", provider.identifier == "anthropic/sonnet" && provider.deployment.sendsDataOffThisMachine)
        check("provider: the failed model is passed over", holds.isHeld("local/qwen") && !holds.isHeld("anthropic/sonnet"))
        _ = try? await provider.streamTurn(request, onTextDelta: { _ in })
        check("provider: later calls of the run stay on the backup", primary.callCount == 1 && backup.callCount == 2)

        let nextRunPrimary = FailoverTestProvider(identifier: "local/qwen")
        let nextRunBackup = FailoverTestProvider(identifier: "anthropic/sonnet", offThisMachine: true)
        let nextRun = FailoverModelProvider(members: [nextRunPrimary, nextRunBackup], memberNames: ["Local", "Sonnet"], holds: holds)
        _ = try? await nextRun.streamTurn(request, onTextDelta: { _ in })
        check("provider: the next run starts on the backup while the model is passed over", nextRunPrimary.callCount == 0 && nextRunBackup.callCount == 1)
        check("provider: a run that starts there says so from the first call", nextRun.identifier == "anthropic/sonnet")
    }
    do {
        let holds = BuddyModelHolds()
        let primary = FailoverTestProvider(identifier: "a")
        primary.failures = [BuddyChatError.rateLimited(providerName: "A", retryAfter: nil)]
        primary.deltasBeforeFailing = ["Half an ans"]
        let backup = FailoverTestProvider(identifier: "b")
        let provider = FailoverModelProvider(members: [primary, backup], memberNames: ["A", "B"], holds: holds)
        var caught: Error?
        do { _ = try await provider.streamTurn(request, onTextDelta: { _ in }) } catch { caught = error }
        check("provider: text already shown means no switch", caught != nil && backup.callCount == 0)

        let noSwitchPrimary = FailoverTestProvider(identifier: "c")
        noSwitchPrimary.failures = [BuddyChatError.visionUnsupported(providerName: "C")]
        let noSwitchBackup = FailoverTestProvider(identifier: "d")
        let noSwitch = FailoverModelProvider(members: [noSwitchPrimary, noSwitchBackup], memberNames: ["C", "D"], holds: holds)
        _ = try? await noSwitch.streamTurn(request, onTextDelta: { _ in })
        check("provider: a request problem doesn't switch", noSwitchBackup.callCount == 0 && !holds.isHeld("c"))

        let answeredPrimary = FailoverTestProvider(identifier: "e")
        let answeredBackup = FailoverTestProvider(identifier: "f")
        let answered = FailoverModelProvider(members: [answeredPrimary, answeredBackup], memberNames: ["E", "F"], holds: holds)
        _ = try? await answered.streamTurn(request, onTextDelta: { _ in })
        answeredPrimary.failures = [BuddyChatError.rateLimited(providerName: "E", retryAfter: nil)]
        var laterError: Error?
        do { _ = try await answered.streamTurn(request, onTextDelta: { _ in }) } catch { laterError = error }
        check("provider: after the run has answered once, a failure isn't switched", laterError != nil && answeredBackup.callCount == 0)

        let allDownA = FailoverTestProvider(identifier: "g"), allDownB = FailoverTestProvider(identifier: "h")
        allDownA.failures = [BuddyChatError.rateLimited(providerName: "G", retryAfter: nil)]
        allDownB.failures = [BuddyChatError.authenticationFailed(providerName: "H")]
        var lastError: Error?
        do { _ = try await FailoverModelProvider(members: [allDownA, allDownB], memberNames: ["G", "H"], holds: holds).streamTurn(request, onTextDelta: { _ in }) } catch { lastError = error }
        check("provider: every model failing gives the last error", (lastError as? BuddyChatError).map { if case .authenticationFailed = $0 { return true } else { return false } } ?? false)

        holds.hold("x")
        let recovered = FailoverTestProvider(identifier: "x")
        _ = try? await FailoverModelProvider(members: [recovered], memberNames: ["X"], holds: holds).streamTurn(request, onTextDelta: { _ in })
        check("provider: a call that works ends the pass-over early", !holds.isHeld("x"))
    }

    section("failover: privacy and asking other buddies")
    do {
        var localBuddy = WispBuddy(id: UUID(), name: "Local", instruction: "j", colorIndex: 0, schedule: .once, createdAt: Date(),
                                   runTaskIDs: [], nextScheduledRunAt: nil, modelChoice: local)
        check("privacy: a local buddy stays local", !localBuddy.sendsDataOffThisMachine)
        localBuddy.backupModelChoices = [claude]
        check("privacy: a cloud backup makes it a cloud buddy from the start", localBuddy.sendsDataOffThisMachine)

        let caller = WispBuddy(id: UUID(), name: "Caller", instruction: "j", colorIndex: 0, schedule: .once, createdAt: Date(),
                               runTaskIDs: [], nextScheduledRunAt: nil, modelChoice: local)
        let broker = CapturingBroker(decision: .declined(reason: "no"))
        let service = BuddyDelegationService(
            buddies: { [caller, localBuddy] }, startRun: { _, _, _ in UUID() }, runRecord: { _ in nil },
            cancelRun: { _ in }, broker: broker, providerKind: { $0.modelChoice?.providerKind ?? .localOllama }
        )
        let reply = await service.askBuddy(from: caller, targetName: "Local", message: "my plans")
        check("asking: a peer with a cloud backup needs the user's ok", broker.askedInputs.count == 1 && reply.contains("didn't approve"), reply)
        let cardModels = broker.askedInputs.first.flatMap { input -> String? in
            if case .object(let object) = input.toolInput, case .string(let models)? = object["to_model"] { return models }
            return nil
        }
        check("asking: the card names the backup's provider", cardModels?.contains("Claude") == true || cardModels?.contains("Anthropic") == true, cardModels ?? "")

        var hiddenPeer = WispBuddy(id: UUID(), name: "Sleepy", instruction: "j", colorIndex: 0, schedule: .once, createdAt: Date(),
                                   runTaskIDs: [], nextScheduledRunAt: nil, modelChoice: local)
        hiddenPeer.isHidden = true
        let hiddenService = BuddyDelegationService(
            buddies: { [caller, hiddenPeer] }, startRun: { _, _, _ in UUID() }, runRecord: { _ in nil },
            cancelRun: { _ in }, broker: CapturingBroker(decision: .approved)
        )
        check("asking: a hidden buddy can't be asked", await hiddenService.askBuddy(from: caller, targetName: "Sleepy", message: "hi").contains("no other buddies"))
        check("asking: a hidden buddy isn't in the tool's peer list", BuddyDelegationToolBuilder.tool(for: caller, service: hiddenService) == nil)
    }

    section("hidden buddies")
    do {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let store = BuddyStore(buddiesFileURL: sandbox.appendingPathComponent("buddies.json"))
        var startedRuns: [BuddyRunRequest] = []
        store.start(runStarter: { _, request in startedRuns.append(request); return UUID() })
        let daily = store.createBuddy(instruction: "every morning check the news", schedule: .daily(hour: 9, minute: 0), runImmediately: false)
        store.setHidden(buddyWithID: daily.id, isHidden: true)

        check("hidden: a message is refused", !store.sendMessage("hello", toBuddyWithID: daily.id))
        check("hidden: Run now starts nothing", !store.runNow(buddyWithID: daily.id) && startedRuns.isEmpty)
        let dueDate = store.buddy(withID: daily.id)?.nextScheduledRunAt ?? Date()
        store.runDueBuddies(now: dueDate.addingTimeInterval(60))
        check("hidden: its schedule's slot passes without running", startedRuns.isEmpty)
        check("hidden: the slot is skipped, not saved for later", (store.buddy(withID: daily.id)?.nextScheduledRunAt ?? .distantPast) > dueDate)
        check("hidden: a waiting message says why",
              BuddyRunHoldReason.hidden.displayText.contains("show this buddy"))

        store.setHidden(buddyWithID: daily.id, isHidden: false)
        check("shown again: it takes messages", store.sendMessage("hello again", toBuddyWithID: daily.id) && startedRuns.count == 1)
        check("shown again: the next slot is in the future, so no backlog", (store.buddy(withID: daily.id)?.nextScheduledRunAt ?? .distantPast) > Date())
    }

    if ProcessInfo.processInfo.environment["WISP_LIVE_CLAUDE"] == "1" {
        section("failover: live (a local model that isn't running, then Claude Haiku)")
        let holds = BuddyModelHolds()
        let deadLocalModel = OllamaProvider(baseURL: "http://localhost:9", model: "qwen2.5vl:3b")
        let provider = FailoverModelProvider(
            members: [deadLocalModel, ClaudeSubscriptionProvider(modelChoice: .haiku, effortLevel: .low)],
            memberNames: ["Local", "Claude Haiku 4.5"], holds: holds
        )
        do {
            let turn = try await provider.streamTurn(
                ModelRequest(systemPrompt: "You are terse.", messages: [BuddyChatMessage(role: .user, text: "Reply with exactly the word: pong")]),
                onTextDelta: { _ in }
            )
            check("live failover: the backup answered", turn.text.lowercased().contains("pong"), turn.text)
            check("live failover: the dead model is passed over", holds.isHeld(deadLocalModel.identifier))
        } catch {
            check("live failover: a refused connection switches", false, "\(type(of: error)): \(error.localizedDescription)")
        }
    }
}
