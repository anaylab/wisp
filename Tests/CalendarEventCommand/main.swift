//
//  Calendar event command suite: which sentences are scheduling requests,
//  what title/place/time each becomes, and which are declined or handed to
//  extraction. NSDataDetector resolves relative days against the real clock,
//  so day checks are relational (the right weekday, in the future).
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

let calendar = Calendar.current
let now = Date()

func draft(_ transcript: String) -> CalendarEventDraft? {
    if case .draft(let parsedDraft) = CalendarEventCommandParser.parse(transcript, now: now, calendar: calendar) {
        return parsedDraft
    }
    return nil
}

func outcome(_ transcript: String) -> CalendarEventCommandParseOutcome {
    CalendarEventCommandParser.parse(transcript, now: now, calendar: calendar)
}

func hour(_ date: Date) -> Int { calendar.component(.hour, from: date) }
func minute(_ date: Date) -> Int { calendar.component(.minute, from: date) }
func weekday(_ date: Date) -> Int { calendar.component(.weekday, from: date) }

// MARK: - Recognised, fully parsed

if let lunch = draft("Add lunch with Sam friday at 1 at Tartine to my calendar.") {
    check(lunch.title == "Lunch with Sam", "lunch title: \(lunch.title)")
    check(lunch.location == "Tartine", "lunch location: \(String(describing: lunch.location))")
    check(weekday(lunch.startDate) == 6, "lunch is on a friday")
    check(hour(lunch.startDate) == 13, "lunch at 1pm: \(hour(lunch.startDate))")
    check(lunch.endDate.timeIntervalSince(lunch.startDate) == 3600, "lunch defaults to an hour")
    check(!lunch.isAllDay, "lunch is timed")
} else { check(false, "lunch with sam parsed") }

if let dentist = draft("schedule the dentist thursday at 3pm for 30 minutes") {
    check(dentist.title == "Dentist", "dentist title: \(dentist.title)")
    check(hour(dentist.startDate) == 15, "dentist at 3pm")
    check(weekday(dentist.startDate) == 5, "dentist on thursday")
    check(dentist.endDate.timeIntervalSince(dentist.startDate) == 1800, "dentist lasts 30 minutes")
} else { check(false, "dentist parsed") }

if let sync = draft("schedule team sync next tuesday from 2 to 3:30") {
    check(sync.title == "Team sync", "team sync title: \(sync.title)")
    check(hour(sync.startDate) == 14, "team sync at 2pm")
    check(sync.endDate.timeIntervalSince(sync.startDate) == 5400, "team sync lasts 90 minutes")
} else { check(false, "team sync parsed") }

if let meeting = draft("create a meeting with the design team tomorrow at 10am for an hour") {
    check(meeting.title == "Meeting with the design team", "meeting keeps the noun: \(meeting.title)")
    check(hour(meeting.startDate) == 10, "meeting at 10")
    check(calendar.isDateInTomorrow(meeting.startDate), "meeting is tomorrow")
} else { check(false, "meeting parsed") }

if let named = draft("create an event called design review on friday at 2pm") {
    check(named.title == "Design review", "event called: \(named.title)")
} else { check(false, "event called parsed") }

if let flight = draft("put flight to denver on october 12 on my calendar") {
    check(flight.title == "Flight to denver", "flight title: \(flight.title)")
    check(flight.isAllDay, "a date with no time is all-day")
    check(calendar.component(.month, from: flight.startDate) == 10, "flight in october")
    check(calendar.component(.day, from: flight.startDate) == 12, "flight on the 12th")
    check(hour(flight.startDate) == 0, "all-day starts at midnight")
} else { check(false, "flight parsed") }

if let dinner = draft("add dinner tonight at 7 to my calendar") {
    check(dinner.title == "Dinner", "a noun swallowed by the time phrase is kept: \(dinner.title)")
    check(hour(dinner.startDate) == 19, "dinner at 7pm")
} else { check(false, "dinner parsed") }

if let call = draft("can you schedule call with mom at 6") {
    check(call.title == "Call with mom", "call title: \(call.title)")
    check(hour(call.startDate) == 18, "bare 'at 6' means 6pm")
    check(call.startDate > now, "bare time is the next one ahead")
} else { check(false, "call with mom parsed") }

if let standup = draft("new event standup at 9am tomorrow") {
    check(standup.title == "Standup", "standup title: \(standup.title)")
    check(hour(standup.startDate) == 9, "standup at 9am")
} else { check(false, "standup parsed") }

