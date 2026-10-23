//
//  Automation draft suite: spoken phrases -> drafts, ambiguous -> asks, ordinary talk is left
//  alone, templates, validation, and the optional model-assist reply. No model, no app.
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
let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))! // Wednesday

let plannerID = UUID()
let brieferID = UUID()
let focusID = UUID()
let researcherID = UUID()
let buddies = [
    AutomationBuddyReference(id: plannerID, name: "Planner", specialty: .planner),
    AutomationBuddyReference(id: brieferID, name: "Briefer", specialty: .general),
    AutomationBuddyReference(id: focusID, name: "Focus", specialty: .planner),
    AutomationBuddyReference(id: researcherID, name: "Scout", specialty: .researcher),
]

func parse(_ text: String, buddies: [AutomationBuddyReference] = buddies) -> AutomationDraftParser.Result {
    AutomationDraftParser.parse(text, now: now, calendar: calendar, buddies: buddies)
}

func draftOf(_ result: AutomationDraftParser.Result) -> AutomationDraft? {
    switch result {
    case .draft(let draft), .unsure(let draft): return draft
    case .needsChoice(let draft, _, _): return draft
    case .notAnAutomation: return nil
    }
}

func scheduleOf(_ draft: AutomationDraft?) -> AutomationSchedule? {
    if case .schedule(let schedule)? = draft?.trigger { return schedule }
    return nil
}

// MARK: - The required phrases

do {
    let result = parse("every weekday at 8 tell me what's due today")
    check({ if case .draft = result { return true } else { return false } }(), "weekday brief is a complete draft")
    let draft = draftOf(result)
    check(scheduleOf(draft) == AutomationSchedule(recurrence: .weekdays, hour: 8, minute: 0), "weekday brief: weekdays 08:00")
    check(draft?.source == .canvasDeadlines(withinDays: 1), "weekday brief: what's due today reads Canvas for 1 day")
    check(draft?.outputs == [.notchCard], "weekday brief: notch card by default")
    check(draft?.uncertainFields.isEmpty == true, "weekday brief: nothing guessed, so ready as is")
    check(draft?.isReadyToSave == true, "weekday brief: ready to save")
    if case .askBuddy(let instruction)? = draft?.action {
        check(instruction == "Tell me what's due today", "weekday brief: instruction has the schedule words removed (got \(instruction))")
    } else {
        check(false, "weekday brief: askBuddy action")
    }
    check(draft?.buddyID == plannerID, "weekday brief: Canvas work goes to the Planner")
}

do {
    let draft = draftOf(parse("every morning summarize Hacker News"))
    check(scheduleOf(draft) == AutomationSchedule(recurrence: .daily, hour: 9, minute: 0), "every morning: daily 09:00")
    check(draft?.uncertainFields.contains(.trigger) == true, "every morning: the 9:00 is a soft guess")
    check(draft?.notes[.trigger]?.contains("9:00 AM") == true, "every morning: the note names the assumed time")
    if case .askBuddy(let instruction)? = draft?.action {
        check(instruction == "Summarize Hacker News", "every morning: instruction is the task (got \(instruction))")
    } else {
        check(false, "every morning: askBuddy action")
    }
    check(draft?.buddyID == researcherID, "every morning: summarize goes to the researcher")
}

do {
    let draft = draftOf(parse("every Sunday evening plan my week"))
    check(scheduleOf(draft) == AutomationSchedule(recurrence: .weekly(weekday: 1), hour: 18, minute: 0), "Sunday evening: weekly(1) 18:00")
}

do {
    let draft = draftOf(parse("on the 1st of each month remind me to pay rent"))
    check(scheduleOf(draft) == AutomationSchedule(recurrence: .monthly(dayOfMonth: 1), hour: 9, minute: 0) || scheduleOf(draft)?.recurrence == .monthly(dayOfMonth: 1), "monthly: on the 1st")
    check(draft?.outputs.contains(.remindersChecklist(listTitle: "Wisp Today")) == true, "monthly remind: output is the reminders checklist")
    if case .askBuddy(let instruction)? = draft?.action {
        check(instruction.lowercased().contains("pay rent"), "monthly remind: keeps the task (got \(instruction))")
    } else {
        check(false, "monthly remind: askBuddy action")
    }
}

