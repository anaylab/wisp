//
//  Learned shortcuts suite: replayability, phrase templates, matching, slot filling,
//  the drift policy and the store file.
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

// MARK: Helpers

func call(_ toolName: String, _ arguments: [String: JSONValue], succeeded: Bool = true) -> ShortcutRecordedToolCall {
    ShortcutRecordedToolCall(toolName: toolName, toolInput: .object(arguments), succeeded: succeeded)
}

func draft(_ transcript: String, _ calls: [ShortcutRecordedToolCall]) -> LearnedShortcutDraft? {
    if case .replayable(let learnedDraft) = ShortcutReplayability.evaluate(transcript: transcript, toolCalls: calls) {
        return learnedDraft
    }
    return nil
}

func reason(_ transcript: String, _ calls: [ShortcutRecordedToolCall]) -> ShortcutNotReplayableReason? {
    if case .notReplayable(let notReplayableReason) = ShortcutReplayability.evaluate(transcript: transcript, toolCalls: calls) {
        return notReplayableReason
    }
    return nil
}

func shortcut(from learnedDraft: LearnedShortcutDraft?) -> LearnedShortcut {
    learnedDraft!.makeShortcut()
}

let runningApplicationNames = ["Safari", "Xcode", "Google Chrome", "Notes"]

/// Stands in for the window-layout app matcher: case-insensitive, "chrome" -> "Google Chrome".
func resolveApplicationName(_ spokenName: String) -> String? {
    let lowercasedSpokenName = spokenName.lowercased()
    let matches = runningApplicationNames.filter { $0.lowercased() == lowercasedSpokenName }
        + runningApplicationNames.filter { $0.lowercased().hasSuffix(" " + lowercasedSpokenName) }
    return Set(matches).count == 1 ? matches.first : nil
}

func matched(_ transcript: String, _ shortcuts: [LearnedShortcut]) -> (LearnedShortcut, [String: String])? {
    if case .matched(let matchedShortcut, let slotValues) = LearnedShortcutMatcher.match(
        transcript: transcript, among: shortcuts, applicationNameResolver: resolveApplicationName
    ) {
        return (matchedShortcut, slotValues)
    }
    return nil
}

func matchResult(_ transcript: String, _ shortcuts: [LearnedShortcut]) -> LearnedShortcutMatchResult {
    LearnedShortcutMatcher.match(transcript: transcript, among: shortcuts, applicationNameResolver: resolveApplicationName)
}

// MARK: Tokenizer

check(LearnedShortcutTokenizer.tokens(from: "Hey Wisp, could you put Safari on the left please?").map(\.normalizedText)
      == ["put", "safari", "on", "the", "left"], "courtesy stripped both ends")
check(LearnedShortcutTokenizer.tokens(from: "put Safari on the left for me").map(\.normalizedText)
      == ["put", "safari", "on", "the", "left"], "trailing 'for me' stripped")
check(LearnedShortcutTokenizer.tokens(from: "Remind me to Call Mom!").map(\.originalText)
      == ["Remind", "me", "to", "Call", "Mom"], "original text keeps case, drops edge punctuation")
check(LearnedShortcutTokenizer.tokens(from: "set volume to eight").map(\.normalizedText)
      == LearnedShortcutTokenizer.tokens(from: "set volume to 8").map(\.normalizedText), "eight == 8")
check(LearnedShortcutTokenizer.tokens(from: "wisp").map(\.normalizedText) == ["wisp"], "a bare 'wisp' is not erased to nothing")
check(LearnedShortcutTokenizer.tokens(from: "  ...  ").isEmpty, "only punctuation -> no tokens")
check(LearnedShortcutTokenizer.tokens(from: "don’t quit").map(\.normalizedText) == ["don't", "quit"], "curly apostrophe folded")

// MARK: Phrase templates

check(LearnedShortcutPhraseTemplate.parse("put {app} on the left")?.slotNames == ["app"], "template with one blank")
check(LearnedShortcutPhraseTemplate.parse("Put {app} on the Left")?.canonicalText == "put {app} on the left", "canonical text is lowercase")
check(LearnedShortcutPhraseTemplate.parse("{app}") == nil, "all-blank template refused")
check(LearnedShortcutPhraseTemplate.parse("") == nil, "empty template refused")
check(LearnedShortcutPhraseTemplate.parse("move {a} {b} left") == nil, "adjacent blanks refused")
check(LearnedShortcutPhraseTemplate.parse("move {a} to {a}") == nil, "repeated blank name refused")
check(LearnedShortcutPhraseTemplate.parse("move {} left") == nil, "unnamed blank refused")
check(LearnedShortcutPhraseTemplate.parse("move {1app} left") == nil, "blank name must start with a letter")
check(LearnedShortcutPhraseTemplate.parse("move {app left") == nil, "unbalanced brace refused")
check(LearnedShortcutPhraseTemplate.parse("a b c d e f g h i j k l m") == nil, "too long refused")
check(LearnedShortcutPhraseTemplate.parse("set volume to eight")?.canonicalText == "set volume to 8", "number words canonical")

// MARK: Replayability — accepted

let arrangeSafariLeft = call("arrange_windows", ["app": .string("Safari"), "placement": .string("left_half")])
let safariDraft = draft("put Safari on the left", [arrangeSafariLeft])
check(safariDraft?.phraseTemplate == "put {app} on the left", "app name becomes a blank: \(safariDraft?.phraseTemplate ?? "nil")")
check(safariDraft?.slots == [LearnedShortcutSlot(name: "app", kind: .applicationName)], "app slot kind")
check(safariDraft?.steps.first?.slotBindings == [LearnedShortcutSlotBinding(argumentPath: [.key("app")], slotName: "app")], "binding points at the app argument")
check(safariDraft?.steps.first?.toolInput == arrangeSafariLeft.toolInput, "step keeps the input it ran with")

