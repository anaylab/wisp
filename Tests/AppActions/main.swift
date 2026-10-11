//
//  App actions suite: other apps' App Intents metadata, matching a request to
//  an app's actions, the suggested shortcut name, and running it later.
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

// MARK: - Title humanizer

check(AppActionTitleHumanizer.readableTitle(fromKey: "PlayMusicItemSiriIntent_Title") == "Play Music Item", "camel-case key: \(String(describing: AppActionTitleHumanizer.readableTitle(fromKey: "PlayMusicItemSiriIntent_Title")))")
check(AppActionTitleHumanizer.readableTitle(fromKey: "CREATE_FOLDER_INTENT_TITLE") == "Create Folder", "upper snake key")
check(AppActionTitleHumanizer.readableTitle(fromKey: "Add Sticky Note to Board") == "Add Sticky Note to Board", "a title already in words is kept")
check(AppActionTitleHumanizer.readableTitle(fromKey: "?") == nil, "placeholder dropped")
check(AppActionTitleHumanizer.readableTitle(fromKey: "OpenURLLinkIntent") == "Open Url Link", "acronym split: \(String(describing: AppActionTitleHumanizer.readableTitle(fromKey: "OpenURLLinkIntent")))")

// MARK: - Metadata parsing

let sampleMetadata = """
{"actions": {
  "AddNote": {"title": {"key": "ADD_NOTE_TITLE"}, "descriptionMetadata": {"descriptionText": {"key": "ADD_NOTE_DESC"}},
              "parameters": [{"title": {"key": "Text"}}], "visibilityMetadata": {"assistantOnly": false, "isDiscoverable": true}},
  "Hidden": {"title": {"key": "Hidden Thing"}, "visibilityMetadata": {"assistantOnly": true, "isDiscoverable": true}},
  "NotDiscoverable": {"title": {"key": "Secret"}, "isDiscoverable": false},
  "NoTitle": {"title": {"key": "?"}}
}}
""".data(using: .utf8)!
let localizedStrings = ["ADD_NOTE_TITLE": "Add Sticky Note to Board", "ADD_NOTE_DESC": "Adds a sticky note with your text to a board."]
let parsedActions = AppIntentsMetadataParser.actions(fromActionsData: sampleMetadata) { localizedStrings[$0] }
check(parsedActions.map(\.title) == ["Add Sticky Note to Board"], "hidden, undiscoverable and untitled actions dropped: \(parsedActions.map(\.title))")
check(parsedActions.first?.descriptionText == "Adds a sticky note with your text to a board.", "description localized")
check(parsedActions.first?.parameterTitles == ["Text"], "parameter titles")
check(AppIntentsMetadataParser.actions(fromActionsData: Data("not json".utf8)) { _ in nil }.isEmpty, "garbage metadata → no actions")

check(AppIntentsMetadataParser.isInternalTitle("Test: Drive to Apple Park"), "Apple test actions hidden")
check(AppIntentsMetadataParser.isInternalTitle("Update a BookSettings AppEntity's Page Navigation Setting"), "generated entity titles hidden")
check(!AppIntentsMetadataParser.isInternalTitle("Start Navigation in Maps"), "ordinary titles kept")

// A real app's metadata, when this Mac has it (Freeform ships with macOS).
let freeformMetadataURL = URL(fileURLWithPath: "/System/Applications/Freeform.app/Contents/Resources/Metadata.appintents/extract.actionsdata")
if let freeformMetadata = try? Data(contentsOf: freeformMetadataURL) {
    let freeformBundle = Bundle(url: URL(fileURLWithPath: "/System/Applications/Freeform.app"))
    let freeformActions = AppIntentsMetadataParser.actions(fromActionsData: freeformMetadata) { key in
        freeformBundle?.localizedString(forKey: key, value: nil, table: nil)
    }
    check(freeformActions.contains { $0.title == "Add Sticky Note to Board" }, "real Freeform metadata parses: \(freeformActions.prefix(5).map(\.title))")
}

// MARK: - Suggesting a shortcut

func application(_ name: String, _ bundleIdentifier: String, _ actionTitles: [String]) -> InstalledApplicationActions {
    InstalledApplicationActions(
        applicationName: name,
        bundleIdentifier: bundleIdentifier,
        applicationPath: "/Applications/\(name).app",
        actions: actionTitles.map { InstalledAppAction(id: $0, title: $0, descriptionText: nil, parameterTitles: []) }
    )
}
let installedApplications = [
    application("Freeform", "com.apple.freeform", ["Add Sticky Note to Board", "Add Text to Board", "Show/Hide Dot Grid", "Open Board"]),
    application("Microsoft Teams", "com.microsoft.teams2", ["Schedule new Teams meeting", "Change Teams status", "Open Teams calendar"]),
    application("Microsoft Word", "com.microsoft.Word", ["Create Document", "Open Document"]),
    application("Flow", "design.yugen.Flow", ["Start Session", "Pause Session", "Reset Cycle", "Get Phase"]),
]

