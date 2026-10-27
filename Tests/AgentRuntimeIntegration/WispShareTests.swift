//
//  WispShareTests.swift
//  AgentRuntimeIntegration
//
//  Sharing routines and buddies as files: what is exported (setup only), how a
//  file from someone else is validated and cleaned, what the review warns about,
//  and that importing adds things inert — no shortcut, no schedule, no run.
//

import Foundation

@MainActor func wispShareSuite() {
    section("Sharing: export")
    let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-share-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

    let routine = WispRoutine(
        name: "Brief {person}", instruction: "Brief {person} on {topic|the launch}", symbolName: "sparkles", shortcutDigit: 3,
        suggestedAppBundleIdentifiers: ["com.apple.mail"], suggestedAppNames: ["Mail"], isPinnedInNotch: true,
        lastRunAt: Date(), lastParameterValues: ["person": "Sam"]
    )
    let sharedRoutine = WispShareBundleCodec.sharedRoutine(from: routine)
    check("a routine is shared as its setup", sharedRoutine.name == "Brief {person}" && sharedRoutine.instruction.contains("{topic|the launch}")
          && sharedRoutine.suggestedAppNames == ["Mail"])
    let routineJSON = String(data: WispShareBundleCodec.encode(WispShareBundle(routines: [sharedRoutine]))!, encoding: .utf8)!
    check("no shortcut, pin, run time or typed values leave", !routineJSON.contains("shortcut") && !routineJSON.contains("Sam")
          && !routineJSON.contains("lastRun") && !routineJSON.contains("pinned"))

    let buddy = WispBuddy(
        id: UUID(), name: "Inbox", instruction: "Summarize my Gmail", colorIndex: 3, schedule: .daily(hour: 9, minute: 0),
        createdAt: Date(), runTaskIDs: [UUID()], nextScheduledRunAt: Date(),
        modelChoice: BuddyModelChoice(providerKind: .anthropic, claudeModel: nil),
        toolAccess: BuddyToolAccess(allowedGroupIDs: ["browser"]), specialty: .inbox
    )
    let sharedBuddy = WispShareBundleCodec.sharedBuddy(from: buddy)
    check("a buddy keeps its job, colour, specialty, model and tool limits",
          sharedBuddy.instruction == "Summarize my Gmail" && sharedBuddy.colorIndex == 3 && sharedBuddy.specialty == .inbox
          && sharedBuddy.modelChoice?.providerKind == .anthropic && sharedBuddy.toolAccess?.allowedGroupIDs == ["browser"])
    check("its schedule is only described", sharedBuddy.scheduleSummary?.contains("Every day") == true)
    let buddyJSON = String(data: WispShareBundleCodec.encode(WispShareBundle(buddies: [sharedBuddy]))!, encoding: .utf8)!
    check("no id, runs or schedule data leave", !buddyJSON.contains(buddy.id.uuidString) && !buddyJSON.contains("runTaskIDs") && !buddyJSON.contains("nextScheduledRunAt"))

    let roundTrip = WispShareBundleCodec.decode(WispShareBundleCodec.encode(WispShareBundle(routines: [sharedRoutine], buddies: [sharedBuddy]))!)
    check("a bundle round-trips", (try? roundTrip.get()) == WispShareBundle(routines: [sharedRoutine], buddies: [sharedBuddy]))

    section("Sharing: reading a file from someone else")
    do {
        func failure(_ data: Data) -> WispShareBundleCodec.DecodeFailure? {
            if case .failure(let failure) = WispShareBundleCodec.decode(data) { return failure }
            return nil
        }
        func bundleData(_ bundle: WispShareBundle) -> Data { WispShareBundleCodec.encode(bundle)! }
        check("garbage isn't a Wisp file", failure(Data("not json".utf8)) == .notAWispFile)
        check("other JSON isn't either", failure(Data(#"{"hello": 1}"#.utf8)) == .notAWispFile)
        check("a wrong format name is refused", failure(bundleData(WispShareBundle(format: "something-else", routines: [sharedRoutine]))) == .notAWispFile)
        check("a newer version asks for an update", failure(bundleData(WispShareBundle(version: 99, routines: [sharedRoutine]))) == .newerThanThisWisp)
        check("a huge file is refused", failure(Data(count: WispShareBundleCodec.maximumFileBytes + 1)) == .tooLarge)
        check("an empty bundle has nothing to import", failure(bundleData(WispShareBundle(routines: []))) == .nothingToImport)

        var messy = sharedRoutine
        messy.name = "  " + String(repeating: "n", count: 300) + "  "
        messy.instruction = String(repeating: "i", count: 9000)
        messy.symbolName = "not.a.real.symbol"
        var unnamed = sharedRoutine
        unnamed.name = "   "
        var noInstruction = sharedRoutine
        noInstruction.instruction = ""
        var wild = sharedBuddy
        wild.colorIndex = -7
        let cleaned = try? WispShareBundleCodec.decode(bundleData(WispShareBundle(routines: [messy, unnamed, noInstruction], buddies: [wild]))).get()
        check("a name and instruction are capped", cleaned?.routines?.first?.name.count == WispShareBundleCodec.maximumNameCharacters
              && cleaned?.routines?.first?.instruction.count == WispShareBundleCodec.maximumInstructionCharacters)
        check("an unknown icon becomes the default", cleaned?.routines?.first?.symbolName == "bolt")
        check("items missing a name or instruction are dropped", cleaned?.routines?.count == 1)
        check("a wild colour index lands in the palette", (0..<BuddyAppearance.paletteCount).contains(cleaned?.buddies?.first?.colorIndex ?? -1))

        let manyRoutines = (0..<80).map { index -> SharedRoutine in var copy = sharedRoutine; copy.name = "R\(index)"; return copy }
        let capped = try? WispShareBundleCodec.decode(bundleData(WispShareBundle(routines: manyRoutines))).get()
        check("a flood of items is capped", capped?.routines?.count == WispShareBundleCodec.maximumItemsPerKind)
    }

    section("Sharing: the review")
    do {
        let lines = WispShareReview.lines(for: WispShareBundle(
            routines: [SharedRoutine(name: "Fix", instruction: "Fix {clipboard} for {person}", symbolName: "bolt", suggestedAppBundleIdentifiers: [], suggestedAppNames: [])],
            buddies: [sharedBuddy, SharedBuddy(name: "Local", instruction: "x", colorIndex: 0, specialty: nil, modelChoice: nil, toolAccess: nil, scheduleSummary: nil)]
        ))
        let text = lines.joined(separator: "\n")
        check("a routine's blanks and clipboard use are called out", text.contains("asks for person") && text.contains("reads your clipboard"))
        check("a cloud buddy is flagged as leaving the Mac", text.contains("what it sees leaves your Mac"))
        check("a buddy with no tool limit says it can use every tool", text.contains("can use every tool Wisp has"))
        check("a limited buddy says how limited", text.contains("limited to 1 tool group"))
        check("the schedule is said to be off", text.contains("imported with its schedule off"))
    }

    section("Sharing: importing adds things inert")
    do {
        let routineStore = RoutineStore(routinesFileURL: sandbox.appendingPathComponent("routines.json"))
        let buddyStore = BuddyStore(buddiesFileURL: sandbox.appendingPathComponent("buddies.json"))
        var startedRuns = 0
        buddyStore.start { _, _ in startedRuns += 1; return UUID() }
        _ = buddyStore.createBuddy(instruction: "existing", schedule: .daily(hour: 8, minute: 0), name: "Inbox", runImmediately: false)
        let existingRoutineName = routineStore.routines[0].name
        let startingRoutineCount = routineStore.routines.count

        var clashing = sharedRoutine
        clashing.name = existingRoutineName
        let outcome = WispShareImporter.add(
            WispShareBundle(routines: [clashing], buddies: [sharedBuddy]),
            routineStore: routineStore, buddyStore: buddyStore
        )
        check("a routine is added", outcome.routineCount == 1 && routineStore.routines.count == startingRoutineCount + 1)
        let addedRoutine = routineStore.routines.last!
        check("a clashing name gets a number", addedRoutine.name == existingRoutineName + " 2")
        check("it takes no keyboard shortcut and isn't pinned", addedRoutine.shortcutDigit == nil && !addedRoutine.isPinnedInNotch)
        check("its setup came across", addedRoutine.instruction == sharedRoutine.instruction && addedRoutine.suggestedAppNames == ["Mail"])

        check("a buddy is added", outcome.importedBuddyIDs.count == 1)
        let addedBuddy = buddyStore.buddy(withID: outcome.importedBuddyIDs[0])!
        check("it doesn't clobber the existing name", addedBuddy.name == "Inbox 2")
        check("its job, colour, specialty, model and tools came across",
              addedBuddy.instruction == "Summarize my Gmail" && addedBuddy.colorIndex == 3 && addedBuddy.specialty == .inbox
              && addedBuddy.modelChoice?.providerKind == .anthropic && addedBuddy.toolAccess?.allowedGroupIDs == ["browser"])
        check("its schedule is off", addedBuddy.schedule == .once && addedBuddy.nextScheduledRunAt == nil)
        check("nothing ran", startedRuns == 0 && addedBuddy.runTaskIDs.isEmpty)
    }
}