let frontWindowDraft = draft("make this window full screen", [call("arrange_windows", ["placement": .string("maximize")])])
check(frontWindowDraft?.slots.isEmpty == true && frontWindowDraft?.phraseTemplate == "make this window full screen",
      "no app named -> no blank, phrase kept whole")

let thisAppDraft = draft("move this to the left", [call("arrange_windows", ["app": .string("this"), "placement": .string("left_half")])])
check(thisAppDraft != nil && thisAppDraft?.slots.isEmpty == true, "'this' app that isn't said as an app stays a constant")

let reminderDraft = draft("remind me to call the dentist", [call("create_reminder", ["title": .string("call the dentist")])])
check(reminderDraft?.phraseTemplate == "remind me to {title}", "free text becomes a blank: \(reminderDraft?.phraseTemplate ?? "nil")")
check(reminderDraft?.slots == [LearnedShortcutSlot(name: "title", kind: .freeText)], "title slot is free text")

let musicDraft = draft("play Blinding Lights", [call("control_music", ["action": .string("play"), "query": .string("Blinding Lights")])])
check(musicDraft?.phraseTemplate == "play {query}" && musicDraft?.steps.first?.toolInput == .object(["action": .string("play"), "query": .string("Blinding Lights")]),
      "music query is a blank, action stays constant")

let pauseDraft = draft("pause the music", [call("control_music", ["action": .string("pause")])])
check(pauseDraft != nil && pauseDraft?.slots.isEmpty == true, "no blank when nothing variable")

let twoWindowsDraft = draft("put Safari on the left and Xcode on the right", [
    call("arrange_windows", ["app": .string("Safari"), "placement": .string("left_half")]),
    call("arrange_windows", ["app": .string("Xcode"), "placement": .string("right_half")]),
])
check(twoWindowsDraft?.phraseTemplate == "put {app} on the left and {app2} on the right", "two steps, two blanks: \(twoWindowsDraft?.phraseTemplate ?? "nil")")
check(twoWindowsDraft?.steps.count == 2 && twoWindowsDraft?.slots.map(\.name) == ["app", "app2"], "slot names stay distinct")

let sameAppTwiceDraft = draft("put Safari on the left then maximize Safari", [
    call("arrange_windows", ["app": .string("Safari"), "placement": .string("left_half")]),
])
check(sameAppTwiceDraft != nil && sameAppTwiceDraft?.slots.isEmpty == true,
      "an app said twice is a constant, not a guess")

let sharedValueDraft = draft("lock Safari", [
    call("arrange_windows", ["app": .string("Safari"), "placement": .string("left_half")]),
    call("arrange_windows", ["app": .string("Safari"), "placement": .string("maximize")]),
])
check(sharedValueDraft?.slots.map(\.name) == ["app"] && sharedValueDraft?.steps.allSatisfy { $0.slotBindings.count == 1 } == true,
      "one value used by two steps shares one blank")

check(draft("organize my tabs", [call("chrome_organize_tabs", [:])]) != nil, "tab organizing is replayable")
check(draft("organize my tabs", [ShortcutRecordedToolCall(toolName: "chrome_organize_tabs", toolInput: .null, succeeded: true)]) != nil, "null input is treated as empty")

// MARK: Replayability — refused

check(reason("tidy up", []) == .noToolCalls, "no tool calls")
check(reason("", [arrangeSafariLeft]) == .emptyRequest, "empty request")
check(reason("put Safari on the left", [call("arrange_windows", ["app": .string("Safari"), "placement": .string("left_half")], succeeded: false)])
      == .aCallDidNotSucceed(toolName: "arrange_windows"), "failed or declined call")
check(reason("do it", [call("browser_task", ["task": .string("open youtube")])]) == .toolNotAllowed(toolName: "browser_task"), "browser_task never")
for forbiddenToolName in ["do_in_background", "delegate_coding_task", "ask_buddy", "send_imessage", "draft_email",
                          "read_screen_text", "cua-driver__click", "remember", "forget", "chrome_close_tabs",
                          "chrome_focus_tab", "list_shortcuts", "COMPOSIO_MULTI_EXECUTE_TOOL"] {
    check(reason("do the thing", [call(forbiddenToolName, [:])]) == .toolNotAllowed(toolName: forbiddenToolName),
          "\(forbiddenToolName) is not on the allow-list")
}
check(reason("put Safari on the left", [call("arrange_windows", ["pid": .number(412), "placement": .string("left_half")])])
      == .ephemeralArgument(toolName: "arrange_windows", argumentName: "pid"), "pid is per-turn")
check(reason("run it", [call("run_shortcut", ["name": .string("Tidy"), "extra": .object(["element_token": .string("s1:3")])])])
      == .ephemeralArgument(toolName: "run_shortcut", argumentName: "element_token"), "nested element token is found")
check(reason("run it", [call("run_shortcut", ["name": .string("a12")])])
      == .ephemeralArgument(toolName: "run_shortcut", argumentName: "a12"), "an a12-style value is a per-turn id")
check(reason("run it", [call("run_shortcut", ["name": .string("t7")])]) != nil, "t7-style id")
check(reason("run it", [call("run_shortcut", ["name": .string("e7")])]) != nil, "e7-style id")
check(reason("run it", [call("run_shortcut", ["name": .string("Evening")])]) == nil, "an ordinary name isn't mistaken for an id")
check(reason("remind me to call the dentist tomorrow", [call("create_reminder", ["title": .string("call the dentist"), "due": .string("2026-10-22")])])
      == .timeDependentArgument(toolName: "create_reminder", argumentName: "due"), "absolute due date")
check(reason("remind me to call the dentist", [call("create_reminder", ["title": .string("Call Dr. Patel to schedule a cleaning")])])
      == .modelAuthoredText(toolName: "create_reminder", argumentName: "title"), "title the user never said")
check(reason("remind me to call", [call("create_reminder", ["title": .number(3)])])
      == .modelAuthoredText(toolName: "create_reminder", argumentName: "title"), "non-string free text")
