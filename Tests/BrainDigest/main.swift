//
//  Brain digest suite: the pure policy behind the conversation digest and
//  notes import. No model, no Wisp vault — the folder-walk test uses a
//  temporary directory.
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

let utc = TimeZone(identifier: "UTC")!
let referenceNow = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 ~14:13 UTC

func exchangeRecord(
    _ question: String,
    answer: String? = "Sure.",
    minutesAgo: Double,
    status: AgentTaskRecord.Status = .succeeded,
    kind: AgentTaskRecord.Kind = .interactive,
    steps: [AgentStepRecord] = []
) -> AgentTaskRecord {
    AgentTaskRecord(
        title: question,
        kind: kind,
        status: status,
        steps: steps,
        startedAt: referenceNow.addingTimeInterval(-minutesAgo * 60),
        finishedAt: referenceNow.addingTimeInterval(-minutesAgo * 60 + 5),
        finalText: answer
    )
}

// MARK: - Exchange filtering

do {
    let records = [
        exchangeRecord("I'm moving to Berlin in March for the Atlas job", answer: "Congrats! [SAY: congrats] [POINT:10,20:thing]", minutesAgo: 60),
        exchangeRecord("open safari", answer: "Opening Safari", minutesAgo: 59),
        exchangeRecord("set a timer for 5 minutes", answer: "Timer set", minutesAgo: 58),
        exchangeRecord("mute", answer: "Muted", minutesAgo: 57),
        exchangeRecord("new tab", answer: "Opened", minutesAgo: 56),
        exchangeRecord("what's the weather", answer: "Sunny", minutesAgo: 55,
                       steps: [AgentStepRecord(kind: .modelCall, summary: "Handled natively — no model call")]),
        exchangeRecord(AgentTaskRecord.routineRunTitlePrefix + "Summarize page", minutesAgo: 54),
        exchangeRecord(AgentTaskRecord.skillRunTitlePrefix + "Research", minutesAgo: 53),
        exchangeRecord(AgentTaskRecord.buddyRunTitlePrefix + "Cloud", minutesAgo: 52),
        exchangeRecord("explain quantum tunnelling to me", minutesAgo: 51, status: .failed("offline")),
        exchangeRecord("what did we decide about the database", answer: nil, minutesAgo: 50),
        exchangeRecord("summarize my week", minutesAgo: 49, kind: .background),
        exchangeRecord("hey wisp, can you please open notes", answer: "Opening Notes", minutesAgo: 48),
        exchangeRecord("text mom i'm late", answer: "Sent", minutesAgo: 47),
    ]
    let exchanges = BrainConversationDigestPlanner.digestibleExchanges(from: records)
    check(exchanges.count == 1, "only the user's real conversational exchange survives (got \(exchanges.map(\.question)))")
    check(exchanges.first?.answer == "Congrats!", "machine tags are stripped from answers (got \(exchanges.first?.answer ?? "nil"))")

    let withInjectedRouter = BrainConversationDigestPlanner.digestibleExchanges(
        from: [exchangeRecord("github atlas issues please", minutesAgo: 10)],
        isDirectCommand: { $0.contains("github") }
    )
    check(withInjectedRouter.isEmpty, "the app's own routers can mark requests as commands")
}

// MARK: - Command / small talk / screen heuristics

check(BrainConversationDigestPlanner.looksLikePlainCommand("Open Xcode"), "open is a command")
check(BrainConversationDigestPlanner.looksLikePlainCommand("Hey Wisp, could you turn the volume down?"), "courtesy openers are stripped before matching")
check(!BrainConversationDigestPlanner.looksLikePlainCommand("What should I name the Atlas launch?"), "a question is not a command")
check(BrainConversationDigestPlanner.isSmallTalk("Thanks!"), "thanks is small talk")
check(!BrainConversationDigestPlanner.isSmallTalk("I'm vegetarian"), "a short fact is not small talk")
check(BrainConversationDigestPlanner.looksLikeEphemeralScreenRequest("where is the save button"), "pointing is ephemeral")
check(BrainConversationDigestPlanner.mentionsTheUser("my sister Priya starts at Stripe next week"), "my → about the user")
check(!BrainConversationDigestPlanner.mentionsTheUser("how do i center a div in css"), "\"how do i\" is grammar, not the user")
check(!BrainConversationDigestPlanner.mentionsTheUser("tell me about the roman empire"), "\"tell me\" is grammar, not the user")
check(BrainConversationDigestPlanner.mentionsTheUser("we decided to use postgres for atlas"), "we decided → about the user")

