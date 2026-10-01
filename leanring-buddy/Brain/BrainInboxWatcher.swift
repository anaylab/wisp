//
//  BrainInboxWatcher.swift
//  leanring-buddy
//
//  Ingests files dropped into `~/.wisp/brain/raw/inbox/`, while
//  `BrainPreferences.isInboxWatchingEnabled` (and the brain itself) is on.
//
//  A 5-second poll rather than an FSEvents stream: a file only counts once
//  its size and modification date are the same on two polls in a row
//  (`BrainInboxStabilityTracker`), so a browser download or a Finder copy is
//  never read half-written — and that check needs polls anyway. Hidden files,
//  `.DS_Store`, Office lock files and partial downloads (`.crdownload`,
//  `.download`, …) are ignored (`BrainIngestFileRules`). Files ingest can't
//  read are left where they are and logged once.
//
//  The queue moves each file out of the inbox into `raw/ingested/` when it
//  starts on it, so the inbox empties as the brain reads.
//

import Combine
import Foundation

@MainActor
final class BrainInboxWatcher: ObservableObject {
    static let shared = BrainInboxWatcher()

    static let pollIntervalSeconds: TimeInterval = 5

    /// True while the inbox is being polled.
    @Published private(set) var isWatching = false

    private var hasStarted = false
    private var pollTimer: Timer?
    private var stabilityTracker = BrainInboxStabilityTracker()
    private var preferenceObserver: AnyCancellable?
    /// Unsupported files already logged, so each is mentioned once.
    private var reportedUnsupportedPaths = Set<String>()

    private init() {}

    /// Follows the inbox-watching and brain switches; safe to call repeatedly.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let preferences = BrainPreferences.shared
        preferenceObserver = preferences.$isInboxWatchingEnabled
            .combineLatest(preferences.$isBrainEnabled)
            .map { isInboxWatchingEnabled, isBrainEnabled in isInboxWatchingEnabled && isBrainEnabled }
            .removeDuplicates()
            .sink { [weak self] shouldWatch in
                self?.setWatching(shouldWatch)
            }
    }

    private func setWatching(_ shouldWatch: Bool) {
        guard shouldWatch != isWatching else { return }
        isWatching = shouldWatch
        if shouldWatch {
            BrainStore.shared.ensureVaultExists()
            let timer = Timer(timeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollInbox() }
            }
            // Precision doesn't matter; let the system batch the wake-ups.
            timer.tolerance = 1.5
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
            pollInbox()
            print("🧠 Brain inbox: watching \(BrainStore.shared.inboxURL.path)")
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            // Start fresh next time: a file must again look stable twice.
            stabilityTracker = BrainInboxStabilityTracker()
        }
    }

    private func pollInbox() {
        guard isWatching else { return }
        let inboxURL = BrainStore.shared.inboxURL
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else { return }

        var observationsByPath: [String: BrainInboxFileObservation] = [:]
        var fileURLsByPath: [String: URL] = [:]
        for fileURL in fileURLs {
            let fileName = fileURL.lastPathComponent
            switch BrainIngestFileRules.inboxFileDecision(forFileName: fileName) {
            case .ignore:
                continue
            case .unsupported:
                if reportedUnsupportedPaths.insert(fileURL.path).inserted {
                    print("🧠 Brain inbox: can't read \(fileName) — left in the inbox")
                }
                continue
            case .candidate:
                break
            }
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  resourceValues.isRegularFile == true else { continue }
            observationsByPath[fileURL.path] = BrainInboxFileObservation(
                byteCount: Int64(resourceValues.fileSize ?? 0),
                modificationDate: resourceValues.contentModificationDate ?? .distantPast
            )
            fileURLsByPath[fileURL.path] = fileURL
        }
        reportedUnsupportedPaths.formIntersection(Set(fileURLs.map(\.path)))

        for readyPath in stabilityTracker.pathsReadyToIngest(currentObservationsByPath: observationsByPath) {
            guard let readyFileURL = fileURLsByPath[readyPath] else { continue }
            print("🧠 Brain inbox: ingesting \(readyFileURL.lastPathComponent)")
            BrainIngestQueue.shared.enqueue(fileURL: readyFileURL, origin: .ingest)
        }
    }
}