check(reason("play something chill chill", [call("control_music", ["action": .string("play"), "query": .string("chill")])])
      == .ambiguousArgumentPosition(toolName: "control_music", argumentName: "query"), "free text said twice")
check(reason("play one two three four five six seven eight nine ten", [call("control_music", ["action": .string("play"), "query": .string("one two three four five six seven eight nine ten")])])
      == .blankTooLong(argumentName: "query"), "blank longer than the matcher can capture")
check(reason("tabs", [call("chrome_organize_tabs", [:])]) == nil, "one-word fixed phrase is allowed")
check(reason("Safari", [call("arrange_windows", ["app": .string("Safari"), "placement": .string("maximize")])]) == .noFixedWordsLeft,
      "nothing left but the blank")
check(reason("play Taylor Swift Taylor", [call("control_music", ["action": .string("play"), "query": .string("Taylor Swift")]),
                                          call("control_music", ["action": .string("play"), "query": .string("Swift Taylor")])])
      == .blanksOverlapOrTouch, "overlapping blanks")
check(reason("play A B", [call("control_music", ["action": .string("play"), "query": .string("A")]),
                          call("create_reminder", ["title": .string("B")])])
      == .blanksOverlapOrTouch, "touching blanks")
let nineCalls = (0..<9).map { _ in call("chrome_organize_tabs", [:]) }
check(reason("organize", nineCalls) == .tooManySteps, "step cap")

// MARK: Matching

let moveAppLeft = LearnedShortcut(
    phraseTemplate: "put {app} on the left",
    slots: [LearnedShortcutSlot(name: "app", kind: .applicationName)],
    steps: [LearnedShortcutStep(toolName: "arrange_windows",
                                toolInput: .object(["app": .string("Safari"), "placement": .string("left_half")]),
                                slotBindings: [LearnedShortcutSlotBinding(argumentPath: [.key("app")], slotName: "app")])]
)

check(matched("put Xcode on the left", [moveAppLeft])?.1 == ["app": "Xcode"], "slot captured")
check(matched("Put xcode on the left.", [moveAppLeft])?.1 == ["app": "Xcode"], "case/punctuation insensitive; resolver canonicalises")
check(matched("hey wisp could you put chrome on the left please", [moveAppLeft])?.1 == ["app": "Google Chrome"], "courtesy + resolver alias")
check(matched("put Google Chrome on the left", [moveAppLeft])?.1 == ["app": "Google Chrome"], "multi-word slot")
check(matchResult("put Spotify on the left", [moveAppLeft]) == .noMatch, "unresolvable app -> no match")
check(matchResult("put on the left", [moveAppLeft]) == .noMatch, "empty blank -> no match")
check(matchResult("put Safari on the right", [moveAppLeft]) == .noMatch, "different word -> no match")
check(matchResult("put Safari on the left now", [moveAppLeft]) == .noMatch, "extra trailing word -> no match")
check(matchResult("so put Safari on the left", [moveAppLeft]) == .noMatch, "extra leading word -> no match")
check(matchResult("put Safari on left", [moveAppLeft]) == .noMatch, "missing word -> no match")
check(matchResult("", [moveAppLeft]) == .noMatch, "empty utterance")
check(matchResult("put Safari on the left", []) == .noMatch, "no shortcuts")

var disabledShortcut = moveAppLeft
disabledShortcut.isEnabled = false
check(matchResult("put Safari on the left", [disabledShortcut]) == .noMatch, "disabled shortcuts never match")

let setVolume = LearnedShortcut(
    phraseTemplate: "set volume to 8",
    slots: [],
    steps: [LearnedShortcutStep(toolName: "run_shortcut", toolInput: .object(["name": .string("Volume 8")]), slotBindings: [])]
)
check(matched("set volume to eight", [setVolume]) != nil, "spoken number matches saved digit")
check(matched("Set volume to 8!", [setVolume]) != nil, "digit matches")

let remindMe = LearnedShortcut(
    phraseTemplate: "remind me to {title}",
    slots: [LearnedShortcutSlot(name: "title", kind: .freeText)],
    steps: [LearnedShortcutStep(toolName: "create_reminder", toolInput: .object(["title": .string("x")]),
                                slotBindings: [LearnedShortcutSlotBinding(argumentPath: [.key("title")], slotName: "title")])]
)
check(matched("remind me to Call Mom at the Dentist", [remindMe])?.1 == ["title": "Call Mom at the Dentist"], "free text keeps its case")
check(matchResult("remind me to a b c d e f g h i", [remindMe]) == .noMatch, "free text over the word cap -> no match")

let tidySafari = LearnedShortcut(phraseTemplate: "tidy up", slots: [], steps: setVolume.steps)
check(matchResult("tidy up", [tidySafari, moveAppLeft]) != .noMatch, "unrelated shortcuts don't interfere")
let tidyTwin = LearnedShortcut(phraseTemplate: "tidy up", slots: [], steps: setVolume.steps)
check(matchResult("tidy up", [tidySafari, tidyTwin]) == .ambiguous, "two shortcuts fit -> ambiguous")

// "play {a} and {b}" against "play x and y and z" fits two ways.
let playTwo = LearnedShortcut(
    phraseTemplate: "play {first} and {second}",
    slots: [LearnedShortcutSlot(name: "first", kind: .freeText), LearnedShortcutSlot(name: "second", kind: .freeText)],
    steps: remindMe.steps
)
check(matchResult("play x and y and z", [playTwo]) == .ambiguous, "one shortcut fitting two ways -> ambiguous")
check(matched("play x and y", [playTwo])?.1 == ["first": "x", "second": "y"], "unambiguous two blanks")

var brokenSlotsShortcut = moveAppLeft
brokenSlotsShortcut.slots = []
check(matchResult("put Safari on the left", [brokenSlotsShortcut]) == .noMatch, "template/slot mismatch is ignored, not guessed")