do {
    let result = parse("10 minutes before every meeting show me the agenda")
    let draft = draftOf(result)
    check(draft?.trigger == .event(.meetingStarting(minutesBefore: 10)), "meeting prep: meetingStarting(10)")
    check(draft?.source == .todaysCalendar, "meeting prep: reads today's calendar")
    if case .askBuddy(let instruction)? = draft?.action {
        check(instruction == "Show me the agenda", "meeting prep: instruction (got \(instruction))")
    } else {
        check(false, "meeting prep: askBuddy action")
    }
}

do {
    let draft = draftOf(parse("when a new Canvas assignment shows up tell me"))
    check(draft?.trigger == .event(.newCanvasItem), "new Canvas assignment: newCanvasItem event")
    check(draft?.buddyID == plannerID, "new Canvas assignment: the Planner owns it")
}

do {
    let draft = draftOf(parse("tell me when the build says Succeeded"))
    check(draft?.trigger == .event(.screenTextAppears(text: "Succeeded")), "screen watch: text Succeeded (got \(String(describing: draft?.trigger)))")
    check(draft?.source == .screenText, "screen watch: reads screen text")
}

do {
    let draft = draftOf(parse("let me know when the page shows \"Order confirmed\""))
    check(draft?.trigger == .event(.screenTextAppears(text: "Order confirmed")), "screen watch: quoted text kept")
}

do {
    let result = parse("every day")
    if case .needsChoice(let draft, let field, let question) = result {
        check(field == .trigger, "every day: asks about the trigger")
        check(question.lowercased().contains("time"), "every day: asks what time")
        check(draft.uncertainFields.contains(.trigger), "every day: trigger highlighted")
        check(!draft.isReadyToSave, "every day: not ready to save")
    } else {
        check(false, "every day with no time should be needsChoice, got \(result)")
    }
}

do {
    let result = parse("every Monday")
    if case .needsChoice(_, let field, _) = result {
        check(field == .trigger || field == .name, "every Monday alone needs a choice")
    } else {
        check(false, "every Monday alone should ask, got \(result)")
    }
}

// MARK: - Ordinary talk is left alone

for ordinaryText in ["what's the weather", "text size bigger", "open Safari", "what's due today", "set a timer for 10 minutes",
                     "remind me in 10 minutes to stand up", "how are you", "summarize this page", "what time is it",
                     "put Safari on the left", "tell me a joke", "when is the next meeting"] {
    check(!AutomationDraftParser.looksLikeAutomationRequest(ordinaryText), "not an automation: \"\(ordinaryText)\"")
    check(parse(ordinaryText) == .notAnAutomation, "parse leaves \"\(ordinaryText)\" alone")
}
for automationText in ["every weekday at 8 tell me what's due", "daily at 7pm review my day", "remind me tomorrow at 9 to call mom",
                       "when a new canvas item appears tell me", "weekly on friday send me a recap", "10 minutes before every meeting",
                       "nightly summarize my notes", "remind me on friday at 3pm to submit the form"] {
    check(AutomationDraftParser.looksLikeAutomationRequest(automationText), "looks like an automation: \"\(automationText)\"")
}

// MARK: - One-offs

do {
    let draft = draftOf(parse("remind me tomorrow at 9 to call mom"))
    if case .schedule(let schedule)? = draft?.trigger, case .once(let runDate) = schedule.recurrence {
        let c = calendar.dateComponents([.day, .hour], from: runDate)
        check(c.day == 15 && c.hour == 9, "one-off: tomorrow 9:00")
    } else {
        check(false, "one-off: remind me tomorrow should be a once schedule, got \(String(describing: draft?.trigger))")
    }
    check(draft?.outputs.contains(.notification) == true, "reminder: also notifies")
}