if let stickySuggestion = AppActionRequestMatcher.suggestion(forRequest: "add a sticky note to my Freeform board saying buy milk", installedApplications: installedApplications) {
    check(stickySuggestion.application.applicationName == "Freeform", "Freeform named")
    check(stickySuggestion.matchedActions.first?.title == "Add Sticky Note to Board", "best action: \(stickySuggestion.matchedActions.map(\.title))")
    check(stickySuggestion.suggestedShortcutName == "Add Sticky Note to Board in Freeform", "suggested name: \(stickySuggestion.suggestedShortcutName)")
} else { check(false, "sticky note request matched") }

if let teamsSuggestion = AppActionRequestMatcher.suggestion(forRequest: "schedule a meeting in Teams with the design group", installedApplications: installedApplications) {
    check(teamsSuggestion.application.bundleIdentifier == "com.microsoft.teams2", "Teams by its short name")
    check(teamsSuggestion.matchedActions.first?.title == "Schedule new Teams meeting", "teams action: \(teamsSuggestion.matchedActions.map(\.title))")
    check(teamsSuggestion.suggestedShortcutName == "Schedule new Teams meeting", "a title naming the app is kept: \(teamsSuggestion.suggestedShortcutName)")
} else { check(false, "teams request matched") }

if let flowSuggestion = AppActionRequestMatcher.suggestion(forRequest: "pause my flow session", installedApplications: installedApplications) {
    check(flowSuggestion.matchedActions.first?.title == "Pause Session", "flow: \(flowSuggestion.matchedActions.map(\.title))")
} else { check(false, "flow request matched") }

if let wordSuggestion = AppActionRequestMatcher.suggestion(forRequest: "create a document in word called trip plan", installedApplications: installedApplications) {
    check(wordSuggestion.suggestedShortcutName == "Create Document in Word", "word: \(wordSuggestion.suggestedShortcutName)")
} else { check(false, "word request matched") }

for unmatched in [
    "how do I add a sticky note in freeform",       // a question, not a request
    "add a word to my vocabulary list",              // "word" isn't the app here
    "open freeform",                                 // only the verb matches; launching apps is elsewhere
    "add a sticky note to my board",                 // no app named
    "change the teams status page in my notes",      // "teams" not used as the app
    "what's on my freeform board",
] {
    check(AppActionRequestMatcher.suggestion(forRequest: unmatched, installedApplications: installedApplications) == nil, "no suggestion: \(unmatched)")
}
check(AppActionRequestMatcher.suggestion(forRequest: "add flow", installedApplications: installedApplications) == nil, "nothing left once the app name is removed")
check(AppActionRequestMatcher.suggestion(forRequest: "freeform", installedApplications: installedApplications) == nil, "a request that is only the app name doesn't crash")

// MARK: - Running the shortcut next time

let shortcutNames = ["Add Sticky Note to Board in Freeform", "Morning Routine", "Log Water", "Weather"]
if let runRequest = ShortcutRunRequestMatcher.runRequest(forRequest: "add a sticky note to my Freeform board saying buy milk", shortcutNames: shortcutNames) {
    check(runRequest.shortcutName == "Add Sticky Note to Board in Freeform", "runs the built shortcut")
    check(runRequest.textInput == "buy milk", "input after 'saying': \(String(describing: runRequest.textInput))")
} else { check(false, "the same request runs the shortcut once it exists") }

check(ShortcutRunRequestMatcher.runRequest(forRequest: "log water 500 ml", shortcutNames: shortcutNames)?.textInput == "500 ml", "leftover words become the input")
check(ShortcutRunRequestMatcher.runRequest(forRequest: "run my morning routine", shortcutNames: shortcutNames)?.shortcutName == "Morning Routine", "run cue")
check(ShortcutRunRequestMatcher.runRequest(forRequest: "run my morning routine", shortcutNames: shortcutNames)?.textInput == nil, "no input left")
check(ShortcutRunRequestMatcher.runRequest(forRequest: "what's the weather", shortcutNames: shortcutNames) == nil, "one-word names never run directly")
check(ShortcutRunRequestMatcher.runRequest(forRequest: "how much water should I log", shortcutNames: shortcutNames) == nil, "must start like the name or with 'run'")
check(ShortcutRunRequestMatcher.textInput(fromRequest: "add a sticky note in freeform: \"call mom\"", shortcutName: "Add Sticky Note to Board in Freeform") == "call mom", "quoted input wins")
check(ShortcutRunRequestMatcher.textInput(fromRequest: "add a sticky note in freeform: call mom", shortcutName: "Add Sticky Note to Board in Freeform") == "call mom", "text after a colon")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