var invalidTemplateShortcut = moveAppLeft
invalidTemplateShortcut.phraseTemplate = "{app}"
check(matchResult("Safari", [invalidTemplateShortcut]) == .noMatch, "an all-blank template never matches anything")

// Learned from a request, then matched by the same request and a variation.
let roundTripShortcut = shortcut(from: safariDraft)
check(matched("put Safari on the left", [roundTripShortcut]) != nil, "the request that taught it matches it")
check(matched("hey wisp, put Notes on the left", [roundTripShortcut])?.1 == ["app": "Notes"], "…and its variations")
let roundTripReminder = shortcut(from: reminderDraft)
check(matched("remind me to call the dentist", [roundTripReminder])?.1 == ["title": "call the dentist"], "reminder round trip")

// MARK: Slot filling

let filledInput = moveAppLeft.steps[0].toolInput(fillingSlotsWith: ["app": "Xcode"])
check(filledInput == .object(["app": .string("Xcode"), "placement": .string("left_half")]), "slot value replaces only the bound argument")
check(moveAppLeft.steps[0].toolInput(fillingSlotsWith: [:]) == nil, "missing slot value -> nil, never a half-filled call")

let nestedStep = LearnedShortcutStep(
    toolName: "run_shortcut",
    toolInput: .object(["items": .array([.string("a"), .object(["text": .string("b")])])]),
    slotBindings: [
        LearnedShortcutSlotBinding(argumentPath: [.key("items"), .index(1), .key("text")], slotName: "t"),
        LearnedShortcutSlotBinding(argumentPath: [.key("items"), .index(0)], slotName: "u"),
    ]
)
check(nestedStep.toolInput(fillingSlotsWith: ["t": "B2", "u": "A2"])
      == .object(["items": .array([.string("A2"), .object(["text": .string("B2")])])]), "nested paths with array indexes")
let wrongPathStep = LearnedShortcutStep(
    toolName: "run_shortcut", toolInput: .object(["n": .number(1)]),
    slotBindings: [LearnedShortcutSlotBinding(argumentPath: [.key("n")], slotName: "t")]
)
check(wrongPathStep.toolInput(fillingSlotsWith: ["t": "x"]) == nil, "a binding that no longer points at a string -> nil")
let outOfRangeStep = LearnedShortcutStep(
    toolName: "run_shortcut", toolInput: .object(["items": .array([])]),
    slotBindings: [LearnedShortcutSlotBinding(argumentPath: [.key("items"), .index(3)], slotName: "t")]
)
check(outOfRangeStep.toolInput(fillingSlotsWith: ["t": "x"]) == nil, "index out of range -> nil")

// MARK: Drift policy

var driftingShortcut = moveAppLeft
let driftDate = Date(timeIntervalSince1970: 1_000)
driftingShortcut = LearnedShortcutDriftPolicy.applying(runSucceeded: true, at: driftDate, to: driftingShortcut)
check(driftingShortcut.successCount == 1 && driftingShortcut.consecutiveFailures == 0 && driftingShortcut.lastRunAt == driftDate, "success counted")
driftingShortcut = LearnedShortcutDriftPolicy.applying(runSucceeded: false, at: driftDate, to: driftingShortcut)
check(driftingShortcut.isEnabled && driftingShortcut.consecutiveFailures == 1, "one failure keeps it on")
driftingShortcut = LearnedShortcutDriftPolicy.applying(runSucceeded: true, at: driftDate, to: driftingShortcut)
check(driftingShortcut.consecutiveFailures == 0, "a success resets the streak")
driftingShortcut = LearnedShortcutDriftPolicy.applying(runSucceeded: false, at: driftDate, to: driftingShortcut)
driftingShortcut = LearnedShortcutDriftPolicy.applying(runSucceeded: false, at: driftDate, to: driftingShortcut)
check(!driftingShortcut.isEnabled && driftingShortcut.disabledReason != nil, "two failures in a row turn it off, with a reason")

// MARK: Offer policy

func offered(_ transcript: String, _ calls: [ShortcutRecordedToolCall], ownQuestion: Bool = true,
             hitCap: Bool = false, existing: Set<String> = []) -> LearnedShortcutOffer? {
    LearnedShortcutOfferPolicy.offer(transcript: transcript, isUsersOwnQuestion: ownQuestion, hitIterationCap: hitCap,
                                     toolCalls: calls, existingPhraseTemplates: existing)
}
check(offered("put Safari on the left", [arrangeSafariLeft])?.draft == safariDraft, "a replayable user turn is offered")
check(offered("put Safari on the left", [arrangeSafariLeft], ownQuestion: false) == nil, "routine/skill/dictation turns are never offered")
check(offered("put Safari on the left", [arrangeSafariLeft], hitCap: true) == nil, "a turn that hit the iteration cap isn't offered")
check(offered("put Safari on the left", [arrangeSafariLeft], existing: ["put {app} on the left"]) == nil, "a phrase already saved isn't offered again")
check(offered("put Safari on the left", [arrangeSafariLeft], existing: ["something else"]) != nil, "other saved phrases don't block it")
check(offered("what's the weather", []) == nil, "a turn with no tool calls isn't offered")
check(offered("do the thing", [call("browser_task", ["task": .string("x")])]) == nil, "a turn with a disallowed tool isn't offered")

// MARK: Draft editing (the save card's logic)

let twoBlankDraft = twoWindowsDraft!
check(LearnedShortcutDraftEditing.exampleValue(forSlotNamed: "app", in: twoBlankDraft) == "Safari", "example value comes from the learned input")
check(LearnedShortcutDraftEditing.exampleValue(forSlotNamed: "app2", in: twoBlankDraft) == "Xcode", "second blank's example")
check(LearnedShortcutDraftEditing.exampleValue(forSlotNamed: "nope", in: twoBlankDraft) == nil, "unknown blank has no example")

let allBlanksKept = LearnedShortcutDraftEditing.keepingBlanks(["app", "app2"], in: twoBlankDraft)
check(allBlanksKept == twoBlankDraft, "keeping every blank changes nothing")