// MARK: - Outputs, actions, notify

do {
    let draft = draftOf(parse("every weekday at 7:30 build my daily checklist"))
    check(draft?.action == .buildDailyChecklist, "checklist phrase picks the checklist action")
}
do {
    let draft = draftOf(parse("every weekday at 7 summarize the news and read it out loud"))
    check(draft?.outputs.contains(.spokenLine) == true, "out loud adds the spoken line")
}
do {
    let draft = draftOf(parse("every night at 9 plan tomorrow silently"))
    check(draft?.notify == .never, "silently means notify never")
}
do {
    let draft = draftOf(parse("every Friday at 4pm find time to study and block it on my calendar"))
    check(draft?.action == .proposeStudyBlocks, "study phrase picks proposeStudyBlocks")
    check(draft?.outputs.contains(.calendarBlock) == true, "study blocks output a calendar block (which always asks)")
    check(draft?.makeAutomation(id: UUID(), now: now).validationProblems().isEmpty == true, "study block automation is valid")
}
do {
    let draft = draftOf(parse("every weekday at 9 focus on my essay for 45 minutes"))
    check(draft?.action == .startChromeFocus(topic: "my essay", minutes: 45), "a focus phrase picks Chrome focus mode, got \(String(describing: draft?.action))")
    check(draft?.makeAutomation(id: UUID(), now: now).validationProblems().isEmpty == true, "the focus automation is valid")
    let studyDraft = draftOf(parse("every Monday at 4pm block off focus blocks for study"))
    check(studyDraft?.action == .proposeStudyBlocks, "\"focus blocks\" still means study blocks")
}
do {
    let draft = draftOf(parse("when a file lands in my downloads folder tell me what it is"))
    check(draft?.trigger == .event(.fileDropped(folderPath: "~/Downloads")), "downloads folder event")
    check(draft?.source == .folderFiles(path: "~/Downloads"), "the watched folder is also the source")
}
do {
    let result = parse("when a new file is added tell me")
    if case .needsChoice(_, let field, _) = result {
        check(field == .trigger, "file event without a folder asks which folder")
    } else {
        check(false, "file event without a folder should ask, got \(result)")
    }
}

// MARK: - Buddy choice

do {
    let draft = draftOf(parse("every weekday at 8 ask Scout to read the headlines"))
    check(draft?.buddyID == researcherID, "a buddy named in the sentence wins")
}
do {
    let draft = draftOf(parse("every weekday at 8 tell me a fun fact", buddies: []))
    check(draft?.buddyID == nil, "no buddies: owner left for the store")
    check(!(draft?.uncertainFields.contains(.buddy) ?? true), "no buddies: not flagged")
}
do {
    let draft = draftOf(parse("every weekday at 8 tell me a fun fact"))
    check(draft?.buddyID == brieferID, "no clue: the Briefer is the fallback")
    check(draft?.uncertainFields.contains(.buddy) == true, "a guessed owner among several is highlighted")
    check(draft?.isReadyToSave == true, "a guessed owner does not block saving")
}

// MARK: - Validation

