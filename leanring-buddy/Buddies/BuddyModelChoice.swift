//
//  BuddyModelChoice.swift
//  leanring-buddy
//
//  Which model a buddy runs on. Until now every buddy ran on whatever model
//  Wisp itself was set to, so a heavy job (research, browsing) and a light one
//  (a daily digest) both used the one local 3B model, one at a time. A buddy can
//  now pick its own: stay on the local model, or use a bring-your-own-key cloud
//  model such as Claude. A buddy with no choice follows Wisp's selection, so
//  nothing changes for existing buddies, and local stays the default.
//
//  A cloud choice means that buddy's job, thread and memory are sent off this
//  Mac (the picker says so), and the buddy is kept away from the brain and the
//  user's own memory (`BuddyRunToolPolicy`). It also lifts the one-at-a-time
//  limit: the local model is a single resident copy that must be shared, a
//  cloud model is not, so cloud buddies run side by side
//  (`BackgroundTaskCapacityPolicy`).
//

import Foundation

struct BuddyModelChoice: Codable, Equatable, Hashable, Identifiable {
    var providerKind: BuddyChatProviderKind
    /// Which Claude model, when `providerKind` is `.anthropic`; nil follows
    /// the Claude model chosen in Settings → Model.
    var claudeModel: AnthropicModelChoice?

    var id: String { "\(providerKind.rawValue)|\(claudeModel?.rawValue ?? "")" }

    /// Whether this buddy's requests leave this Mac.
    var sendsDataOffThisMachine: Bool { providerKind.sendsScreenshotsOffThisMachine }

    var displayName: String {
        switch providerKind {
        case .anthropic: return claudeModel?.displayName ?? providerKind.displayName
        default: return providerKind.displayName
        }
    }

    /// Every choice the picker offers, local first.
    static let allChoices: [BuddyModelChoice] =
        [BuddyModelChoice(providerKind: .localOllama, claudeModel: nil)]
        + AnthropicModelChoice.allCases.map { BuddyModelChoice(providerKind: .anthropic, claudeModel: $0) }
        + [
            BuddyModelChoice(providerKind: .openAI, claudeModel: nil),
            BuddyModelChoice(providerKind: .gemini, claudeModel: nil),
        ]
}

/// How many buddy runs may be in flight at once. Pure so it can be tested.
enum BackgroundTaskCapacityPolicy {
    /// Runs on the local model. They queue behind one resident copy anyway
    /// (`ModelAccessGate`), so more would only lengthen the queue.
    static let maximumLocalTasks = 2
    /// Runs on cloud models, which don't share a resident model. The ceiling is
    /// there for rate limits and the bill, not for memory.
    static let maximumCloudTasks = 4

    static func canStart(runsOffThisMachine: Bool, runningTotal: Int, runningOffThisMachine: Int) -> Bool {
        if runsOffThisMachine {
            return runningOffThisMachine < maximumCloudTasks
        }
        return (runningTotal - runningOffThisMachine) < maximumLocalTasks
    }
}
