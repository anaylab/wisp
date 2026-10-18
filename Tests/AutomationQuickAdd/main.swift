//
//  Quick add suite: which lines become a draft card and which carry on to the model.
//  Pure (AutomationQuickAddPlanner); the router glue and first-run flow are views.
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

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/New_York")!
calendar.locale = Locale(identifier: "en_US")
let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!

let buddies = [
    AutomationBuddyReference(id: UUID(), name: "Planner", specialty: .planner),
    AutomationBuddyReference(id: UUID(), name: "Briefer", specialty: .general),
]

func decide(_ text: String) -> AutomationQuickAddDecision {
    AutomationQuickAddPlanner.decide(transcript: text, now: now, calendar: calendar, buddies: buddies)
}

func opensDraft(_ text: String) -> Bool {
    if case .openDraft = decide(text) { return true }
    return false
}

// Requests that open the card.
check(opensDraft("every weekday at 8 tell me what's due today"), "weekday schedule opens a draft")
check(opensDraft("remind me tomorrow at 6pm to submit the form"), "remind me with a time opens a draft")
check(opensDraft("tell me when a new Canvas assignment shows up"), "event phrase opens a draft")
check(opensDraft("can you remind me tomorrow at 9 to call the dentist?"), "a request phrased as a question still opens a draft")

// The draft carries the original words and is not silently ready when a field was guessed.
if case .openDraft(let draft) = decide("every weekday at 8 tell me what's due today") {
    check(draft.originalText.lowercased().contains("weekday"), "draft keeps the original text")
}

// Ordinary turns fall through.
check(decide("what's the weather like").isFallThrough, "weather is a normal turn")
check(decide("text size bigger").isFallThrough, "text size is a normal turn")
check(decide("set a timer for 10 minutes").isFallThrough, "timers belong to the fast router")
check(decide("remind me in 10 minutes").isFallThrough, "relative reminders belong to the fast router")
check(decide("what happens every morning at a hospital?").isFallThrough, "a question mentioning a recurrence is a question")
check(decide("when does the library close?").isFallThrough, "when-question is a question")
check(decide("").isFallThrough, "empty falls through")
check(decide("hi").isFallThrough, "too short falls through")

// Question detection.
check(AutomationQuickAddPlanner.isPlainQuestion("why does it run every hour?"), "why-question")
check(!AutomationQuickAddPlanner.isPlainQuestion("remind me at 6 to stretch?"), "remind me with ? is a request")
check(!AutomationQuickAddPlanner.isPlainQuestion("every day at 7 tell me the news"), "no question mark is not a question")

extension AutomationQuickAddDecision {
    var isFallThrough: Bool { self == .fallThrough }
}

print("\(checkCount) checks, \(failureCount) failures")
exit(failureCount == 0 ? 0 : 1)