do {
    let valid = Automation(name: "A", buddyID: nil, trigger: .manual, action: .askBuddy(instruction: "Hi"), createdAt: now)
    check(valid.validationProblems().isEmpty, "a plain manual automation is valid")

    var noName = valid; noName.name = "  "
    check(!noName.validationProblems().isEmpty, "empty name is invalid")
    var noOutputs = valid; noOutputs.outputs = []
    check(!noOutputs.validationProblems().isEmpty, "no outputs is invalid")
    var calendarWithoutReason = valid; calendarWithoutReason.outputs = [.calendarBlock]
    check(!calendarWithoutReason.validationProblems().isEmpty, "calendarBlock without study blocks or a schedule instruction is invalid")
    var calendarWithSchedule = valid
    calendarWithSchedule.action = .askBuddy(instruction: "Schedule two focus hours")
    calendarWithSchedule.outputs = [.calendarBlock]
    check(calendarWithSchedule.validationProblems().isEmpty, "calendarBlock is fine when the instruction says to schedule")
    var badMinutes = valid; badMinutes.trigger = .event(.meetingStarting(minutesBefore: 500))
    check(!badMinutes.validationProblems().isEmpty, "meetingStarting 500 minutes is invalid")
    var scheduledBlank = valid
    scheduledBlank.trigger = .schedule(AutomationSchedule(recurrence: .daily, hour: 8, minute: 0))
    scheduledBlank.action = .askBuddy(instruction: "Summarize {topic}")
    check(scheduledBlank.validationProblems().contains { $0.contains("{topic}") }, "a scheduled blank with no default says it needs a value")
    scheduledBlank.action = .askBuddy(instruction: "Summarize {topic|the news}")
    check(scheduledBlank.validationProblems().isEmpty, "a blank with a default is fine on a schedule")
    scheduledBlank.action = .askBuddy(instruction: "Summarize {topic}")
    scheduledBlank.parameterValues = ["topic": "AI"]
    check(scheduledBlank.validationProblems().isEmpty, "a remembered value satisfies a blank")
    var manualBlank = valid; manualBlank.action = .askBuddy(instruction: "Summarize {topic}")
    check(manualBlank.validationProblems().isEmpty, "a manual run can ask for the blank, so it is valid")
    var clipboardBlank = valid
    clipboardBlank.trigger = .schedule(AutomationSchedule(recurrence: .daily, hour: 8, minute: 0))
    clipboardBlank.action = .askBuddy(instruction: "Fix {clipboard}")
    check(clipboardBlank.validationProblems().isEmpty, "{clipboard} is filled by Wisp, not asked")
    var badWatch = valid; badWatch.trigger = .event(.screenTextAppears(text: " "))
    check(!badWatch.validationProblems().isEmpty, "watching empty text is invalid")
}

// MARK: - Templates

check(AutomationTemplates.all.count == 8, "eight templates")
check(Set(AutomationTemplates.all.map(\.id)) == Set(AutomationTemplateID.allCases), "one template per id")
for template in AutomationTemplates.all {
    let draft = AutomationDraft(template: template, buddyID: plannerID)
    let problems = draft.makeAutomation(id: UUID(), now: now).validationProblems()
    if template.requiredBlanks.isEmpty {
        check(problems.isEmpty, "template \(template.id.rawValue) is valid as shipped (\(problems))")
        check(draft.isReadyToSave, "template \(template.id.rawValue) is ready to save")
    } else {
        check(!problems.isEmpty, "template \(template.id.rawValue) needs its blank before saving")
        check(draft.uncertainFields.contains(.trigger), "template \(template.id.rawValue) highlights what is missing")
    }
}
check(AutomationTemplates.template(withID: .morningBrief).trigger == .schedule(AutomationSchedule(recurrence: .weekdays, hour: 7, minute: 45)), "morning brief is weekdays 07:45")
check(AutomationTemplates.template(withID: .meetingPrep).trigger == .event(.meetingStarting(minutesBefore: 10)), "meeting prep is 10 minutes before")
check(AutomationTemplates.template(withID: .weeklyReview).trigger == .schedule(AutomationSchedule(recurrence: .weekly(weekday: 1), hour: 18, minute: 0)), "weekly review is Sunday 18:00")
check(AutomationTemplates.template(withID: .studyPlan).trigger == .schedule(AutomationSchedule(recurrence: .daily, hour: 19, minute: 0)), "study plan is daily 19:00")
check(AutomationTemplates.template(withID: .canvasDeadlines).action == .syncCanvas, "canvas deadlines is the JobsEngine sync")
check(AutomationTemplates.template(withID: .dailyChecklist).action == .buildDailyChecklist, "daily checklist is the JobsEngine checklist")
check(AutomationTemplates.template(withID: .focusBlock).outputs.contains(.calendarBlock), "focus block writes a calendar block")
check(AutomationTemplates.template(withID: .dailyChecklist).outputs == [.remindersChecklist(listTitle: "Wisp Today")], "daily checklist goes to Wisp Today")