// MARK: - Worth digesting

func exchange(_ question: String) -> BrainDigestExchange {
    BrainDigestExchange(question: question, answer: "An answer.", askedDate: referenceNow)
}

check(!BrainConversationDigestPlanner.isWorthDigesting([]), "no exchanges → skip")
check(!BrainConversationDigestPlanner.isWorthDigesting([exchange("what's the capital of France")]), "a lone general-knowledge question is skipped")
check(!BrainConversationDigestPlanner.isWorthDigesting([exchange("thanks"), exchange("where is the save button")]), "small talk + screen help is skipped")
check(BrainConversationDigestPlanner.isWorthDigesting([exchange("I'm vegetarian")]), "a short fact about the user is kept")
check(BrainConversationDigestPlanner.isWorthDigesting([exchange("my manager Dana wants the Atlas spec by Friday")]), "a fact about the user's work is kept")
check(BrainConversationDigestPlanner.isWorthDigesting([
    exchange("compare postgres and sqlite for a local app"),
    exchange("which one handles concurrent writers better")
]), "a real back-and-forth is kept")
check(!BrainConversationDigestPlanner.isWorthDigesting([exchange("how do i center a div")]), "a lone how-to is skipped")

// MARK: - Session readiness

do {
    let records = [
        // Old session, ended long ago.
        exchangeRecord("first session question about atlas", minutesAgo: 300),
        exchangeRecord("follow up about atlas", minutesAgo: 295),
        // Middle session, ended.
        exchangeRecord("second session", minutesAgo: 200),
        // Live session: last exchange 10 minutes ago → not ended.
        exchangeRecord("current session", minutesAgo: 10),
    ]
    let sessions = NotchConversationSessionGrouper.sessions(from: records)
    check(sessions.count == 3, "grouper splits on 30-minute gaps (got \(sessions.count))")

    let freshState = BrainConversationDigestState()
    let ready = BrainConversationDigestPlanner.sessionsReadyToDigest(from: sessions, state: freshState, now: referenceNow)
    check(ready.count == 2, "only ended sessions are ready (got \(ready.count))")
    check(ready.first?.exchanges.first?.title == "first session question about atlas", "ready sessions are oldest first")

    let capped = BrainConversationDigestPlanner.sessionsReadyToDigest(from: sessions, state: freshState, now: referenceNow, maximumSessionCount: 1)
    check(capped.count == 1, "the per-pass cap applies")

    var handledState = freshState
    if let firstReady = ready.first {
        handledState.markSessionHandled(sessionID: firstReady.id, lastExchangeDate: firstReady.lastActivityAt)
    }
    let afterHandling = BrainConversationDigestPlanner.sessionsReadyToDigest(from: sessions, state: handledState, now: referenceNow)
    check(afterHandling.count == 1 && afterHandling.first?.title == "second session", "a handled session isn't offered again")

    // The watermark alone also excludes it, after the records are filtered
    // and re-grouped (as the digester does).
    var watermarkOnlyState = BrainConversationDigestState()
    watermarkOnlyState.lastDigestedExchangeDate = handledState.lastDigestedExchangeDate
    let regroupedSessions = NotchConversationSessionGrouper.sessions(
        from: BrainConversationDigestPlanner.recordsAfterWatermark(records, watermark: BrainConversationDigestPlanner.effectiveWatermark(state: watermarkOnlyState, now: referenceNow))
    )
    let readyAfterWatermark = BrainConversationDigestPlanner.sessionsReadyToDigest(from: regroupedSessions, state: watermarkOnlyState, now: referenceNow)
    check(readyAfterWatermark.map(\.title) == ["second session"], "the watermark excludes digested exchanges")

    // A running turn keeps a session open.
    let runningRecords = [exchangeRecord("long task", minutesAgo: 120, status: .running)]
    let runningReady = BrainConversationDigestPlanner.sessionsReadyToDigest(
        from: NotchConversationSessionGrouper.sessions(from: runningRecords), state: freshState, now: referenceNow)
    check(runningReady.isEmpty, "a session with a running turn isn't ready")

    // First run looks back one week only.
    let oldRecords = [exchangeRecord("ancient history", minutesAgo: 8 * 24 * 60)]
    let oldReady = BrainConversationDigestPlanner.sessionsReadyToDigest(
        from: NotchConversationSessionGrouper.sessions(from: oldRecords), state: freshState, now: referenceNow)
    check(oldReady.isEmpty, "first run ignores sessions older than 7 days")
}

