//
//  RoutineStoreTests.swift
//  leanring-buddyTests
//
//  Proves routines seed on first launch and persist, that the notch suggests
//  routines for the frontmost app before pinned ones (capped), and that a
//  shortcut digit belongs to one routine at a time. Every store here uses its
//  own temporary file, never the user's routines.json.
//

import XCTest
@testable import Wisp

@MainActor
final class RoutineStoreTests: XCTestCase {

    private var temporaryDirectoryURL: URL!

    override func setUp() async throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutineStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }

    private var routinesFileURL: URL {
        temporaryDirectoryURL.appendingPathComponent("routines.json")
    }

    /// A store that starts empty, by deleting the seeded starters.
    private func makeEmptyStore() -> RoutineStore {
        let routineStore = RoutineStore(routinesFileURL: routinesFileURL)
        for routine in routineStore.routines {
            routineStore.deleteRoutine(withID: routine.id)
        }
        return routineStore
    }

    func testFirstLaunchSeedsStartersAndWritesThem() {
        let routineStore = RoutineStore(routinesFileURL: routinesFileURL)

        XCTAssertEqual(routineStore.routines.map(\.name), RoutineStore.starterRoutines.map(\.name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: routinesFileURL.path),
                      "starters are written so deleting one sticks")
    }

    func testEditsPersistAcrossStores() {
        let firstStore = makeEmptyStore()
        let addedRoutine = firstStore.addRoutine(WispRoutine(name: "Tidy Downloads", instruction: "sort it"))

        let reloadedStore = RoutineStore(routinesFileURL: routinesFileURL)

        XCTAssertEqual(reloadedStore.routines.map(\.id), [addedRoutine.id],
                       "an emptied list stays empty and is not re-seeded")
        XCTAssertEqual(reloadedStore.routines.first?.instruction, "sort it")
    }

    func testUnreadableFileIsLeftAloneAndNotReseeded() throws {
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        try Data("{ not routines".utf8).write(to: routinesFileURL)

        let routineStore = RoutineStore(routinesFileURL: routinesFileURL)

        XCTAssertTrue(routineStore.routines.isEmpty)
        XCTAssertEqual(try String(contentsOf: routinesFileURL, encoding: .utf8), "{ not routines",
                       "the user's broken file is not overwritten")
    }

    func testNotchSuggestsAppRoutinesBeforePinnedAndCaps() {
        let routineStore = makeEmptyStore()
        let pinnedRoutine = routineStore.addRoutine(
            WispRoutine(name: "Pinned", instruction: "p", isPinnedInNotch: true)
        )
        var safariRoutines: [WispRoutine] = []
        for index in 1...4 {
            safariRoutines.append(routineStore.addRoutine(WispRoutine(
                name: "Safari \(index)", instruction: "s",
                suggestedAppBundleIdentifiers: ["com.apple.Safari"], suggestedAppNames: ["Safari"]
            )))
        }
        routineStore.addRoutine(WispRoutine(name: "Unrelated", instruction: "u"))

        let safariSuggestions = routineStore.notchSuggestions(forAppBundleIdentifier: "com.apple.Safari")
        XCTAssertEqual(safariSuggestions.map(\.id), safariRoutines.map(\.id),
                       "app routines first, and the cap pushes the pinned one out")
        XCTAssertEqual(safariSuggestions.count, RoutineStore.maximumNotchSuggestions)
        XCTAssertTrue(routineStore.hasAppSpecificSuggestions(forAppBundleIdentifier: "com.apple.Safari"))

        let finderSuggestions = routineStore.notchSuggestions(forAppBundleIdentifier: "com.apple.finder")
        XCTAssertEqual(finderSuggestions.map(\.id), [pinnedRoutine.id], "other apps get only pinned routines")
        XCTAssertFalse(routineStore.hasAppSpecificSuggestions(forAppBundleIdentifier: "com.apple.finder"))

        XCTAssertEqual(routineStore.notchSuggestions(forAppBundleIdentifier: nil).map(\.id), [pinnedRoutine.id])
    }

    func testShortcutDigitMovesToTheLatestRoutine() {
        let routineStore = makeEmptyStore()
        let firstRoutine = routineStore.addRoutine(WispRoutine(name: "First", instruction: "f", shortcutDigit: 3))
        let secondRoutine = routineStore.addRoutine(WispRoutine(name: "Second", instruction: "s", shortcutDigit: 3))

        XCTAssertNil(secondRoutine.shortcutDigit, "adding never steals a digit already in use")
        XCTAssertEqual(routineStore.routine(forShortcutDigit: 3)?.id, firstRoutine.id)

        var editedSecondRoutine = secondRoutine
        editedSecondRoutine.shortcutDigit = 3
        routineStore.updateRoutine(editedSecondRoutine)

        XCTAssertEqual(routineStore.routine(forShortcutDigit: 3)?.id, secondRoutine.id, "an explicit edit takes it")
        XCTAssertNil(routineStore.routine(withID: firstRoutine.id)?.shortcutDigit, "and the old owner loses it")
    }

    func testMarkingARunRecordsTheTime() {
        let routineStore = makeEmptyStore()
        let routine = routineStore.addRoutine(WispRoutine(name: "Run me", instruction: "r"))
        XCTAssertNil(routineStore.routine(withID: routine.id)?.lastRunAt)

        routineStore.markRoutineRun(withID: routine.id)

        XCTAssertNotNil(routineStore.routine(withID: routine.id)?.lastRunAt)
    }
}
