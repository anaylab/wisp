//
//  Buddy personality suite: what each work style puts in the prompt, how it is
//  clamped and mapped, the checklist streak, and who greets the user each day.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

// MARK: - The five styles

check(BuddyPersonality.allCases.count == 5, "five personalities")
check(Set(BuddyPersonality.allCases.map(\.title)).count == 5, "titles are distinct")
check(Set(BuddyPersonality.allCases.map(\.personaLine)).count == 5, "every personality has its own persona line")
check(BuddyPersonality.allCases.allSatisfy { !$0.tagline.isEmpty && !$0.symbolName.isEmpty }, "tagline and symbol are filled in")
check(BuddyPersonality.allCases.allSatisfy { $0.personaLine.contains("never changes what you are allowed to do") },
      "every persona line says it grants nothing")
check(BuddyPersonality.allCases.allSatisfy {
    $0.personaLine.contains("about \($0.replyStyle.maximumSentences) sentences")
}, "the persona line states the reply length")
check(BuddyPersonality.deadpan.replyStyle.maximumSentences < BuddyPersonality.teacher.replyStyle.maximumSentences,
      "deadpan is briefer than teacher")
check(BuddyPersonality.hype.replyStyle.usesEmoji && BuddyPersonality.hype.personaLine.contains("emoji is fine"),
      "hype may use an occasional emoji")
check(BuddyPersonality.coach.personaLine.contains("Don't use emoji."), "coach does not use emoji")
check(!BuddyPersonality.allCases.contains { $0.personaLine.lowercased().contains("roleplay") && !$0.personaLine.contains("never") },
      "no roleplay wording")

// Codable raw values are stable (they are stored in buddies.json).
check(BuddyPersonality.coach.rawValue == "coach" && BuddyPersonality(rawValue: "deadpan") == .deadpan, "raw values are stable")
let encodedPersonality = try! JSONEncoder().encode([BuddyPersonality.teacher])
check(String(data: encodedPersonality, encoding: .utf8) == "[\"teacher\"]", "encodes as its raw value")

// MARK: - Voice

check(BuddyVoiceProfile(kokoroVoiceIdentifier: "af_heart", speakingRate: 3).speakingRate == 1.25, "speaking rate clamps high")
check(BuddyVoiceProfile(kokoroVoiceIdentifier: "af_heart", speakingRate: 0.1).speakingRate == 0.8, "speaking rate clamps low")
check(BuddyVoiceProfile(kokoroVoiceIdentifier: "af_heart", speakingRate: 1.0).speakingRate == 1.0, "normal speed unchanged")
check(BuddyPersonality.allCases.allSatisfy {
    BuddyVoiceProfile.allowedSpeakingRateRange.contains($0.voice.speakingRate) && !$0.voice.kokoroVoiceIdentifier.isEmpty
}, "every preset voice is in range")
check(BuddyPersonality.hype.voice.speakingRate > BuddyPersonality.chill.voice.speakingRate, "hype speaks faster than chill")

// MARK: - Reaction

check(BuddyPersonality.allCases.allSatisfy { (0...2).contains($0.reaction.celebrationLevel) }, "celebration levels are 0...2")
check(BuddyPersonality.hype.reaction.celebrationLevel == 2, "hype gets the bounce and burst")
check(BuddyPersonality.chill.reaction.celebrationLevel == 0 && BuddyPersonality.deadpan.reaction.celebrationLevel == 0,
      "chill and deadpan stay composed")

let allMoods: [BuddyMood] = [.idle, .working, .happy, .sleepy, .oops, .waiting]
for personality in BuddyPersonality.allCases {
    let moodWords = allMoods.map { personality.reaction.moodWord(for: $0) }
    check(moodWords.allSatisfy { !$0.isEmpty }, "\(personality.title) has a word for every mood")
    check(Set(moodWords).count == moodWords.count, "\(personality.title)'s mood words are distinct")
}
check(BuddyPersonality.hype.reaction.moodWord(for: .happy) != BuddyPersonality.deadpan.reaction.moodWord(for: .happy),
      "the same mood reads differently per personality")

// MARK: - Prompt projection

