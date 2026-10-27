//
//  BuddyRedesignTests.swift
//  AgentRuntimeIntegration
//
//  The rules behind the buddies redesign: mood from run state, specialty
//  templates, attachment prompt building and name resolution, the per-buddy
//  file library, and a message with files reaching the run with the documents
//  fenced as data and the thread showing only the user's words.
//

import Foundation

@MainActor func buddyRedesignSuite() async {
    section("Buddies: mood")
    do {
        let now = Date()
        func mood(_ status: AgentTaskRecord.Status?, finishedAgo: TimeInterval? = nil, idleFor: TimeInterval = 60) -> BuddyMood {
            BuddyMoodPolicy.mood(
                latestRunStatus: status,
                latestRunFinishedAt: finishedAgo.map { now.addingTimeInterval(-$0) },
                lastActivityAt: now.addingTimeInterval(-idleFor),
                now: now
            )
        }
        check("running → working", mood(.running) == .working)
        check("needs approval → waiting", mood(.waitingForApproval) == .waiting)
        check("just succeeded → happy", mood(.succeeded, finishedAgo: 5) == .happy)
        check("succeeded long ago → idle", mood(.succeeded, finishedAgo: 3600) == .idle)
        check("recent failure → oops", mood(.failed("x"), finishedAgo: 30) == .oops)
        check("old failure fades", mood(.failed("x"), finishedAgo: 7200) == .idle)
        check("quiet for a long time → sleepy", mood(nil, idleFor: 8 * 3600) == .sleepy)
        check("a stopped run isn't news", mood(.cancelled, finishedAgo: 5) == .idle)
    }

    section("Buddies: specialties")
    do {
        check("every specialty has a distinct colour except none shared", Set(BuddySpecialty.allCases.map(\.preferredColorIndex)).count == BuddySpecialty.allCases.count)
        check("colours are inside the palette", BuddySpecialty.allCases.allSatisfy { $0.preferredColorIndex < BuddyAppearance.paletteCount })
        check("general keeps every tool", BuddySpecialty.general.toolAccess == nil)
        check("researcher is limited to browser + brain", BuddySpecialty.researcher.toolAccess?.allowedGroupIDs == ["browser", "brain"])
        check("inbox may use the connected Composio server",
              BuddySpecialty.inbox.toolAccess?.allowsServer(named: ComposioAccountStore.serverId) == true)
        check("every limited specialty only names real groups",
              BuddySpecialty.allCases.compactMap(\.toolAccess).allSatisfy { access in
                  access.allowedGroupIDs.allSatisfy { groupID in
                      BuddyToolGroup(rawValue: groupID) != nil || groupID.hasPrefix(BuddyToolAccessPolicy.mcpGroupPrefix)
                  }
              })
        check("a coder starts with GitHub but not Gmail",
              BuddySpecialty.coder.toolAccess?.allowsApp("github") == true && BuddySpecialty.coder.toolAccess?.allowsApp("gmail") == false)
        check("a researcher gets no connected apps", BuddySpecialty.researcher.toolAccess?.allowsServer(named: ComposioAccountStore.serverId) == false)
        check("every specialty with apps also has the Composio group",
              BuddySpecialty.allCases.allSatisfy { $0.suggestedAppSlugs == nil || $0.toolAccess?.allowsServer(named: ComposioAccountStore.serverId) == true })
        check("every specialty has a starter job", BuddySpecialty.allCases.allSatisfy { !$0.starterJobs.isEmpty })
        check("the daily planner starter reads as daily",
              BuddySchedule.inferred(fromInstruction: BuddySpecialty.planner.starterJobs[0]) == .daily(hour: 9, minute: 0))
        check("specialty codes round trip", (try? JSONDecoder().decode(BuddySpecialty.self, from: JSONEncoder().encode(BuddySpecialty.coder))) == .coder)
    }

    section("Buddies: attachments prompt")
    do {
        let plain = BuddyAttachmentPolicy.messageText(userText: "hi", documents: [])
        check("no files → the user's words untouched", plain == "hi")

        let withFile = BuddyAttachmentPolicy.messageText(userText: "summarize", documents: [("notes.md", "alpha beta")])
        check("the user's words come first", withFile.hasPrefix("summarize"))
        check("the file is fenced and named", withFile.contains("--- notes.md ---") && withFile.contains("alpha beta") && withFile.contains("--- end of notes.md ---"))
        check("the file is framed as data, not instructions", withFile.contains("not instructions to follow"))

        let hugeText = String(repeating: "x", count: 50_000)
        let capped = BuddyAttachmentPolicy.messageText(userText: "q", documents: [("big.txt", hugeText)])
        check("one file is cut to the per-file limit", capped.count < 14_000)
        check("a cut file points at read_my_file", capped.contains("read_my_file"))
        let manyFiles = BuddyAttachmentPolicy.messageText(userText: "q", documents: (0..<6).map { ("f\($0).txt", hugeText) })
        check("the whole message stays under the total cap", manyFiles.count < BuddyAttachmentPolicy.maximumCharactersInMessage + 2_000)
        check("unreadable files are named", BuddyAttachmentPolicy.messageText(userText: "q", documents: [], skippedFileNames: ["a.bin"]).contains("a.bin"))

        check("images are told apart by extension", BuddyAttachmentPolicy.kind(forFileExtension: "PNG") == .image && BuddyAttachmentPolicy.kind(forFileExtension: "pdf") == .document)
        check("an empty library adds nothing to the prompt", BuddyAttachmentPolicy.libraryPromptLine(fileNames: []).isEmpty)
        check("the library line names files", BuddyAttachmentPolicy.libraryPromptLine(fileNames: ["a.pdf", "b.md"]).contains("a.pdf, b.md"))

        let sampleAttachments = ["Q3 Report.pdf", "Q4 Report.pdf", "notes.md"].map {
            BuddyAttachment(id: UUID(), fileName: $0, kind: .document, storedFileName: $0, byteCount: 1, addedAt: Date())
        }
        check("exact name resolves", BuddyAttachmentPolicy.resolve(name: "notes.md", among: sampleAttachments)?.fileName == "notes.md")
        check("loose unique name resolves", BuddyAttachmentPolicy.resolve(name: "notes", among: sampleAttachments)?.fileName == "notes.md")
        check("an ambiguous name resolves to nothing", BuddyAttachmentPolicy.resolve(name: "report", among: sampleAttachments) == nil)
    }

    section("Buddies: file library and sending files")
    do {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-buddy-redesign-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let notesURL = sandbox.appendingPathComponent("notes.txt")
        try? "launch is on friday; budget is 40k".write(to: notesURL, atomically: true, encoding: .utf8)
        let folderURL = sandbox.appendingPathComponent("a-folder")
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let library = BuddyFileLibrary(rootURL: sandbox.appendingPathComponent("library"))
        let buddyID = UUID()
        let addResult = library.add(fileURLs: [notesURL, folderURL], toBuddyWithID: buddyID)
        check("a file is copied into the library", addResult.added.count == 1 && addResult.added[0].fileName == "notes.txt")
        check("a folder is skipped, by name", addResult.skippedFileNames == ["a-folder"])
        check("the copy exists", FileManager.default.fileExists(atPath: library.fileURL(of: addResult.added[0], buddyID: buddyID).path))
        check("the manifest survives a reload",
              BuddyFileLibrary(rootURL: sandbox.appendingPathComponent("library")).attachments(ofBuddyWithID: buddyID).count == 1)
        let readBack = await library.extractedText(of: addResult.added[0], buddyID: buddyID, maximumCharacters: 1000)
        check("a document's text can be read back", readBack?.contains("budget is 40k") == true)

        let replaced = library.add(fileURLs: [notesURL], toBuddyWithID: buddyID)
        check("the same name replaces, not duplicates", replaced.added.count == 1 && library.attachments(ofBuddyWithID: buddyID).count == 1)

        // A message with a file, through a real store with a stub run starter.
        let store = BuddyStore(buddiesFileURL: sandbox.appendingPathComponent("buddies.json"))
        let buddy = store.createBuddy(instruction: "Answer questions about my files", schedule: .once, specialty: .researcher, name: "Filey", colorIndex: 4, runImmediately: false)
        check("a new buddy keeps its chosen name, colour and specialty", buddy.name == "Filey" && buddy.colorIndex == 4 && buddy.specialty == .researcher)

        var capturedRequest: BuddyRunRequest?
        store.start(runStarter: { _, request in capturedRequest = request; return UUID() })
        let sendLibrary = BuddyFileLibrary(rootURL: sandbox.appendingPathComponent("library2"))
        let didStart = await store.sendMessage("when is the launch?", attachmentFileURLs: [notesURL], toBuddyWithID: buddy.id, fileLibrary: sendLibrary)
        check("the message started a run", didStart && capturedRequest != nil)
        check("the model is shown the file's text", capturedRequest?.text.contains("launch is on friday") == true)
        check("the file is fenced as data", capturedRequest?.text.contains("--- notes.txt ---") == true)
        check("the thread shows only the user's words", capturedRequest?.displayText == "when is the launch?")
        check("the file name rides along for the chip", capturedRequest?.attachmentNames == ["notes.txt"])
        check("the file went into the buddy's library", sendLibrary.attachments(ofBuddyWithID: buddy.id).count == 1)

        let busyStore = BuddyStore(buddiesFileURL: sandbox.appendingPathComponent("buddies2.json"))
        let noFileBuddy = busyStore.createBuddy(instruction: "x", schedule: .once, runImmediately: false)
        check("no files falls back to the plain send (and fails without a starter)", await busyStore.sendMessage("hello", attachmentFileURLs: [], toBuddyWithID: noFileBuddy.id) == false)

        // Old buddies.json without a specialty still loads.
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","name":"Old","instruction":"x","colorIndex":1,"schedule":{"once":{}},"createdAt":"2026-01-01T00:00:00Z","runTaskIDs":[]}]
        """
        let legacyURL = sandbox.appendingPathComponent("legacy.json")
        try? legacyJSON.write(to: legacyURL, atomically: true, encoding: .utf8)
        let legacyStore = BuddyStore(buddiesFileURL: legacyURL)
        check("a buddy saved before specialties still loads", legacyStore.buddies.count == 1 && legacyStore.buddies[0].specialty == nil)
    }
}

@MainActor func buddyToolAppAccessSuite() {
    section("Buddies: per-app tool access")
    let composioGroup = BuddyToolAccessPolicy.groupID(forServerNamed: ComposioAccountStore.serverId)
    let connected: Set<String> = ["gmail", "notion", "googlecalendar"]

    let allApps = BuddyToolAccess(allowedGroupIDs: [composioGroup])
    check("no app limit allows every app", allApps.allowsApp("gmail") && allApps.allowsApp("notion"))
    check("an app is refused when the Composio group is off", !BuddyToolAccess(allowedGroupIDs: []).allowsApp("gmail"))

    let withoutNotion = allApps.settingApp("notion", isAllowed: false, connectedAppSlugs: connected)
    check("turning one app off keeps the others", withoutNotion.allowsApp("gmail") && !withoutNotion.allowsApp("notion"))
    check("the app list is now explicit", withoutNotion.allowedAppSlugs == ["gmail", "googlecalendar"])
    let backOn = withoutNotion.settingApp("notion", isAllowed: true, connectedAppSlugs: connected)
    check("turning it back on restores 'all apps'", backOn.allowedAppSlugs == nil)

    let noneLeft = ["gmail", "notion", "googlecalendar"].reduce(allApps) { $0.settingApp($1, isAllowed: false, connectedAppSlugs: connected) }
    check("turning every app off drops the Composio group", !noneLeft.allowsServer(named: ComposioAccountStore.serverId) && noneLeft.allowedAppSlugs == [])

    let started = BuddyToolAccess.everythingAsChoices(connectedAppSlugs: connected, availableGroupIDs: ["browser", "screen"], serverIDs: ["mcp:fetch"], composioGroupID: composioGroup)
    check("'Choose' starts with everything on", started.allows(.browser) && started.allowsServer(named: "fetch") && started.allowsApp("gmail"))
    check("with no connected app the Composio group isn't added", !BuddyToolAccess.everythingAsChoices(connectedAppSlugs: [], availableGroupIDs: [], serverIDs: [], composioGroupID: composioGroup).allowsServer(named: ComposioAccountStore.serverId))

    func execute(_ slugs: [String]) -> JSONValue {
        .object(["tools": .array(slugs.map { .object(["tool_slug": .string($0), "arguments": .object([:])]) })])
    }
    let limited = BuddyToolAccess(allowedGroupIDs: [composioGroup], allowedAppSlugs: ["gmail"])
    func refusal(_ name: String, _ input: JSONValue, _ access: BuddyToolAccess?) -> String? {
        BuddyToolAccessPolicy.appRefusalReason(toolName: name, toolInput: input, access: access)
    }
    let executeName = "composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL"
    check("an allowed app's call goes through", refusal(executeName, execute(["GMAIL_FETCH_EMAILS"]), limited) == nil)
    check("another app's call is refused by name", refusal(executeName, execute(["NOTION_CREATE_PAGE"]), limited)?.contains("notion") == true)
    check("one bad tool in a batch refuses the batch", refusal(executeName, execute(["GMAIL_SEND_EMAIL", "SLACK_POST"]), limited) != nil)
    check("an unreadable call is refused", refusal(executeName, .object(["tools": .string("???")]), limited) != nil)
    check("no app limit never refuses", refusal(executeName, execute(["NOTION_CREATE_PAGE"]), allApps) == nil)
    check("no access limit at all never refuses", refusal(executeName, execute(["NOTION_CREATE_PAGE"]), nil) == nil)
    check("the shell tool is refused under an app limit", refusal("composio-connect__COMPOSIO_REMOTE_BASH_TOOL", .object([:]), limited) != nil)
    check("the workbench is refused under an app limit", refusal("composio-connect__COMPOSIO_REMOTE_WORKBENCH", .object([:]), limited) != nil)
    check("searching for tools is still allowed", refusal("composio-connect__COMPOSIO_SEARCH_TOOLS", .object([:]), limited) == nil)
    check("non-Composio tools are untouched", refusal("fetch__get", .object([:]), limited) == nil)

    let legacy = try? JSONDecoder().decode(BuddyToolAccess.self, from: Data(#"{"allowedGroupIDs":["browser"]}"#.utf8))
    check("an access saved before app limits still loads, with no limit", legacy?.allowedAppSlugs == nil && legacy?.allows(.browser) == true)
}