// MARK: - Failure bookkeeping

do {
    var state = BrainConversationDigestState()
    let sessionID = UUID()
    let lastDate = referenceNow
    check(!state.recordFailedAttempt(sessionID: sessionID, lastExchangeDate: lastDate), "first failure retries")
    check(!state.recordFailedAttempt(sessionID: sessionID, lastExchangeDate: lastDate), "second failure retries")
    check(state.recordFailedAttempt(sessionID: sessionID, lastExchangeDate: lastDate), "third failure gives up")
    check(state.digestedSessionIDs.contains(sessionID) && state.lastDigestedExchangeDate == lastDate, "giving up marks the session handled")
    check(state.failedAttemptCountsBySessionID.isEmpty, "handled sessions drop their failure count")

    // Round trip keeps sub-second precision (the watermark is compared with >).
    state.lastDigestedExchangeDate = Date(timeIntervalSince1970: 1_790_000_000.456)
    let encoded = try! JSONEncoder().encode(state)
    let decoded = try! JSONDecoder().decode(BrainConversationDigestState.self, from: encoded)
    check(decoded == state, "digest state round-trips exactly")
}

// MARK: - Text

do {
    let sessionStart = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
    check(BrainConversationDigestPlanner.transcriptFileStem(for: sessionStart, timeZone: utc) == "2026-09-21 1413", "transcript file stem")
    check(BrainConversationDigestPlanner.provenanceLabel(for: sessionStart, timeZone: utc) == "conversation 2026-09-21 14:13", "provenance label")

    let exchanges = [
        BrainDigestExchange(question: "I'm moving to Berlin", answer: "Exciting!\nGood luck.", askedDate: sessionStart)
    ]
    let transcript = BrainConversationDigestPlanner.transcriptMarkdown(exchanges: exchanges, sessionStartDate: sessionStart, timeZone: utc)
    check(transcript.hasPrefix("# Conversation 2026-09-21 14:13"), "transcript heading")
    check(transcript.contains("**You:** I'm moving to Berlin") && transcript.contains("**Wisp:** Exciting!"), "transcript lines")

    let material = BrainConversationDigestPlanner.materialText(exchanges: exchanges, sessionStartDate: sessionStart, timeZone: utc)
    check(material.contains("User: I'm moving to Berlin\nWisp: Exciting! Good luck."), "material is compact one-line exchanges (got \(material))")

    let longExchanges = (0..<40).map { index in
        BrainDigestExchange(question: "question number \(index) about my project", answer: String(repeating: "long answer ", count: 100), askedDate: sessionStart)
    }
    let longMaterial = BrainConversationDigestPlanner.materialText(exchanges: longExchanges, sessionStartDate: sessionStart, timeZone: utc)
    check(longMaterial.count <= BrainConversationDigestPlanner.maximumMaterialCharacters, "material stays within the cap (\(longMaterial.count))")
    check(longMaterial.contains("question number 39"), "the newest exchanges are kept when material is cut")
}

// MARK: - Summary line

check(BrainConversationDigestPlanner.summaryLine(
    changeDescriptions: ["added 3 facts to Me", "added 1 fact to Atlas"], touchedPageCount: 2,
    digestedSessionCount: 1, skippedSessionCount: 0) == "filed 4 facts into 2 pages from 1 conversation", "summary with facts")
check(BrainConversationDigestPlanner.summaryLine(
    changeDescriptions: ["added 2 facts to Me", "summarised Atlas"], touchedPageCount: 2,
    digestedSessionCount: 1, skippedSessionCount: 1) == "filed 2 facts and 1 other change into 2 pages from 2 conversations", "summary with other changes")