let neutralAddendum = BuddyThreadPolicy.systemPromptAddendum(buddyName: "Planner", job: "plan my day")
let defaultedAddendum = BuddyThreadPolicy.systemPromptAddendum(
    buddyName: "Planner", job: "plan my day", specialtyLine: nil, personalityLine: nil
)
check(neutralAddendum == defaultedAddendum, "no personality leaves the prompt exactly as before")
check(!neutralAddendum.contains("Work style"), "a neutral buddy has no work-style line")

let specialtyLine = "You are a planner."
let personalityAddendum = BuddyThreadPolicy.systemPromptAddendum(
    buddyName: "Planner",
    job: "plan my day",
    specialtyLine: specialtyLine,
    personalityLine: BuddyPersonality.coach.personaLine
)
check(personalityAddendum.contains(BuddyPersonality.coach.personaLine), "the personality line is in the prompt")
check(personalityAddendum.contains("Planner") && personalityAddendum.contains("plan my day"), "the buddy's name and job are still there")
if let specialtyRange = personalityAddendum.range(of: specialtyLine),
   let personalityRange = personalityAddendum.range(of: BuddyPersonality.coach.personaLine),
   let nameRange = personalityAddendum.range(of: "You are Planner") {
    check(specialtyRange.lowerBound < personalityRange.lowerBound, "the personality line follows the specialty line")
    check(personalityRange.lowerBound < nameRange.lowerBound, "both persona lines come before the job paragraph")
} else {
    check(false, "specialty, personality and job text are all present")
}
let personalityOnlyAddendum = BuddyThreadPolicy.systemPromptAddendum(
    buddyName: "Planner", job: "plan my day", personalityLine: BuddyPersonality.teacher.personaLine
)
check(personalityOnlyAddendum.hasPrefix("\n\n" + BuddyPersonality.teacher.personaLine), "a personality without a specialty starts the addendum")

// MARK: - Checklist streak

var testCalendar = Calendar(identifier: .gregorian)
testCalendar.timeZone = TimeZone(identifier: "America/New_York")!
func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
    testCalendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
}
func keys(_ dates: [Date]) -> Set<String> {
    Set(dates.map { ChecklistStreakPolicy.dayKey(for: $0, calendar: testCalendar) })
}

check(ChecklistStreakPolicy.dayKey(for: day(2026, 10, 7), calendar: testCalendar) == "2026-10-07", "day key is zero-padded")
check(ChecklistStreakPolicy.currentStreak(completedDayKeys: [], today: day(2026, 10, 17), calendar: testCalendar) == 0, "no days, no streak")
check(ChecklistStreakPolicy.currentStreak(
    completedDayKeys: keys([day(2026, 10, 15), day(2026, 10, 16), day(2026, 10, 17)]),
    today: day(2026, 10, 17), calendar: testCalendar) == 3, "three days ending today")
check(ChecklistStreakPolicy.currentStreak(
    completedDayKeys: keys([day(2026, 10, 15), day(2026, 10, 16)]),
    today: day(2026, 10, 17), calendar: testCalendar) == 2, "a streak ending yesterday is still alive today")
check(ChecklistStreakPolicy.currentStreak(
    completedDayKeys: keys([day(2026, 10, 14), day(2026, 10, 15)]),
    today: day(2026, 10, 17), calendar: testCalendar) == 0, "a streak that ended two days ago is broken")
check(ChecklistStreakPolicy.currentStreak(
    completedDayKeys: keys([day(2026, 10, 12), day(2026, 10, 14), day(2026, 10, 15), day(2026, 10, 16)]),
    today: day(2026, 10, 16), calendar: testCalendar) == 3, "a gap ends the streak")
check(ChecklistStreakPolicy.currentStreak(
    completedDayKeys: keys([day(2026, 2, 27), day(2026, 2, 28), day(2026, 3, 1)]),
    today: day(2026, 3, 1), calendar: testCalendar) == 3, "month boundaries count")
// US spring-forward (2026-03-08 has 23 hours) must not break a streak.
check(ChecklistStreakPolicy.currentStreak(
    completedDayKeys: keys([day(2026, 3, 7), day(2026, 3, 8), day(2026, 3, 9)]),
    today: day(2026, 3, 9, hour: 0), calendar: testCalendar) == 3, "a short DST day doesn't break the streak")
check(ChecklistStreakPolicy.trimmed(Set((0..<500).map { String(format: "2025-%03d", $0) })).count == ChecklistStreakPolicy.maximumRememberedDays,
      "old day keys are trimmed")

