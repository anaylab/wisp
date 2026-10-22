//
//  DownloadConcierge.swift
//  leanring-buddy
//
//  The download concierge (Chrome extension phase 07). When Chrome finishes a
//  download, Wisp can offer to file it: give it a meaningful name, move it into
//  a folder by rule, and/or add it to the brain. Nothing moves without a yes:
//  the user answers a small notch card once per download (File / Just brain /
//  Ignore), or once per rule by marking it "always". An "always" filing is
//  reported in the notch with an Undo that moves the file back, kept for ten
//  minutes.
//
//  The extension only reports downloads (`download.completed`); it never
//  renames or moves anything. Wisp does that here, on disk, because Wisp owns
//  both the decision and the filesystem. The rules are pure and tested in
//  `DownloadFilingRules.swift`.
//
//  Off by default (Settings → Agent → Chrome Tabs). Quiet mode (a call, the
//  camera) holds the card back: the offer waits behind a badge in the notch's
//  flank instead of dropping down mid-call.
//

import AppKit
import Combine
import Foundation

/// An offer the user hasn't answered yet.
struct DownloadFilingOffer: Identifiable, Equatable {
    let id = UUID()
    let plan: DownloadFilingPlan
    /// The card's "Add to brain" chip.
    var addsToBrain: Bool
    /// The card's "Always for <rule>" chip, saved to the rule when the user files.
    var marksRuleAlways: Bool
}

/// One filing Wisp can undo: where the file was and where it went.
struct DownloadFilingRecord: Identifiable, Equatable {
    let id = UUID()
    let originalFilePath: String
    let filedFilePath: String
    let filedAt: Date
}

/// The line the notch shows after Wisp acted ("Filed Paper.pdf in ~/Documents/Papers").
struct DownloadConciergeReport: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// The filing an Undo would reverse, if there is one.
    let filingRecordID: UUID?
}

enum DownloadConciergeError: LocalizedError {
    case refused(DownloadFilingRefusal)
    case fileIsGone
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .refused(let refusal):
            return refusal.explanation
        case .fileIsGone:
            return "that download isn't where chrome left it any more."
        case .moveFailed(let reason):
            return "i couldn't move it: \(reason)"
        }
    }
}

@MainActor
final class DownloadConcierge: ObservableObject {
    static let shared = DownloadConcierge()

    /// How long an Undo stays possible (the brief's ten minutes, in memory only).
    static let undoWindowSeconds: TimeInterval = 10 * 60
    /// How long a report keeps the island showing. The Undo stays in the hover
    /// panel for the whole undo window; the island needn't stay up that long.
    static let reportStaysInNotchSeconds: TimeInterval = 45
    /// Offers beyond this are dropped oldest first: a burst of downloads
    /// shouldn't build an unbounded queue of cards.
    static let maximumPendingOffers = 5

    private static let isEnabledDefaultsKey = "chromeExtension.downloadConcierge.enabled"