let firstBlankDemoted = LearnedShortcutDraftEditing.keepingBlanks(["app2"], in: twoBlankDraft)
check(firstBlankDemoted?.phraseTemplate == "put safari on the left and {app2} on the right", "demoted blank goes back to its words: \(firstBlankDemoted?.phraseTemplate ?? "nil")")
check(firstBlankDemoted?.slots.map(\.name) == ["app2"], "demoted blank leaves the slot list")
check(firstBlankDemoted?.steps[0].slotBindings.isEmpty == true && firstBlankDemoted?.steps[1].slotBindings.count == 1, "demoted blank is unbound, the other kept")
check(firstBlankDemoted?.steps[0].toolInput == twoBlankDraft.steps[0].toolInput, "the step input itself is untouched")

let noBlanksKept = LearnedShortcutDraftEditing.keepingBlanks([], in: twoBlankDraft)
check(noBlanksKept?.slots.isEmpty == true && noBlanksKept?.phraseTemplate == "put safari on the left and xcode on the right", "all blanks demoted -> a plain phrase")
let demotedShortcut = noBlanksKept.map { $0.makeShortcut() }
check(demotedShortcut.flatMap { matched("put Safari on the left and Xcode on the right", [$0]) } != nil, "…which matches only the learned request")
check(demotedShortcut.flatMap { matched("put Notes on the left and Xcode on the right", [$0]) } == nil, "…and not a variation")

let multiWordDemoted = LearnedShortcutDraftEditing.keepingBlanks([], in: draft("play Blinding Lights", [call("control_music", ["action": .string("play"), "query": .string("Blinding Lights")])])!)
check(multiWordDemoted?.phraseTemplate == "play blinding lights", "multi-word example restores all its words")

// Saving with an edited phrase.
if case .success(let editedShortcut) = LearnedShortcutDraftEditing.shortcut(from: safariDraft!, editedPhrase: "Move {app} to the left") {
    check(editedShortcut.phraseTemplate == "move {app} to the left" && editedShortcut.steps == safariDraft!.steps && editedShortcut.slots == safariDraft!.slots,
          "edited phrase keeps the learned steps and blanks")
    check(matched("move Notes to the left", [editedShortcut])?.1 == ["app": "Notes"], "edited phrase matches the new wording")
} else {
    check(false, "an edited phrase that keeps its blank is accepted")
}
let missingBlank = LearnedShortcutDraftEditing.shortcut(from: safariDraft!, editedPhrase: "move it to the left")
check(missingBlank == .failure(.blanksDoNotMatchTheSteps(expected: ["app"], found: [])), "dropping a blank is refused")
let renamedBlank = LearnedShortcutDraftEditing.shortcut(from: safariDraft!, editedPhrase: "move {window} to the left")
check(renamedBlank == .failure(.blanksDoNotMatchTheSteps(expected: ["app"], found: ["window"])), "renaming a blank is refused")
let extraBlank = LearnedShortcutDraftEditing.shortcut(from: pauseDraft!, editedPhrase: "pause {what}")
check(extraBlank == .failure(.blanksDoNotMatchTheSteps(expected: [], found: ["what"])), "adding a blank the steps don't use is refused")
check(LearnedShortcutDraftEditing.shortcut(from: safariDraft!, editedPhrase: "{app}") == .failure(.phraseIsNotATemplate), "all-blank phrase is refused")
check(LearnedShortcutDraftEditing.shortcut(from: pauseDraft!, editedPhrase: "") == .failure(.phraseIsNotATemplate), "empty phrase is refused")

// Plain descriptions on the card.
check(LearnedShortcutDraftEditing.plainDescription(of: safariDraft!.steps[0]) == "Arrange windows: app {app}, placement \"left_half\"",
      "a blank shows as its name: \(LearnedShortcutDraftEditing.plainDescription(of: safariDraft!.steps[0]))")
check(LearnedShortcutDraftEditing.plainDescription(of: LearnedShortcutStep(toolName: "chrome_organize_tabs", toolInput: .object([:]), slotBindings: []))
      == "Chrome organize tabs", "no arguments -> just the title")

// MARK: Runner

func okOutcome(_ content: String = "done.", ranWith: JSONValue? = nil) -> LearnedShortcutToolOutcome {
    LearnedShortcutToolOutcome(content: content, isError: false, wasDeclined: false, executedToolInput: ranWith)
}
func errorOutcome(_ content: String) -> LearnedShortcutToolOutcome {
    LearnedShortcutToolOutcome(content: content, isError: true, wasDeclined: false, executedToolInput: nil)
}
let declinedOutcome = LearnedShortcutToolOutcome(content: "the user did not approve this", isError: false, wasDeclined: true, executedToolInput: nil)

final class CallRecorder {
    var calls: [(String, JSONValue)] = []
}

func runShortcut(_ shortcut: LearnedShortcut, _ slotValues: [String: String],
                 outcomes: [LearnedShortcutToolOutcome]) async -> (LearnedShortcutRunResult, [(String, JSONValue)]) {
    let recorder = CallRecorder()
    var outcomeIndex = 0
    let result = await LearnedShortcutRunner.run(shortcut, slotValues: slotValues) { toolName, toolInput in
        recorder.calls.append((toolName, toolInput))
        defer { outcomeIndex += 1 }
        return outcomeIndex < outcomes.count ? outcomes[outcomeIndex] : okOutcome()
    }
    return (result, recorder.calls)
}

let twoStepShortcut = LearnedShortcut(
    phraseTemplate: "put {app} on the left and tidy tabs",
    slots: [LearnedShortcutSlot(name: "app", kind: .applicationName)],
    steps: [moveAppLeft.steps[0],
            LearnedShortcutStep(toolName: "chrome_organize_tabs", toolInput: .object([:]), slotBindings: [])]
)

