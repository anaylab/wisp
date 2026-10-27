//
//  BuddyGreeting.swift
//  leanring-buddy
//
//  Who greets you on Today, and what they say. The day's buddy is chosen by a
//  stable rule (the same buddy all day, a different one tomorrow, the Briefer
//  favoured) and speaks in its personality's voice. Pure, so it is tested without
//  the app; `BuddyStore` supplies the buddies.
//

import Foundation

nonisolated enum BuddyGreetingPolicy {
    /// The buddy for `dayKey` ("2026-10-17"), or nil with no buddies. The preferred
    /// buddy (the Briefer) is entered twice so it greets about twice as often as
    /// any other, while the choice still changes from day to day. The index comes
    /// from the day key's characters, not `Hasher`, which is seeded per launch and
    /// would pick a different buddy every time the app opened.
    static func dayBuddyID(candidateBuddyIDs: [UUID], preferredBuddyID: UUID?, dayKey: String) -> UUID? {
        guard !candidateBuddyIDs.isEmpty else { return nil }
        var weightedCandidates = candidateBuddyIDs
        if let preferredBuddyID, candidateBuddyIDs.contains(preferredBuddyID) {
            weightedCandidates.append(preferredBuddyID)
        }
        let dayKeyValue = dayKey.unicodeScalars.reduce(0) { runningTotal, scalar in
            (runningTotal &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        return weightedCandidates[dayKeyValue % weightedCandidates.count]
    }

    /// A short greeting in the buddy's own voice, by time of day. A buddy with no
    /// personality gets the plain version.
    static func greetingLine(for personality: BuddyPersonality?, buddyName: String, hour: Int) -> String {
        let timeOfDay = TimeOfDay(hour: hour)
        switch personality {
        case .coach:
            switch timeOfDay {
            case .morning: return "Morning. Let's pick the one thing that counts today."
            case .afternoon: return "Afternoon. Where are we on today's list?"
            case .evening: return "Evening. Finish strong, then rest."
            }
        case .chill:
            switch timeOfDay {
            case .morning: return "Morning. No rush, we'll get through it."
            case .afternoon: return "Hey. Easy afternoon, one thing at a time."
            case .evening: return "Evening. Take it slow."
            }
        case .hype:
            switch timeOfDay {
            case .morning: return "Good morning! Today is going to be a good one."
            case .afternoon: return "Afternoon! Let's keep the streak rolling."
            case .evening: return "Evening! Look how much you got done."
            }
        case .deadpan:
            switch timeOfDay {
            case .morning: return "Morning. The day has begun."
            case .afternoon: return "Afternoon. Still here."
            case .evening: return "Evening. Nearly over."
            }
        case .teacher:
            switch timeOfDay {
            case .morning: return "Good morning. Let's plan today so it makes sense."
            case .afternoon: return "Good afternoon. A good moment to review what's done."
            case .evening: return "Good evening. What did we learn today?"
            }
        case nil:
            switch timeOfDay {
            case .morning: return "Good morning."
            case .afternoon: return "Good afternoon."
            case .evening: return "Good evening."
            }
        }
    }

    private enum TimeOfDay {
        case morning, afternoon, evening

        init(hour: Int) {
            switch hour {
            case 0..<12: self = .morning
            case 12..<18: self = .afternoon
            default: self = .evening
            }
        }
    }
}
