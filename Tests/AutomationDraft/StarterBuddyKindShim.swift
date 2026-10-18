//
//  Test-only stand-in for `StarterBuddyKind` (Buddies/StarterBuddies.swift). The real file also
//  pulls in BuddyPersonality and BuddyMood, which the pure automation suites do not need.
//  Keep the cases in step with the real enum.
//

import Foundation

nonisolated enum StarterBuddyKind: String, Codable, CaseIterable, Sendable {
    case planner
    case briefer
    case focus
}

/// Test-only stand-in for `BuddySpecialty` (Buddies/BuddySpecialty.swift), which drags in the tool
/// access and Composio types. The automation suites only compare cases. Keep in step.
nonisolated enum BuddySpecialty: String, Codable, CaseIterable, Sendable {
    case researcher
    case inbox
    case planner
    case writer
    case coder
    case watcher
    case organizer
    case general
}