let (completedResult, completedCalls) = await runShortcut(twoStepShortcut, ["app": "Xcode"], outcomes: [okOutcome("done — Xcode left."), okOutcome("organized.")])
if case .completed(let steps) = completedResult {
    check(steps.count == 2 && steps.allSatisfy { !$0.failed }, "both steps ran")
} else {
    check(false, "a shortcut whose steps succeed completes")
}
check(completedCalls.map(\.0) == ["arrange_windows", "chrome_organize_tabs"], "steps run in order")
check(completedCalls.first?.1 == .object(["app": .string("Xcode"), "placement": .string("left_half")]), "the blank is filled with what was said")

let (editedResult, _) = await runShortcut(moveAppLeft, ["app": "Notes"], outcomes: [okOutcome("done — Notes left.", ranWith: .object(["app": .string("Notes"), "placement": .string("right_half")]))])
check(editedResult.stepResults.first?.inputRan == .object(["app": .string("Notes"), "placement": .string("right_half")]), "the input the tool reports having run is what's recorded")

let unlistedToolShortcut = LearnedShortcut(
    phraseTemplate: "send it",
    slots: [],
    steps: [moveAppLeft.steps[0], LearnedShortcutStep(toolName: "send_imessage", toolInput: .object([:]), slotBindings: [])]
)
let (unlistedResult, unlistedCalls) = await runShortcut(unlistedToolShortcut, ["app": "Notes"], outcomes: [])
check(unlistedCalls.isEmpty, "a step on no allow-list stops everything before the first call")
if case .failed(_, let failedIndex, _, let fallBack) = unlistedResult {
    check(failedIndex == 1 && fallBack, "…naming the step, and falling back to the model")
} else {
    check(false, "a hand-edited unlisted tool fails")
}

let (missingSlotResult, missingSlotCalls) = await runShortcut(twoStepShortcut, [:], outcomes: [])
check(missingSlotCalls.isEmpty, "an unfillable blank stops before anything runs")
if case .failed(let steps, _, _, let fallBack) = missingSlotResult { check(steps.isEmpty && fallBack, "…and may fall back") } else { check(false, "missing slot value fails") }

let (firstStepErrorResult, firstStepErrorCalls) = await runShortcut(twoStepShortcut, ["app": "Xcode"], outcomes: [errorOutcome("accessibility is off")])
check(firstStepErrorCalls.count == 1, "a failed first step stops the run")
if case .failed(_, let failedIndex, let reason, let fallBack) = firstStepErrorResult {
    check(failedIndex == 0 && reason == "accessibility is off" && fallBack, "first-step failure: may fall back to the model")
} else {
    check(false, "first-step error is a failure")
}

let (secondStepErrorResult, _) = await runShortcut(twoStepShortcut, ["app": "Xcode"], outcomes: [okOutcome("done — Xcode left."), errorOutcome("no chrome")])
if case .failed(let steps, let failedIndex, _, let fallBack) = secondStepErrorResult {
    check(failedIndex == 1 && steps.count == 2 && !fallBack, "failure after a step ran must NOT fall back (the model would repeat it)")
} else {
    check(false, "second-step error is a failure")
}

let (softFailureResult, _) = await runShortcut(moveAppLeft, ["app": "Xcode"], outcomes: [okOutcome("i couldn't move that: Xcode has no open window.")])
if case .failed(_, _, _, let fallBack) = softFailureResult { check(fallBack, "a tool that says 'i couldn't' as ordinary text counts as failed") } else { check(false, "soft failure is a failure") }

let (declinedFirstResult, declinedFirstCalls) = await runShortcut(twoStepShortcut, ["app": "Xcode"], outcomes: [declinedOutcome])
if case .declined(_, let declinedIndex) = declinedFirstResult { check(declinedIndex == 0 && declinedFirstCalls.count == 1, "declining step 1 ends the run, no fallback") } else { check(false, "a declined step is .declined") }
let (declinedSecondResult, _) = await runShortcut(twoStepShortcut, ["app": "Xcode"], outcomes: [okOutcome("done — Xcode left."), declinedOutcome])
if case .declined(let steps, let declinedIndex) = declinedSecondResult { check(declinedIndex == 1 && steps.count == 2, "declining step 2 ends the run after step 1") } else { check(false, "second-step decline") }

// Failure wording.
for failureText in ["I couldn't control Music: boom", "I couldn’t do it", "i need a placement, one of: left_half", "no single running app matches \"x\". running apps: a",
                    "macOS blocked Wisp from controlling Music.", "Chrome has no open tabs.", "done — Safari left. but Xcode has no open window.", "Error: nope"] {
    check(ShortcutToolResultJudgement.looksLikeFailure(failureText), "reads as a failure: \(failureText)")
}
for successText in ["done — Safari left, Xcode right.", "done.", "paused.", "playing.", "added \"call mom\" to the Reminders list.", "organized 6 tabs into 2 groups.", ""] {
    check(!ShortcutToolResultJudgement.looksLikeFailure(successText), "reads as success: \(successText)")
}

// Reply lines.
check(LearnedShortcutReplyText.reply(for: completedResult, shortcut: twoStepShortcut) == "done.", "success says the shortcut's confirmation")
check(LearnedShortcutReplyText.reply(for: declinedFirstResult, shortcut: twoStepShortcut) == "okay, i didn't run that.", "declined at once")
check(LearnedShortcutReplyText.reply(for: declinedSecondResult, shortcut: twoStepShortcut) == "okay, i stopped after 1 of 2 steps.", "declined later")
check(LearnedShortcutReplyText.reply(for: secondStepErrorResult, shortcut: twoStepShortcut) == "i did 1 of 2 steps, then: no chrome", "failed after progress")
check(LearnedShortcutReplyText.reply(for: firstStepErrorResult, shortcut: twoStepShortcut) == "that shortcut didn't work: accessibility is off", "failed at once")

// MARK: Display