check(BrainConversationDigestPlanner.summaryLine(
    changeDescriptions: [], touchedPageCount: 0,
    digestedSessionCount: 0, skippedSessionCount: 2) == "nothing lasting in 2 conversations", "summary when nothing was filed")

// MARK: - Notes import: filters and paths

let supportedExtensions: Set<String> = ["md", "markdown", "txt", "pdf", "html", "htm", "rtf", "docx", "json", "csv"]

check(BrainNotesImportPlanner.shouldSkipDirectory(named: ".obsidian"), "skip .obsidian")
check(BrainNotesImportPlanner.shouldSkipDirectory(named: ".trash"), "skip .trash")
check(BrainNotesImportPlanner.shouldSkipDirectory(named: "node_modules"), "skip node_modules")
check(BrainNotesImportPlanner.shouldSkipDirectory(named: ".hidden"), "skip hidden folders")
check(!BrainNotesImportPlanner.shouldSkipDirectory(named: "Projects"), "walk ordinary folders")
check(BrainNotesImportPlanner.shouldConsiderFile(named: "Atlas.MD", byteCount: 100, supportedFileExtensions: supportedExtensions), "md (any case) is a note")
check(!BrainNotesImportPlanner.shouldConsiderFile(named: "photo.png", byteCount: 100, supportedFileExtensions: supportedExtensions), "png isn't")
check(!BrainNotesImportPlanner.shouldConsiderFile(named: ".DS_Store", byteCount: 100, supportedFileExtensions: supportedExtensions), "hidden files aren't")
check(!BrainNotesImportPlanner.shouldConsiderFile(named: "huge.md", byteCount: 3 * 1024 * 1024, supportedFileExtensions: supportedExtensions), "files over 2MB aren't")
check(!BrainNotesImportPlanner.shouldConsiderFile(named: "empty.md", byteCount: 0, supportedFileExtensions: supportedExtensions), "empty files aren't")

check(BrainNotesImportPlanner.rawDestinationRelativePath(importedFolderName: "My Vault", fileRelativePath: "Projects/Atlas.md")
      == "notes/My Vault/Projects/Atlas.md", "raw path keeps the relative path")
check(BrainNotesImportPlanner.rawDestinationRelativePath(importedFolderName: "..", fileRelativePath: "../evil:name.md")
      == "notes/Notes/Untitled/evil name.md", "raw path components can't climb out (got \(BrainNotesImportPlanner.rawDestinationRelativePath(importedFolderName: "..", fileRelativePath: "../evil:name.md")))")
check(BrainNotesImportPlanner.safePathComponent("a/b:c") == "a b c", "unsafe characters become spaces")
check(BrainNotesImportPlanner.safePathComponent("   ") == "Untitled", "blank names fall back")
check(BrainNotesImportPlanner.safePathComponent(String(repeating: "x", count: 200)).count == 80, "names are capped at 80")

// MARK: - Notes import: folder walk + dedupe