// MARK: - Draft round trips

do {
    let template = AutomationTemplates.template(withID: .morningBrief)
    var draft = AutomationDraft(template: template, buddyID: brieferID)
    draft.shortcutDigit = 3
    let automation = draft.makeAutomation(id: UUID(), now: now)
    check(automation.nextRunAt != nil, "a scheduled draft caches its next run")
    check(automation.symbolName == template.symbolName, "template symbol is kept")
    let editedDraft = AutomationDraft(from: automation)
    check(editedDraft.name == automation.name && editedDraft.trigger == automation.trigger && editedDraft.shortcutDigit == 3, "editing reuses every field")
    let remade = editedDraft.makeAutomation(id: automation.id, now: now.addingTimeInterval(86_400))
    check(remade.createdAt == automation.createdAt, "editing keeps the original creation date")

    let taught = AutomationDraft.fromAnswerRecord(originalQuestion: "What changed in my inbox today?", buddyID: brieferID)
    check(taught.uncertainFields.contains(.trigger) && !taught.isReadyToSave, "teach by example asks when it should run")
    check(taught.action == .askBuddy(instruction: "What changed in my inbox today?"), "teach by example keeps the question as the instruction")

    let encoded = try! JSONEncoder().encode(automation)
    check(try! JSONDecoder().decode(Automation.self, from: encoded) == automation, "an automation survives JSON")
    let jsonText = String(data: encoded, encoding: .utf8) ?? ""
    check(!jsonText.lowercased().contains("webcal") && !jsonText.lowercased().contains("feed"), "an automation never holds a Canvas feed link")
}

// MARK: - Model assist

do {
    let unsureResult = parse("remind me on friday at the end of class")
    _ = unsureResult
    let partial = AutomationDraft(
        originalText: "check the thing weekly",
        name: "Check the thing",
        trigger: .manual,
        action: .askBuddy(instruction: "Check the thing"),
        uncertainFields: [.trigger]
    )
    let prompt = AutomationDraftParser.modelAssistPrompt(for: "check the thing weekly", partial: partial)
    check(prompt.contains("check the thing weekly") && prompt.contains("JSON"), "the assist prompt carries the sentence and asks for JSON")

    let goodReply = "Sure! ```json\n{\"name\":\"Weekly check\",\"trigger\":{\"type\":\"weekly\",\"weekday\":6,\"hour\":16,\"minute\":0},\"outputs\":[\"notch\",\"notification\"],\"notify\":\"onlyWhenSomethingNew\"}\n```"
    let applied = AutomationDraftParser.applyModelReply(goodReply, to: partial)
    check(applied?.trigger == .schedule(AutomationSchedule(recurrence: .weekly(weekday: 6), hour: 16, minute: 0)), "a good reply fills the trigger")
    check(applied?.name == "Weekly check", "a good reply fills the name")
    check(applied?.outputs == [.notchCard, .notification], "a good reply fills the outputs")
    check(applied?.uncertainFields.contains(.trigger) == false, "a filled trigger is no longer uncertain")
    check(applied?.action == partial.action, "the model cannot change the action")

    check(AutomationDraftParser.applyModelReply("I'm not sure what you mean.", to: partial) == nil, "prose without JSON is nothing")
    check(AutomationDraftParser.applyModelReply("{\"trigger\":{\"type\":\"daily\",\"hour\":99}}", to: partial) == nil, "an invalid trigger is dropped, leaving nothing usable")
    check(AutomationDraftParser.applyModelReply("{\"outputs\":[\"calendar\"]}", to: partial) == nil, "a model may never switch on calendar writes")
    check(AutomationDraftParser.applyModelReply("{\"foo\":1}", to: partial) == nil, "unknown keys are nothing")
    check(AutomationDraftParser.applyModelReply("{\"name\":\"X\",\"action\":\"delete everything\"}", to: partial)?.action == partial.action, "extra keys are ignored")
}