let displayNow = Date(timeIntervalSince1970: 1_000_000)
let displayLocale = Locale(identifier: "en_US")
func summary(_ edit: (inout LearnedShortcut) -> Void) -> String {
    var shortcutToShow = moveAppLeft
    edit(&shortcutToShow)
    return LearnedShortcutDisplay.runSummary(for: shortcutToShow, now: displayNow, locale: displayLocale)
}
check(summary { _ in } == "Not run yet", "never run")
check(summary { $0.lastRunAt = displayNow.addingTimeInterval(-10); $0.successCount = 1 } == "Ran 1 time · last ran just now", "one run, just now")
check(summary { $0.lastRunAt = displayNow.addingTimeInterval(-7_200); $0.successCount = 3 } == "Ran 3 times · last ran 2 hours ago", "several runs: \(summary { $0.lastRunAt = displayNow.addingTimeInterval(-7_200); $0.successCount = 3 })")
check(summary { $0.lastRunAt = displayNow.addingTimeInterval(-86_400); $0.successCount = 0 } == "Never worked · last tried 1 day ago", "only failures: \(summary { $0.lastRunAt = displayNow.addingTimeInterval(-86_400); $0.successCount = 0 })")

check(LearnedShortcutDisplay.attentionLine(for: moveAppLeft) == nil, "a healthy shortcut has no note")
var failingOnce = moveAppLeft; failingOnce.consecutiveFailures = 1
check(LearnedShortcutDisplay.attentionLine(for: failingOnce)?.contains("One more failure") == true, "one failure warns")
check(LearnedShortcutDisplay.attentionLine(for: driftingShortcut) == driftingShortcut.disabledReason, "a shortcut Wisp turned off shows why")
var switchedOffByUser = moveAppLeft; switchedOffByUser.isEnabled = false
check(LearnedShortcutDisplay.attentionLine(for: switchedOffByUser) == nil, "a shortcut the user switched off has no reason")
check(LearnedShortcutDisplay.stepLines(for: twoStepShortcut) == ["Arrange windows: app {app}, placement \"left_half\"", "Chrome organize tabs"], "step lines")

let olderShortcut = LearnedShortcut(phraseTemplate: "older", slots: [], steps: setVolume.steps, createdAt: Date(timeIntervalSince1970: 10))
let newerShortcut = LearnedShortcut(phraseTemplate: "newer", slots: [], steps: setVolume.steps, createdAt: Date(timeIntervalSince1970: 20))
check(LearnedShortcutDisplay.listOrder([olderShortcut, newerShortcut]).map(\.phraseTemplate) == ["newer", "older"], "newest first")

// MARK: Promotion to an automation

func requiresConfirmation(_ toolName: String) -> Bool? {
    switch toolName {
    case "control_music": return false          // trivial and reversible: never asks
    case "arrange_windows", "create_reminder", "chrome_organize_tabs": return true
    default: return nil                          // not registered
    }
}
let musicOnlyShortcut = LearnedShortcut(
    phraseTemplate: "pause the music", slots: [],
    steps: [LearnedShortcutStep(toolName: "control_music", toolInput: .object(["action": .string("pause")]), slotBindings: [])]
)
let schedule8am = AutomationTrigger.schedule(AutomationSchedule(recurrence: .daily, hour: 8, minute: 0))

check(LearnedShortcutPromotion.verdict(for: moveAppLeft, trigger: .manual, toolRequiresConfirmation: requiresConfirmation) == .allowed,
      "any replayable shortcut can become a manual automation (its cards still appear)")
check(LearnedShortcutPromotion.verdict(for: musicOnlyShortcut, trigger: schedule8am, toolRequiresConfirmation: requiresConfirmation) == .allowed,
      "a shortcut whose steps never ask may be scheduled")
if case .refused(let reason) = LearnedShortcutPromotion.verdict(for: moveAppLeft, trigger: schedule8am, toolRequiresConfirmation: requiresConfirmation) {
    check(reason.contains("Arrange windows asks for your OK each time"), "a step that asks can't be scheduled, and the reason names it: \(reason)")
} else { check(false, "a step that asks can't be scheduled") }
check(LearnedShortcutPromotion.verdict(for: moveAppLeft, trigger: .event(.newCanvasItem), toolRequiresConfirmation: requiresConfirmation) != .allowed, "…nor run on an event")
let mixedShortcut = LearnedShortcut(phraseTemplate: "wind down", slots: [], steps: musicOnlyShortcut.steps + moveAppLeft.steps)
check(LearnedShortcutPromotion.verdict(for: mixedShortcut, trigger: schedule8am, toolRequiresConfirmation: requiresConfirmation) != .allowed, "one asking step among quiet ones refuses the whole shortcut")
check(LearnedShortcutPromotion.unattendedProblem(for: moveAppLeft, toolRequiresConfirmation: { _ in nil })?.contains("isn't available") == true, "a tool that isn't registered is refused, not assumed safe")

let promotedAutomation = LearnedShortcutPromotion.automation(from: musicOnlyShortcut, trigger: schedule8am, now: displayNow)
check(promotedAutomation.action == .replayLearnedShortcut(shortcutID: musicOnlyShortcut.id) && promotedAutomation.source == .nothing, "the automation replays that shortcut and reads nothing")
check(promotedAutomation.isValid, "the promoted automation is valid: \(promotedAutomation.validationProblems())")
check(promotedAutomation.notify == .onlyOnFailure && promotedAutomation.outputs == [.notchCard], "a scheduled promotion stays quiet unless it fails")
check(LearnedShortcutPromotion.automation(from: musicOnlyShortcut, trigger: .manual, now: displayNow).notify == .always, "a manual one always reports")
check(LearnedShortcutPromotion.name(for: musicOnlyShortcut) == "Pause the music", "name is the phrase, capitalised")
check(LearnedShortcutPromotion.name(for: moveAppLeft) == "Put Safari on the left", "…with the blank filled by the saved value: \(LearnedShortcutPromotion.name(for: moveAppLeft))")
check(LearnedShortcutDraftEditing.exampleSlotValues(of: moveAppLeft) == ["app": "Safari"], "example values come from the saved steps")