do {
    let temporaryFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("brain-digest-test-\(UUID().uuidString)", isDirectory: true)
    let vaultURL = temporaryFolderURL.appendingPathComponent("Vault", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
    func writeFile(_ relativePath: String, _ contents: String) {
        let fileURL = vaultURL.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    writeFile("Atlas.md", "# Atlas\nthe project")
    writeFile("Projects/Berlin.md", "moving in march")
    writeFile("Projects/Copy of Atlas.md", "# Atlas\nthe project")
    writeFile(".obsidian/workspace.json", "{}")
    writeFile(".trash/old.md", "deleted")
    writeFile("node_modules/pkg/readme.md", "dependency")
    writeFile("image.png", "not really a png")
    writeFile(".hidden.md", "hidden")

    let scanned = BrainNotesImportPlanner.scanFolder(vaultURL, supportedFileExtensions: supportedExtensions)
    let scannedPaths = scanned.map(\.relativePath)
    check(Set(scannedPaths) == ["Atlas.md", "Projects/Berlin.md", "Projects/Copy of Atlas.md"], "walk finds only notes (got \(scannedPaths))")

    let hashed = scanned.map { scannedFile in
        BrainNoteFileToImport(scannedFile: scannedFile, contentHash: BrainNotesImportPlanner.contentHash(of: try! Data(contentsOf: scannedFile.fileURL)))
    }
    let firstPlan = BrainNotesImportPlanner.planFolderImport(hashedFiles: hashed, state: BrainNotesImportState())
    check(firstPlan.filesToImport.count == 2 && firstPlan.alreadyImportedFileCount == 1, "identical files import once")

    var stateAfterFirstRun = BrainNotesImportState()
    for importedFile in firstPlan.filesToImport { stateAfterFirstRun.importedContentHashes.insert(importedFile.contentHash) }
    let secondPlan = BrainNotesImportPlanner.planFolderImport(hashedFiles: hashed, state: stateAfterFirstRun)
    check(secondPlan.filesToImport.isEmpty && secondPlan.alreadyImportedFileCount == 3, "re-import is incremental")

    let cappedPlan = BrainNotesImportPlanner.planFolderImport(hashedFiles: hashed, state: BrainNotesImportState(), maximumFileCount: 1)
    check(cappedPlan.filesToImport.count == 1 && cappedPlan.deferredFileCount == 1, "the per-run cap defers the rest")
    check(BrainNotesImportPlanner.cappedRunMessage(importedFileCount: 500, deferredFileCount: 312).hasPrefix("imported 500 of 812 new notes"), "capped message")
}

check(BrainNotesImportPlanner.contentHash(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "content hash is SHA-256 hex")

// MARK: - Apple Notes

do {
    let modified = Date(timeIntervalSince1970: 1_780_000_000)
    let listing = [
        AppleNoteListingEntry(noteID: "n1", name: "Groceries", modificationDate: modified, isPasswordProtected: false, isInRecentlyDeleted: false),
        AppleNoteListingEntry(noteID: "n2", name: "Diary", modificationDate: modified, isPasswordProtected: true, isInRecentlyDeleted: false),
        AppleNoteListingEntry(noteID: "n3", name: "Old", modificationDate: modified, isPasswordProtected: false, isInRecentlyDeleted: true),
        AppleNoteListingEntry(noteID: "n4", name: "Groceries", modificationDate: modified, isPasswordProtected: false, isInRecentlyDeleted: false),
    ]
    let fresh = BrainNotesImportPlanner.appleNotesToFetch(listing: listing, state: BrainNotesImportState())
    check(fresh.map(\.noteID) == ["n1", "n4"], "locked and deleted notes are left out")

    var state = BrainNotesImportState()
    state.appleNotesByNoteID["n1"] = .init(modificationDate: modified, contentHash: "h", fileName: "Groceries.html")
    let afterImport = BrainNotesImportPlanner.appleNotesToFetch(listing: listing, state: state)
    check(afterImport.map(\.noteID) == ["n4"], "unchanged notes aren't fetched again")

    var editedListing = listing
    editedListing[0].modificationDate = modified.addingTimeInterval(60)
    check(BrainNotesImportPlanner.appleNotesToFetch(listing: editedListing, state: state).map(\.noteID) == ["n1", "n4"], "edited notes are fetched again")

    check(BrainNotesImportPlanner.fileName(forAppleNote: listing[0], state: state, namesClaimedThisRun: []) == "Groceries.html", "a note keeps its file name")
    check(BrainNotesImportPlanner.fileName(forAppleNote: listing[3], state: state, namesClaimedThisRun: []) == "Groceries 2.html", "a same-named note gets a numbered name")
    check(BrainNotesImportPlanner.fileName(forAppleNote: listing[3], state: state, namesClaimedThisRun: ["Groceries 2.html"]) == "Groceries 3.html", "names claimed this run count as taken")

    let document = BrainNotesImportPlanner.appleNoteHTMLDocument(title: "A <b> & c", bodyHTML: "<div>milk</div>", modificationDate: modified)
    check(document.contains("<title>A &lt;b&gt; &amp; c</title>") && document.contains("<div>milk</div>"), "note document escapes the title, keeps the body")

    let encodedState = try! JSONEncoder().encode(state)
    check((try? JSONDecoder().decode(BrainNotesImportState.self, from: encodedState)) == state, "import state round-trips")
}

print("\(checkCount - failureCount)/\(checkCount) brain digest checks passed")
exit(failureCount == 0 ? 0 : 1)