    /// The Settings switch. Off by default: the concierge only works for
    /// someone who turned it on (and allowed downloads in Chrome).
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.isEnabledDefaultsKey)
            if !isEnabled { pendingOffers.removeAll() }
        }
    }

    /// Unanswered offers, oldest first. The card shows the first.
    @Published private(set) var pendingOffers: [DownloadFilingOffer] = []
    @Published private(set) var latestReport: DownloadConciergeReport?
    /// The report is new enough to keep the island showing it.
    @Published private(set) var isLatestReportFresh = false
    /// Bumped when the notch should drop the card on its own. Not bumped in
    /// quiet mode, so a call is never interrupted by a card.
    @Published private(set) var presentationSequenceNumber = 0
    /// Why rules in the file are being ignored (shown in Settings).
    @Published private(set) var ruleProblems: [String] = []

    /// Set by `start`; the island's success/error light for a filing.
    private var flashIsland: ((WispIslandState) -> Void)?
    private var filingRecords: [DownloadFilingRecord] = []
    private var downloadEventSubscription: AnyCancellable?
    private var reportFreshnessTask: Task<Void, Never>?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledDefaultsKey)
    }

    // MARK: - State the notch reads

    var currentOffer: DownloadFilingOffer? { pendingOffers.first }

    /// Anything for the notch to show on its own: an offer, or a fresh report.
    var hasNotchContent: Bool { !pendingOffers.isEmpty || isLatestReportFresh }

    /// The latest report's filing, while it can still be undone.
    var undoableRecordForLatestReport: DownloadFilingRecord? {
        guard let filingRecordID = latestReport?.filingRecordID else { return nil }
        return undoableRecord(withID: filingRecordID)
    }

    static var homeDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    }

    static var rulesFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wisp", isDirectory: true)
            .appendingPathComponent("download-rules.json")
    }

    // MARK: - Lifecycle

    /// Starts listening for finished downloads. Safe to call more than once.
    func start(flashIsland: @escaping (WispIslandState) -> Void) {
        self.flashIsland = flashIsland
        guard downloadEventSubscription == nil else { return }
        downloadEventSubscription = ChromeExtensionBridge.shared.extensionEventPublisher
            .filter { $0.eventName == "download.completed" }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completedDownloadEvent in
                MainActor.assumeIsolated {
                    self?.handleCompletedDownload(completedDownloadEvent)
                }
            }
    }

    // MARK: - A finished download

    private func handleCompletedDownload(_ completedDownloadEvent: ChromeExtensionEvent) {
        guard isEnabled else { return }
        guard let downloadItem = completedDownloadEvent.decodePayload(as: ChromeDownloadItem.self) else {
            print("⬇️ Download concierge: couldn't read a download.completed payload")
            return
        }
        guard downloadItem.exists != false, downloadItem.truncated != true else { return }
        let downloadedFile = DownloadedFile(downloadItem: downloadItem)
        guard FileManager.default.fileExists(atPath: downloadedFile.filePath) else { return }

        let planResult = DownloadFilingPlanner.plan(
            for: downloadedFile,
            rules: loadRules(),
            homeDirectoryPath: Self.homeDirectoryPath,
            filedAt: Date(),
            canBrainRead: Self.canBrainRead(fileExtension:)
        )
        let plan: DownloadFilingPlan
        switch planResult {
        case .failure(let refusal):
            // A dangerous download gets no card at all: offering to tidy it
            // would read as Wisp vouching for it.
            print("⬇️ Download concierge: leaving \(downloadedFile.fileName) alone (\(refusal))")
            return
        case .success(let successfulPlan):
            plan = successfulPlan
        }
        guard plan.changesSomething || plan.canAddToBrain else { return }

        pendingOffers.removeAll { $0.plan.downloadedFile.downloadID == downloadedFile.downloadID }

        if plan.appliesWithoutAsking {
            let offer = DownloadFilingOffer(plan: plan, addsToBrain: plan.addsToBrainByDefault, marksRuleAlways: false)
            carryOut(offer, filesTheDownload: plan.changesSomething)
            presentInNotchUnlessQuiet()
            return
        }

        pendingOffers.append(DownloadFilingOffer(plan: plan, addsToBrain: plan.addsToBrainByDefault, marksRuleAlways: false))
        if pendingOffers.count > Self.maximumPendingOffers {
            pendingOffers.removeFirst(pendingOffers.count - Self.maximumPendingOffers)
        }
        presentInNotchUnlessQuiet()
    }

    private func presentInNotchUnlessQuiet() {
        guard !QuietModeMonitor.shared.isQuiet else { return }
        presentationSequenceNumber += 1
    }

    // MARK: - The card's buttons

    func toggleAddsToBrainOnCurrentOffer() {
        guard !pendingOffers.isEmpty, pendingOffers[0].plan.canAddToBrain else { return }
        pendingOffers[0].addsToBrain.toggle()
    }

    func toggleMarksRuleAlwaysOnCurrentOffer() {
        guard !pendingOffers.isEmpty, pendingOffers[0].plan.matchedRule != nil else { return }
        pendingOffers[0].marksRuleAlways.toggle()
    }

    /// File: rename/move as offered, plus the brain if its chip is on.
    func fileCurrentOffer() {
        guard let offer = pendingOffers.first else { return }
        pendingOffers.removeFirst()
        if offer.marksRuleAlways, let matchedRule = offer.plan.matchedRule {
            saveAlways(onRuleWithID: matchedRule.id)
        }
        carryOut(offer, filesTheDownload: offer.plan.changesSomething)
    }

    /// Just brain: the file stays where it is and goes into the brain.
    func addCurrentOfferToBrainOnly() {
        guard let offer = pendingOffers.first, offer.plan.canAddToBrain else { return }
        pendingOffers.removeFirst()
        var brainOnlyOffer = offer
        brainOnlyOffer.addsToBrain = true
        carryOut(brainOnlyOffer, filesTheDownload: false)
    }

    func ignoreCurrentOffer() {
        guard !pendingOffers.isEmpty else { return }
        pendingOffers.removeFirst()
    }

    func dismissLatestReport() {
        reportFreshnessTask?.cancel()
        isLatestReportFresh = false
        latestReport = nil
    }

    /// Moves a filed download back where Chrome put it (or beside it, " 2",
    /// if something new took the name meanwhile).
    func undoFiling(withRecordID filingRecordID: UUID) {
        guard let filingRecord = undoableRecord(withID: filingRecordID) else { return }
        filingRecords.removeAll { $0.id == filingRecordID }
        let filedFileName = (filingRecord.filedFilePath as NSString).lastPathComponent
        do {
            let restoredPath = try moveFile(
                atPath: filingRecord.filedFilePath,
                intoFolderPath: (filingRecord.originalFilePath as NSString).deletingLastPathComponent,
                baseName: ((filingRecord.originalFilePath as NSString).lastPathComponent as NSString).deletingPathExtension,
                fileExtension: (filingRecord.originalFilePath as NSString).pathExtension
            )
            let restoredFolder = DownloadFilingSafety.abbreviatedPath((restoredPath as NSString).deletingLastPathComponent, homeDirectoryPath: Self.homeDirectoryPath)
            showReport(DownloadConciergeReport(text: "Put \(filedFileName) back in \(restoredFolder)", filingRecordID: nil))
            flashIsland?(.success)
        } catch {
            showReport(DownloadConciergeReport(text: "Couldn't undo: \(error.localizedDescription)", filingRecordID: nil))
            flashIsland?(.error)
        }
    }

    // MARK: - Doing it

    private func carryOut(_ offer: DownloadFilingOffer, filesTheDownload: Bool) {
        let plan = offer.plan
        var filedFilePath = plan.downloadedFile.filePath
        var filingRecordID: UUID?
        var reportParts: [String] = []

        if filesTheDownload {
            do {
                let filingRecord = try fileDownload(plan.downloadedFile, intoFolderPath: plan.destinationFolderPath, baseName: plan.suggestedBaseName)
                filedFilePath = filingRecord.filedFilePath
                filingRecordID = filingRecord.id
                let filedFolder = DownloadFilingSafety.abbreviatedPath((filedFilePath as NSString).deletingLastPathComponent, homeDirectoryPath: Self.homeDirectoryPath)
                reportParts.append("Filed \((filedFilePath as NSString).lastPathComponent) in \(filedFolder)")
            } catch {
                showReport(DownloadConciergeReport(text: "Couldn't file \(plan.downloadedFile.fileName): \(error.localizedDescription)", filingRecordID: nil))
                flashIsland?(.error)
                return
            }
        }

        if offer.addsToBrain && plan.canAddToBrain {
            BrainIngestQueue.shared.enqueue(fileURL: URL(fileURLWithPath: filedFilePath))
            reportParts.append(reportParts.isEmpty
                ? "Adding \((filedFilePath as NSString).lastPathComponent) to your brain"
                : "adding it to your brain")
        }

        guard !reportParts.isEmpty else { return }
        showReport(DownloadConciergeReport(text: reportParts.joined(separator: ", "), filingRecordID: filingRecordID))
        flashIsland?(.success)
    }

    /// Renames/moves a download, refusing anything the rules refuse, and
    /// remembers it for Undo. Also what the `chrome_file_download` tool runs,
    /// after its confirmation card.
    @discardableResult
    func fileDownload(_ downloadedFile: DownloadedFile, intoFolderPath destinationFolderPath: String, baseName: String) throws -> DownloadFilingRecord {
        let homeDirectoryPath = Self.homeDirectoryPath
        if let sourceRefusal = DownloadFilingSafety.sourceRefusal(for: downloadedFile, homeDirectoryPath: homeDirectoryPath) {
            throw DownloadConciergeError.refused(sourceRefusal)
        }
        guard FileManager.default.fileExists(atPath: downloadedFile.filePath) else { throw DownloadConciergeError.fileIsGone }
        let filedFilePath = try moveFile(
            atPath: downloadedFile.filePath,
            intoFolderPath: destinationFolderPath,
            baseName: baseName,
            fileExtension: downloadedFile.fileExtension
        )
        let filingRecord = DownloadFilingRecord(originalFilePath: downloadedFile.filePath, filedFilePath: filedFilePath, filedAt: Date())
        filingRecords.append(filingRecord)
        pruneExpiredFilingRecords()
        return filingRecord
    }

    /// The final path a filing would use right now: the free name in the
    /// folder (" 2", " 3"…), or the file's own path when nothing changes. For
    /// the confirmation card, so it names the real destination.
    func destinationPath(forFileAtPath sourceFilePath: String, intoFolderPath destinationFolderPath: String, baseName: String, fileExtension: String) -> String? {
        let resolvedFolderPath = URL(fileURLWithPath: destinationFolderPath).resolvingSymlinksInPath().path
        let sourceFolderPath = URL(fileURLWithPath: (sourceFilePath as NSString).deletingLastPathComponent).resolvingSymlinksInPath().path
        let sourceFileName = (sourceFilePath as NSString).lastPathComponent
        guard let freeFileName = DownloadCollisionNaming.availableFileName(baseName: baseName, fileExtension: fileExtension, isNameTaken: { candidateFileName in
            // The file being renamed doesn't block its own name (or a change of case).
            if resolvedFolderPath == sourceFolderPath && candidateFileName.lowercased() == sourceFileName.lowercased() { return false }
            return FileManager.default.fileExists(atPath: (resolvedFolderPath as NSString).appendingPathComponent(candidateFileName))
        }) else { return nil }
        return (resolvedFolderPath as NSString).appendingPathComponent(freeFileName)
    }

    /// The one place a file moves. The folder is checked after symlinks are
    /// resolved (a link in Documents pointing at /etc is still /etc), created
    /// if missing, and `moveItem` never overwrites, so a name taken in the
    /// meantime fails rather than replacing someone's file.
    private func moveFile(atPath sourceFilePath: String, intoFolderPath destinationFolderPath: String, baseName: String, fileExtension: String) throws -> String {
        let homeDirectoryPath = Self.homeDirectoryPath
        let resolvedFolderPath = URL(fileURLWithPath: destinationFolderPath).resolvingSymlinksInPath().path
        if let destinationRefusal = DownloadFilingSafety.destinationRefusal(destinationFolderPath: resolvedFolderPath, homeDirectoryPath: homeDirectoryPath) {
            throw DownloadConciergeError.refused(destinationRefusal)
        }
        guard FileManager.default.fileExists(atPath: sourceFilePath) else { throw DownloadConciergeError.fileIsGone }
        do {
            try FileManager.default.createDirectory(atPath: resolvedFolderPath, withIntermediateDirectories: true)
        } catch {
            throw DownloadConciergeError.moveFailed(error.localizedDescription)
        }
        guard let destinationFilePath = destinationPath(
            forFileAtPath: sourceFilePath,
            intoFolderPath: resolvedFolderPath,
            baseName: baseName,
            fileExtension: fileExtension
        ) else {
            throw DownloadConciergeError.refused(.noFreeName)
        }
        // Same folder, same name: nothing to move.
        guard destinationFilePath != URL(fileURLWithPath: sourceFilePath).resolvingSymlinksInPath().path else { return sourceFilePath }
        do {
            try FileManager.default.moveItem(atPath: sourceFilePath, toPath: destinationFilePath)
        } catch {
            throw DownloadConciergeError.moveFailed(error.localizedDescription)
        }
        return destinationFilePath
    }

    // MARK: - Rules

    /// Read fresh for each download: the file is small and edited by hand.
    func loadRules() -> [DownloadFilingRule] {
        guard let rulesFileData = try? Data(contentsOf: Self.rulesFileURL) else {
            ruleProblems = []
            return []
        }
        let loadResult = DownloadFilingRuleFile.load(from: rulesFileData, homeDirectoryPath: Self.homeDirectoryPath)
        if loadResult.problems != ruleProblems {
            ruleProblems = loadResult.problems
            for problem in loadResult.problems { print("⬇️ Download rules: \(problem)") }
        }
        return loadResult.usableRules
    }

    private func saveAlways(onRuleWithID ruleID: String) {
        guard let rulesFileData = try? Data(contentsOf: Self.rulesFileURL),
              let updatedRulesFileData = DownloadFilingRuleFile.settingAlways(onRuleWithID: ruleID, inFileData: rulesFileData) else {
            print("⬇️ Download rules: couldn't mark \(ruleID) as always")
            return
        }
        do {
            try updatedRulesFileData.write(to: Self.rulesFileURL, options: .atomic)
        } catch {
            print("⬇️ Download rules: couldn't save: \(error.localizedDescription)")
        }
    }

    /// Opens the rules file in the user's editor, writing the example first
    /// when there isn't one. The example only offers (it isn't "always").
    func openRulesFile() {
        let rulesFileURL = Self.rulesFileURL
        if !FileManager.default.fileExists(atPath: rulesFileURL.path) {
            do {
                try FileManager.default.createDirectory(at: rulesFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DownloadFilingRuleFile.starterFile.encoded().write(to: rulesFileURL, options: .atomic)
            } catch {
                print("⬇️ Download rules: couldn't write the starter file: \(error.localizedDescription)")
                return
            }
        }
        NSWorkspace.shared.open(rulesFileURL)
    }

    // MARK: - Helpers

    private static func canBrainRead(fileExtension: String) -> Bool {
        BrainPreferences.shared.isBrainEnabled && BrainIngestFileRules.isSupported(fileExtension: fileExtension)
    }

    private func showReport(_ report: DownloadConciergeReport) {
        latestReport = report
        isLatestReportFresh = true
        reportFreshnessTask?.cancel()
        reportFreshnessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reportStaysInNotchSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.latestReport?.id == report.id else { return }
            self.isLatestReportFresh = false
            // After the undo window there's nothing left to offer, so the
            // report goes too.
            try? await Task.sleep(nanoseconds: UInt64((Self.undoWindowSeconds - Self.reportStaysInNotchSeconds) * 1_000_000_000))
            guard !Task.isCancelled, self.latestReport?.id == report.id else { return }
            self.latestReport = nil
            self.pruneExpiredFilingRecords()
        }
    }

    private func undoableRecord(withID filingRecordID: UUID) -> DownloadFilingRecord? {
        filingRecords.first { filingRecord in
            filingRecord.id == filingRecordID && Date().timeIntervalSince(filingRecord.filedAt) < Self.undoWindowSeconds
        }
    }

    private func pruneExpiredFilingRecords() {
        filingRecords.removeAll { Date().timeIntervalSince($0.filedAt) >= Self.undoWindowSeconds }
    }
}
