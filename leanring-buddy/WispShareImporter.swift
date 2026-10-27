//
//  WispShareImporter.swift
//  leanring-buddy
//
//  The side-effecting half of sharing (`WispShareBundle.swift` is the pure
//  half): adding an imported bundle's items, and the save / open panels and the
//  review dialog around it.
//
//  Importing never runs anything. A routine arrives without a keyboard shortcut
//  or a pin, so it can't take over the user's. A buddy arrives with its schedule
//  off and doesn't run. The review dialog says what each could do first —
//  including a model that sends data off this Mac and tools it may use — and
//  nothing is added until the user chooses Import.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum WispShareImporter {
    struct Outcome: Equatable {
        var routineCount = 0
        var importedBuddyIDs: [UUID] = []
    }

    /// Adds the bundle's items. Names that clash get a number.
    @discardableResult
    static func add(
        _ bundle: WispShareBundle,
        routineStore: RoutineStore = .shared,
        buddyStore: BuddyStore = .shared
    ) -> Outcome {
        var outcome = Outcome()

        for sharedRoutine in bundle.routines ?? [] {
            let name = WispShareBundleCodec.uniqueName(sharedRoutine.name, avoiding: routineStore.routines.map(\.name))
            routineStore.addRoutine(WispRoutine(
                name: name,
                instruction: sharedRoutine.instruction,
                symbolName: sharedRoutine.symbolName,
                shortcutDigit: nil,
                suggestedAppBundleIdentifiers: sharedRoutine.suggestedAppBundleIdentifiers,
                suggestedAppNames: sharedRoutine.suggestedAppNames,
                isPinnedInNotch: false
            ))
            outcome.routineCount += 1
        }

        for sharedBuddy in bundle.buddies ?? [] {
            // `createBuddy` runs a one-off buddy straight away, so it is made with
            // a repeating placeholder (which waits for its time and isn't run
            // immediately) and then set to run only when asked.
            let importedBuddy = buddyStore.createBuddy(
                instruction: sharedBuddy.instruction,
                schedule: .daily(hour: 9, minute: 0),
                modelChoice: sharedBuddy.modelChoice,
                toolAccess: sharedBuddy.toolAccess,
                specialty: sharedBuddy.specialty,
                name: WispShareBundleCodec.uniqueName(sharedBuddy.name, avoiding: buddyStore.buddies.map(\.name)),
                colorIndex: sharedBuddy.colorIndex,
                runImmediately: false
            )
            buddyStore.updateSchedule(ofBuddyWithID: importedBuddy.id, to: .once)
            outcome.importedBuddyIDs.append(importedBuddy.id)
        }
        return outcome
    }

    // MARK: - Panels

    private static var shareFileType: UTType {
        UTType(filenameExtension: WispShareBundleCodec.fileExtension, conformingTo: .json) ?? .json
    }

    static func exportRoutine(_ routine: WispRoutine) {
        export(WispShareBundle(routines: [WispShareBundleCodec.sharedRoutine(from: routine)]), suggestedName: routine.name)
    }

    static func exportBuddy(_ buddy: WispBuddy) {
        export(WispShareBundle(buddies: [WispShareBundleCodec.sharedBuddy(from: buddy)]), suggestedName: buddy.name)
    }

    private static func export(_ bundle: WispShareBundle, suggestedName: String) {
        guard let bundleData = WispShareBundleCodec.encode(bundle) else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [shareFileType]
        savePanel.nameFieldStringValue = suggestedName.replacingOccurrences(of: "/", with: "-") + "." + WispShareBundleCodec.fileExtension
        savePanel.message = "Shares the setup only — no conversations, notes, files or keys."
        NSApp.activate(ignoringOtherApps: true)
        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else { return }
        do {
            try bundleData.write(to: destinationURL, options: .atomic)
        } catch {
            showMessage("Couldn't save the file", detail: error.localizedDescription)
        }
    }

    /// Lets the user pick a share file, shows what it would add, and adds it on
    /// their say-so. Returns what was added, or nil if nothing was.
    @discardableResult
    static func importFromFile() -> Outcome? {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [shareFileType, .json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.message = "Choose a Wisp share file"
        NSApp.activate(ignoringOtherApps: true)
        guard openPanel.runModal() == .OK, let fileURL = openPanel.url else { return nil }

        // Size is checked before reading so a huge file is never loaded.
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= WispShareBundleCodec.maximumFileBytes, let fileData = try? Data(contentsOf: fileURL) else {
            showMessage("Couldn't import", detail: WispShareBundleCodec.DecodeFailure.tooLarge.message)
            return nil
        }

        switch WispShareBundleCodec.decode(fileData) {
        case .failure(let failure):
            showMessage("Couldn't import", detail: failure.message)
            return nil
        case .success(let bundle):
            guard confirmImport(of: bundle) else { return nil }
            return add(bundle)
        }
    }

    private static func confirmImport(of bundle: WispShareBundle) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Import \(bundle.itemCount) item\(bundle.itemCount == 1 ? "" : "s")?"
        alert.informativeText = "From a file someone made. Nothing runs until you run it, and buddies come in with their schedule off."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        let reviewTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        reviewTextView.isEditable = false
        reviewTextView.font = .systemFont(ofSize: 12)
        reviewTextView.string = WispShareReview.lines(for: bundle).joined(separator: "\n")
        reviewTextView.textContainerInset = NSSize(width: 6, height: 6)
        let scrollView = NSScrollView(frame: reviewTextView.frame)
        scrollView.documentView = reviewTextView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        alert.accessoryView = scrollView

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