MainActor.assumeIsolated {
    // Store: idempotent per day, trigger counts celebrations, persists.
    let suiteName = "BuddyPersonalityTests-\(UUID().uuidString)"
    let isolatedDefaults = UserDefaults(suiteName: suiteName)!
    defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
    let streakToday = day(2026, 10, 17)
    let streakStore = ChecklistStreakStore(userDefaults: isolatedDefaults, calendar: testCalendar, today: streakToday)
    check(streakStore.currentStreakDays == 0 && streakStore.celebrationTrigger == 0, "a fresh store has no streak")
    streakStore.recordChecklistFinished(today: streakToday)
    check(streakStore.currentStreakDays == 1 && streakStore.celebrationTrigger == 1, "finishing today starts a streak and celebrates")
    streakStore.recordChecklistFinished(today: streakToday)
    check(streakStore.celebrationTrigger == 1, "recording the same day again doesn't celebrate twice")
    streakStore.recordChecklistFinished(today: day(2026, 10, 18))
    check(streakStore.currentStreakDays == 2 && streakStore.celebrationTrigger == 2, "the next day extends the streak")
    let reloadedStreakStore = ChecklistStreakStore(userDefaults: isolatedDefaults, calendar: testCalendar, today: day(2026, 10, 18))
    check(reloadedStreakStore.currentStreakDays == 2, "the streak survives a restart")
    reloadedStreakStore.refreshStreak(today: day(2026, 10, 21))
    check(reloadedStreakStore.currentStreakDays == 0, "a lapsed streak reads 0 after refresh")

}

// MARK: - Day buddy and greeting

let briefer = UUID()
let planner = UUID()
let focus = UUID()
let allBuddyIDs = [planner, briefer, focus]
check(BuddyGreetingPolicy.dayBuddyID(candidateBuddyIDs: [], preferredBuddyID: briefer, dayKey: "2026-10-17") == nil, "no buddies, no greeter")
check(BuddyGreetingPolicy.dayBuddyID(candidateBuddyIDs: [planner], preferredBuddyID: briefer, dayKey: "2026-10-17") == planner,
      "a missing preferred buddy is ignored")
check(BuddyGreetingPolicy.dayBuddyID(candidateBuddyIDs: allBuddyIDs, preferredBuddyID: briefer, dayKey: "2026-10-17")
      == BuddyGreetingPolicy.dayBuddyID(candidateBuddyIDs: allBuddyIDs, preferredBuddyID: briefer, dayKey: "2026-10-17"),
      "the same day always picks the same buddy")
var greeterCounts: [UUID: Int] = [:]
for dayNumber in 1...120 {
    let dayKey = String(format: "2026-%02d-%02d", (dayNumber - 1) / 28 + 1, (dayNumber - 1) % 28 + 1)
    if let greeterID = BuddyGreetingPolicy.dayBuddyID(candidateBuddyIDs: allBuddyIDs, preferredBuddyID: briefer, dayKey: dayKey) {
        greeterCounts[greeterID, default: 0] += 1
    }
}
check(greeterCounts.count == 3, "over many days every buddy gets a turn")
check((greeterCounts[briefer] ?? 0) > (greeterCounts[planner] ?? 0) && (greeterCounts[briefer] ?? 0) > (greeterCounts[focus] ?? 0),
      "the Briefer greets more often than the others")

for personality in BuddyPersonality.allCases {
    let greetings = [6, 14, 21].map { BuddyGreetingPolicy.greetingLine(for: personality, buddyName: "X", hour: $0) }
    check(Set(greetings).count == 3 && greetings.allSatisfy { !$0.isEmpty }, "\(personality.title) greets differently morning, afternoon and evening")
}
check(BuddyGreetingPolicy.greetingLine(for: nil, buddyName: "X", hour: 8) == "Good morning.", "a neutral buddy greets plainly")
check(BuddyGreetingPolicy.greetingLine(for: .hype, buddyName: "X", hour: 8) != BuddyGreetingPolicy.greetingLine(for: .deadpan, buddyName: "X", hour: 8),
      "personalities greet in their own voice")

print("\(checkCount) checks, \(failureCount) failures")
exit(failureCount == 0 ? 0 : 1)
