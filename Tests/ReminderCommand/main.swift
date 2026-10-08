//
//  Reminder command suite: which sentences are reminder requests, the title,
//  due date and list each becomes, and which are declined or handed to
//  extraction. Day checks are relational, since NSDataDetector resolves
//  relative days against the real clock.
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

func outcome(_ transcript: String) -> ReminderCommandParseOutcome {
    ReminderCommandParser.parse(transcript, now: now, calendar: calendar)
}

func draft(_ transcript: String) -> ReminderDraft? {
    if case .draft(let parsedDraft) = outcome(transcript) { return parsedDraft }
    return nil
}

func hour(_ date: Date?) -> Int? { date.map { calendar.component(.hour, from: $0) } }

// MARK: - Recognised, fully parsed

if let bank = draft("Remind me to call the bank tomorrow at 9am.") {
    check(bank.title == "Call the bank", "bank title: \(bank.title)")
    check(hour(bank.dueDate) == 9, "bank at 9")
    check(bank.dueDate.map(calendar.isDateInTomorrow) == true, "bank tomorrow")
    check(bank.dueDateIncludesTimeOfDay, "bank is timed")
    check(bank.listName == nil, "default list")
} else { check(false, "bank parsed") }

if let mom = draft("remind me at 6 to call mom") {
    check(mom.title == "Call mom", "time first: \(mom.title)")
    check(hour(mom.dueDate) == 18, "bare 6 means 6pm")
} else { check(false, "call mom parsed") }

if let stretch = draft("remind me in 20 minutes to stretch") {
    check(stretch.title == "Stretch", "stretch title: \(stretch.title)")
    check(stretch.dueDate.map { abs($0.timeIntervalSince(now) - 1200) < 1 } == true, "in 20 minutes")
} else { check(false, "stretch parsed") }

if let trash = draft("remind me tomorrow to take out the trash") {
    check(trash.title == "Take out the trash", "trash title: \(trash.title)")
    check(!trash.dueDateIncludesTimeOfDay, "a day with no time has no alarm")
    check(trash.dueDate.map(calendar.isDateInTomorrow) == true, "trash due tomorrow")
} else { check(false, "trash parsed") }

if let passport = draft("can you create a reminder to renew my passport") {
    check(passport.title == "Renew my passport", "passport title: \(passport.title)")
    check(passport.dueDate == nil, "no time → undated")
} else { check(false, "passport parsed") }

if let finish = draft("remind me to finish this") {
    check(finish.title == "Finish this", "'this' is kept in a reminder: \(finish.title)")
} else { check(false, "finish this parsed") }

if let milk = draft("add milk to my shopping list") {
    check(milk.title == "Milk", "milk title: \(milk.title)")
    check(milk.listName == "Shopping", "named list: \(String(describing: milk.listName))")
    check(milk.dueDate == nil, "milk undated")
} else { check(false, "milk parsed") }

if let todo = draft("put call the plumber friday on my to-do list") {
    check(todo.title == "Call the plumber", "to-do title: \(todo.title)")
    check(todo.listName == nil, "to-do means the default list")
    check(todo.dueDate.map { calendar.component(.weekday, from: $0) } == 6, "plumber on friday")
} else { check(false, "to-do parsed") }

if let meeting = draft("remind me about the meeting at 3pm") {
    check(meeting.title == "The meeting", "about title: \(meeting.title)")
    check(hour(meeting.dueDate) == 15, "meeting at 3pm")
} else { check(false, "meeting parsed") }

// MARK: - Declined

for notACommand in [
    "remind me what time the meeting is",
    "remind me how to export a pdf",
    "remind me",
    "remind me every day at 9 to take my pills",
    "add this page to my reading list",
    "add it to my shopping list",
    "add lunch with sam friday at 1 to my calendar",
    "schedule the dentist thursday at 3",
    "remember that my locker code is 4412",
    "set a timer for 10 minutes",
    "what are my reminders",
] {
    check(outcome(notACommand) == .notAReminderCommand, "declined: \(notACommand) → \(outcome(notACommand))")
}

// MARK: - Handed to extraction

if case .needsExtraction(let requestBody, _) = outcome("remind me tomorrow at 9") {
    check(requestBody == "tomorrow at 9", "no task → extraction: \(requestBody)")
} else { check(false, "a reminder with only a time goes to extraction") }

if case .needsExtraction = outcome("remind me to file taxes by the end of next week") {
    check(true, "unreadable time → extraction")
} else { check(false, "unreadable time goes to extraction, not undated: \(outcome("remind me to file taxes by the end of next week"))") }

// MARK: - Checking the on-device model's extraction

if let extracted = ReminderCommandParser.draft(
    fromExtractedTitle: "pick up the dry cleaning",
    extractedWhenPhrase: "friday at 5",
    requestBody: "pick up the dry cleaning on friday at 5 if i forget",
    listName: nil,
    now: now,
    calendar: calendar
) {
    check(extracted.title == "Pick up the dry cleaning", "extracted title")
    check(hour(extracted.dueDate) == 17, "extracted time resolved deterministically")
} else { check(false, "extraction accepted") }

check(ReminderCommandParser.draft(
    fromExtractedTitle: "Submit quarterly report",
    extractedWhenPhrase: "",
    requestBody: "do the report thing",
    listName: nil,
    now: now,
    calendar: calendar
) == nil, "a title with words the user never said is rejected")

check(ReminderCommandParser.draft(
    fromExtractedTitle: "call sam",
    extractedWhenPhrase: "",
    requestBody: "call sam tomorrow at 9",
    listName: nil,
    now: now,
    calendar: calendar
) == nil, "a time the user said but the model dropped is rejected")

if let undated = ReminderCommandParser.draft(
    fromExtractedTitle: "water the plants",
    extractedWhenPhrase: "",
    requestBody: "water the plants please",
    listName: "Home",
    now: now,
    calendar: calendar
) {
    check(undated.dueDate == nil && undated.listName == "Home", "undated extraction keeps the list")
} else { check(false, "undated extraction accepted") }

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