// MARK: Store

// The store is main-actor isolated; top-level script code is not.
MainActor.assumeIsolated {

let storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("learned-shortcuts-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: storeDirectory) }
let storeFileURL = storeDirectory.appendingPathComponent("Wisp/learned-shortcuts.json")

var store: LearnedShortcutStore? = LearnedShortcutStore(fileURL: storeFileURL)
check(store?.shortcuts.isEmpty == true, "new store is empty")
check(store?.add(roundTripShortcut) == .added(roundTripShortcut), "add")
check(store?.add(LearnedShortcut(phraseTemplate: "PUT {app} on the LEFT", slots: roundTripShortcut.slots, steps: roundTripShortcut.steps)) == .duplicatePhrase,
      "same phrase (any case) is a duplicate")
check(store?.add(LearnedShortcut(phraseTemplate: "{app}", slots: roundTripShortcut.slots, steps: roundTripShortcut.steps)) == .invalidShortcut, "all-blank phrase refused")
check(store?.add(LearnedShortcut(phraseTemplate: "go {app} left", slots: [], steps: roundTripShortcut.steps)) == .invalidShortcut, "blank without slot refused")
check(store?.add(LearnedShortcut(phraseTemplate: "go left", slots: roundTripShortcut.slots, steps: roundTripShortcut.steps)) == .invalidShortcut, "slot without blank refused")
check(store?.add(LearnedShortcut(phraseTemplate: "go left", slots: [], steps: [])) == .invalidShortcut, "no steps refused")
store?.add(shortcut(from: reminderDraft))
store?.add(setVolume)

let permissions = (try? FileManager.default.attributesOfItem(atPath: storeFileURL.path))?[.posixPermissions] as? Int
check(permissions == 0o600, "store file is owner-only (\(String(describing: permissions)))")

if let storeData = try? Data(contentsOf: storeFileURL),
   let storeJSON = try? JSONSerialization.jsonObject(with: storeData) as? [String: Any],
   let storedShortcuts = storeJSON["shortcuts"] as? [[String: Any]] {
    let allowedShortcutKeys: Set<String> = [
        "id", "phraseTemplate", "slots", "steps", "spokenConfirmation", "isEnabled", "disabledReason",
        "createdAt", "lastRunAt", "successCount", "consecutiveFailures",
    ]
    check(storedShortcuts.count == 3, "three shortcuts persisted")
    check(storedShortcuts.allSatisfy { Set($0.keys).isSubset(of: allowedShortcutKeys) }, "persisted shortcut keys are only the declared ones")
    check(Set(storeJSON.keys) == ["version", "shortcuts"], "file holds a version and the shortcuts only")
} else {
    check(false, "store file is readable JSON")
}

let matchFromStore = store?.match(transcript: "put Notes on the left", applicationNameResolver: resolveApplicationName)
if case .matched(let storedMatch, let storedSlotValues)? = matchFromStore {
    check(storedMatch.id == roundTripShortcut.id && storedSlotValues == ["app": "Notes"], "store.match finds the shortcut")
} else {
    check(false, "store.match finds the shortcut")
}

store?.recordRun(shortcutID: roundTripShortcut.id, succeeded: false)
check(store?.shortcut(withID: roundTripShortcut.id)?.isEnabled == true, "one failure keeps the stored shortcut on")
store?.recordRun(shortcutID: roundTripShortcut.id, succeeded: false)
check(store?.shortcut(withID: roundTripShortcut.id)?.isEnabled == false, "two failures turn the stored shortcut off")
check(store?.match(transcript: "put Notes on the left", applicationNameResolver: resolveApplicationName) == .noMatch, "a turned-off shortcut stops matching")
store?.setEnabled(true, shortcutID: roundTripShortcut.id)
check(store?.shortcut(withID: roundTripShortcut.id)?.consecutiveFailures == 0
      && store?.shortcut(withID: roundTripShortcut.id)?.disabledReason == nil, "re-enabling clears the streak and the reason")
store?.recordRun(shortcutID: roundTripShortcut.id, succeeded: true)

store = LearnedShortcutStore(fileURL: storeFileURL)
check(store?.shortcuts.count == 3, "reload keeps all shortcuts")
check(store?.shortcut(withID: roundTripShortcut.id)?.successCount == 1, "reload keeps run stats")
store?.delete(shortcutID: roundTripShortcut.id)
check(LearnedShortcutStore(fileURL: storeFileURL).shortcuts.count == 2, "delete persists")

// An unreadable file is not overwritten silently.
try? "not json".write(to: storeFileURL, atomically: true, encoding: .utf8)
let storeOverUnreadableFile = LearnedShortcutStore(fileURL: storeFileURL)
check(storeOverUnreadableFile.shortcuts.isEmpty, "unreadable file -> empty store")
storeOverUnreadableFile.add(setVolume)
let siblingFileNames = (try? FileManager.default.contentsOfDirectory(atPath: storeFileURL.deletingLastPathComponent().path)) ?? []
check(siblingFileNames.contains { $0.contains(".unreadable-") }, "first save keeps a copy of the unreadable file")

// A full store refuses more.
let fullStoreURL = storeDirectory.appendingPathComponent("full/learned-shortcuts.json")
let fullStore = LearnedShortcutStore(fileURL: fullStoreURL)
for index in 0..<LearnedShortcutStore.maximumShortcutCount {
    fullStore.add(LearnedShortcut(phraseTemplate: "do thing number \(index)", slots: [], steps: setVolume.steps))
}
check(fullStore.shortcuts.count == LearnedShortcutStore.maximumShortcutCount, "store fills to its cap")
check(fullStore.add(LearnedShortcut(phraseTemplate: "one more", slots: [], steps: setVolume.steps)) == .tooManyShortcuts, "cap enforced")
}

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