if let coffee = draft("schedule coffee at blue bottle with priya tomorrow at 8:30am") {
    check(coffee.title == "Coffee with priya", "'with' after the place stays in the title: \(coffee.title)")
    check(coffee.location == "Blue bottle", "coffee location: \(String(describing: coffee.location))")
    check(minute(coffee.startDate) == 30, "coffee at :30")
} else { check(false, "coffee parsed") }

if let soon = draft("schedule focus block in 2 hours") {
    check(abs(soon.startDate.timeIntervalSince(now) - 7200) < 1, "in 2 hours")
    check(soon.title == "Focus block", "focus block title: \(soon.title)")
} else { check(false, "in 2 hours parsed") }

// MARK: - Declined: not a calendar request

for notACommand in [
    "what's on my calendar today",
    "add milk to my shopping list",
    "put safari on the left",
    "schedule an email to sam for tomorrow at 9",
    "schedule a text to mom at 6",
    "remind me to call the bank tomorrow at 9",
    "set a timer for 10 minutes",
    "open calendar",
    "add to my calendar",
    "schedule gym every monday at 7am",
    "willow lunch friday at 1",
] {
    check(outcome(notACommand) == .notACalendarCommand, "declined: \(notACommand) → \(outcome(notACommand))")
}

// MARK: - Recognised but handed to extraction

if case .needsExtraction(let requestBody) = outcome("schedule something with the team sometime soon") {
    check(requestBody == "something with the team sometime soon", "extraction body: \(requestBody)")
} else { check(false, "a request with no time goes to extraction") }

// MARK: - Checking the on-device model's extraction

let extractionBody = "catch up w sam around 1 friday at tartine"
if let extracted = CalendarEventCommandParser.draft(
    fromExtractedTitle: "catch up w sam",
    extractedLocation: "tartine",
    extractedWhenPhrase: "1 friday",
    requestBody: extractionBody,
    now: now,
    calendar: calendar
) {
    check(extracted.title == "Catch up w sam", "extracted title: \(extracted.title)")
    check(extracted.location == "Tartine", "extracted location kept")
} else {
    // The detector may not read "1 friday"; a declined extraction is safe.
    check(CalendarEventCommandParser.draft(
        fromExtractedTitle: "catch up w sam", extractedLocation: nil,
        extractedWhenPhrase: "friday", requestBody: extractionBody, now: now, calendar: calendar
    ) != nil, "extraction with a plain day phrase")
}

check(CalendarEventCommandParser.draft(
    fromExtractedTitle: "Quarterly Planning Sync",
    extractedLocation: nil,
    extractedWhenPhrase: "friday",
    requestBody: "planning friday",
    now: now,
    calendar: calendar
) == nil, "a title with words the user never said is rejected")

check(CalendarEventCommandParser.draft(
    fromExtractedTitle: "planning",
    extractedLocation: nil,
    extractedWhenPhrase: "next monday at 9",
    requestBody: "planning friday",
    now: now,
    calendar: calendar
) == nil, "a time phrase the user never said is rejected")

if let withInventedPlace = CalendarEventCommandParser.draft(
    fromExtractedTitle: "planning",
    extractedLocation: "Conference Room B",
    extractedWhenPhrase: "friday",
    requestBody: "planning friday",
    now: now,
    calendar: calendar
) {
    check(withInventedPlace.location == nil, "an invented place is dropped")
} else { check(false, "invented place still yields a draft") }

if let timeAsPlace = CalendarEventCommandParser.draft(
    fromExtractedTitle: "quick sync with priya",
    extractedLocation: "next wednesday afternoon",
    extractedWhenPhrase: "next wednesday afternoon around 3",
    requestBody: "quick sync with priya next wednesday afternoon around 3ish",
    now: now,
    calendar: calendar
) {
    check(timeAsPlace.location == nil, "a 'place' made of time words is dropped")
} else { check(false, "time-as-place still yields a draft") }

// MARK: - When resolver details

check(CalendarEventWhenResolver.phraseStatesTimeOfDay("friday at 1"), "'at 1' is a time")
check(!CalendarEventWhenResolver.phraseStatesTimeOfDay("october 12"), "'october 12' is a day")
check(!CalendarEventWhenResolver.phraseStatesTimeOfDay("on the 12th"), "'the 12th' is a day")
check(CalendarEventWhenResolver.phraseStatesTimeOfDay("tomorrow 2-4pm"), "a range is a time")

let duration = CalendarEventCommandParser.removingDurationPhrase(from: "standup for half an hour tomorrow")
check(duration.durationSeconds == 1800, "half an hour")
check(duration.text == "standup tomorrow", "duration removed: \(duration.text)")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