// MARK: - Chrome triggers (phase 08)

func instructionOf(_ draft: AutomationDraft?) -> String {
    if case .askBuddy(let instruction)? = draft?.action { return instruction }
    return ""
}

do {
    let result = parse("If I'm on youtube for 1 minute, remind me to study")
    check({ if case .draft = result { return true } else { return false } }(), "youtube for 1 minute is a complete draft (got \(result))")
    let draft = draftOf(result)
    check(draft?.trigger == .event(.chromeTimeOnSite(host: "youtube.com", minutes: 1)), "youtube for 1 minute: time on site (got \(String(describing: draft?.trigger)))")
    check(instructionOf(draft) == "Reply with one short line reminding me to study.", "youtube for 1 minute: the reminder is the instruction (got \(instructionOf(draft)))")
    check(draft?.source == AutomationSource.nothing, "youtube for 1 minute: reads nothing")
}

do {
    let draft = draftOf(parse("if I'm on reddit for 30 minutes tell me to take a break"))
    check(draft?.trigger == .event(.chromeTimeOnSite(host: "reddit.com", minutes: 30)), "reddit for 30 minutes")
    check(draftOf(parse("if I spend more than an hour on twitter, tell me to stop"))?.trigger == .event(.chromeTimeOnSite(host: "x.com", minutes: 60)), "an hour on twitter")
    check(draftOf(parse("when I've been on instagram for half an hour remind me to go outside"))?.trigger == .event(.chromeTimeOnSite(host: "instagram.com", minutes: 30)), "half an hour on instagram")
}

do {
    let draft = draftOf(parse("when I open youtube remind me to study first"))
    check(draft?.trigger == .event(.chromeTabOpened(host: "youtube.com")), "when I open youtube (got \(String(describing: draft?.trigger)))")
    check(instructionOf(draft).contains("study first"), "when I open youtube: the instruction is what to do")
    check(draftOf(parse("whenever I go to news.ycombinator.com tell me to get back to work"))?.trigger == .event(.chromeTabOpened(host: "news.ycombinator.com")), "an address as the site")
    check(draftOf(parse("every time I open hacker news, remind me what I'm working on"))?.trigger == .event(.chromeTabOpened(host: "news.ycombinator.com")), "a two-word site name")
}

do {
    let draft = draftOf(parse("when my page watch for Deployed matches, tell me what changed"))
    check(draft?.trigger == .event(.chromePageWatchMatched(watchDescription: "Deployed")), "page watch for Deployed (got \(String(describing: draft?.trigger)))")
    check(draftOf(parse("when a chrome page watch fires, put it in my buddy thread"))?.trigger == .event(.chromePageWatchMatched(watchDescription: "")), "any page watch")
}

// Not Chrome: no known site, or not about a site at all.
check(draftOf(parse("when I open my laptop remind me to stretch"))?.trigger != .event(.chromeTabOpened(host: "my")), "my laptop isn't a site")
check(!AutomationDraftParser.looksLikeAutomationRequest("when I open the fridge"), "the fridge isn't an automation")
check(!AutomationDraftParser.looksLikeAutomationRequest("I'm on youtube right now"), "a statement isn't an automation")
check(AutomationEvent.chromeTimeOnSite(host: "reddit.com", minutes: 30).validationProblems().isEmpty, "a time-on-site trigger is valid")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
if failureCount > 0 {
    print("\(failureCount) FAILED")
    exit(1)
}
