//
//  BrainActivityRecorder.swift
//  leanring-buddy
//
//  The opt-in screen/work-activity feed (default OFF —
//  `BrainPreferences.isActivityRecordingEnabled`). While on, once a minute it
//  notes what the user is working in — frontmost app, focused window title,
//  and for Chrome/Safari the front tab's cleaned URL — merges the samples into
//  spans in `raw/activity/YYYY-MM-DD.{md,json}`, and once a day hands a
//  compact summary of the day to `BrainKnowledgeExtractor` so project and
//  topic pages grow "## Timeline" lines ("- 2026-09-29: ~2h on the Atlas spec
//  in Figma").
//
//  When a sample is skipped:
//  - the feed or the brain is switched off (applies live);
//  - the user isn't at the Mac (no input for 2 minutes);
//  - quiet mode says they're on a call or their camera is on;
//  - the app or site is excluded (see BrainActivityExclusions.swift), or a
//    Chrome Incognito window is in front (see BrainActivitySampler.swift).
//
//  Privacy: nothing leaves the machine. Screenshots are never taken or stored
//  by the feed. The daily digest always runs on the local Ollama model, even
//  when a cloud provider is selected for conversations, because this is a
//  record of things the user never asked Wisp about. The digest sees only
//  rounded per-item durations, never raw spans, URLs or screen text, and its
//  edits are `.external` trust (window titles are third-party text), so they
//  can only append and can never touch the user's own page.
//

import Combine
import CoreGraphics
import Foundation

/// Digest bookkeeping, persisted in `~/.wisp/brain/.brain/activity-state.json`.
nonisolated struct BrainActivityRecorderState: Codable, Equatable, Sendable {
    /// Days already digested (kept for the retention window).
    var digestedDayKeys: [String] = []
    var lastDigestDate: Date?
    /// Last failed digest attempt (Ollama not running…), to retry hourly
    /// rather than every minute.
    var lastFailedDigestAttemptDate: Date?
}

@MainActor
final class BrainActivityRecorder: ObservableObject {
    static let shared = BrainActivityRecorder()

    /// One sample a minute: fine enough for "~2h on X", cheap enough to be
    /// invisible (one AX call and, in a browser, one AppleScript).
    static let sampleIntervalSeconds: TimeInterval = 60
    /// No keyboard/mouse input for this long means the user isn't at the Mac.
    static let userPresenceThresholdSeconds: TimeInterval = 120
    /// Activity files older than this are deleted.
    static let retentionDays = 30
    /// After a failed digest, wait this long before trying again.
    static let failedDigestRetryIntervalSeconds: TimeInterval = 60 * 60

    /// True while samples are being taken (enabled, not paused, user present).
    @Published private(set) var isRecording = false
    /// Samples recorded today.
    @Published private(set) var todaySampleCount = 0
    @Published private(set) var lastDigestDate: Date?
    /// Today's time per work item / app / site, for the Brain page.
    @Published private(set) var todaySummary: [BrainActivitySummaryRow] = []
    /// Today's full summary (total time + every row), for detail views.
    @Published private(set) var todayDaySummary: BrainActivityDaySummary?
    @Published private(set) var isDigesting = false
    /// One line about the last digest ("updated 2 pages from 2026-09-29").
    @Published private(set) var lastDigestSummary: String?

    /// Supplies already-recognised on-screen text for samples when
    /// `isActivityTextCaptureEnabled` is on. The feed never captures the
    /// screen itself; this is meant to return the OCR text of the most recent
    /// capture only if it is fresh (see the report on wiring it to
    /// `ScreenTextRecognizer`). Nil: no screen text is recorded.
    var recentScreenTextProvider: (@MainActor () -> String?)?

    private let preferences = BrainPreferences.shared
    private var preferenceObservation: AnyCancellable?
    private var sampleTimer: Timer?
    private var isFeedSwitchedOn = false
    private var isTakingSample = false
    private var todayLog: BrainActivityDayLog?
    private var lastRetentionPruneDayKey: String?
    private var recorderState = BrainActivityRecorderState()

    private var logFiles: BrainActivityLogFiles {
        BrainActivityLogFiles(activityFolderURL: BrainStore.shared.rawURL.appendingPathComponent("activity", isDirectory: true))
    }

    private var stateFileURL: URL {
        BrainStore.shared.vaultURL
            .appendingPathComponent(".brain", isDirectory: true)
            .appendingPathComponent("activity-state.json")
    }

    private init() {}

    // MARK: - Public API

    /// Starts sampling if `BrainPreferences.isActivityRecordingEnabled`; also
    /// observes the preference so toggling applies live.
    func start() {
        guard preferenceObservation == nil else { return }
        if recentScreenTextProvider == nil {
            // Only text Wisp already recognised for a turn, never a capture of
            // its own; stale after 90s so it describes the sampled moment.
            recentScreenTextProvider = {
                ScreenTextRecognizer.shared.mostRecentRecognizedPlainText(maximumAgeSeconds: 90)
            }
        }
        loadRecorderState()
        // Retention applies even while the feed is off: old days still expire.
        pruneExpiredActivityIfNeeded(now: Date())
        // `@Published` emits on willSet, so the sink uses the values it is
        // handed rather than reading the properties back.
        preferenceObservation = preferences.$isActivityRecordingEnabled
            .combineLatest(preferences.$isBrainEnabled)
            .map { isActivityRecordingEnabled, isBrainEnabled in isActivityRecordingEnabled && isBrainEnabled }
            .removeDuplicates()
            .sink { [weak self] isFeedEnabled in
                self?.applyFeedSwitch(isOn: isFeedEnabled)
            }
    }

    /// Turns today's activity log into page edits now.
    func digestToday() {
        guard preferences.isBrainEnabled, !isDigesting else { return }
        let todayDayKey = BrainActivityDayKey.dayKey(for: Date())
        Task { await digest(dayKeys: [todayDayKey]) }
    }

    /// Deletes the recorded activity logs (raw/activity/). Pages already
    /// written by past digests stay (they're undoable from the change log).
    func deleteRecordedActivity() {
        logFiles.deleteAllFiles()
        let todayDayKey = BrainActivityDayKey.dayKey(for: Date())
        todayLog = BrainActivityDayLog(dayKey: todayDayKey, spans: [])
        refreshTodayPublishedState()
        print("🧠 Brain activity: deleted all recorded activity")
    }

    /// Asks macOS for Automation access to running browsers so sites can be
    /// recorded. Only from a deliberate user action (it shows a dialog).
    func requestBrowserAccess() {
        Task { await BrainActivitySampler.requestBrowserAutomationAccess() }
    }

    // MARK: - Switching on and off

    private func applyFeedSwitch(isOn: Bool) {
        isFeedSwitchedOn = isOn
        guard isOn else {
            sampleTimer?.invalidate()
            sampleTimer = nil
            isRecording = false
            return
        }
        loadTodayLog(now: Date())
        pruneExpiredActivityIfNeeded(now: Date())
        guard sampleTimer == nil else { return }
        let timer = Timer(timeInterval: Self.sampleIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleTimerFired()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
        // First sample right away, so switching on shows something at once.
        sampleTimerFired()
    }

    private func sampleTimerFired() {
        guard isFeedSwitchedOn else { return }
        let now = Date()
        let todayDayKey = BrainActivityDayKey.dayKey(for: now)
        if todayLog?.dayKey != todayDayKey {
            loadTodayLog(now: now)
        }
        pruneExpiredActivityIfNeeded(now: now)
        runDueDigestsIfNeeded(now: now)

        let secondsSinceLastUserInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            // kCGAnyInputEventType: any keyboard, mouse or trackpad event.
            eventType: CGEventType(rawValue: ~0)!
        )
        let isUserPresent = secondsSinceLastUserInput < Self.userPresenceThresholdSeconds
        let isOnCall = QuietModeMonitor.shared.isQuiet
        guard isUserPresent, !isOnCall else {
            isRecording = false
            return
        }
        guard !isTakingSample else { return }
        isTakingSample = true
        Task {
            await takeAndRecordSample(at: now)
            isTakingSample = false
        }
    }

    private func takeAndRecordSample(at sampleDate: Date) async {
        // Reuses the most recent OCR Wisp already ran (see `start()`); nil when
        // none is recent, which is most of the time.
        let screenText = preferences.isActivityTextCaptureEnabled ? recentScreenTextProvider?() : nil
        let sample = await BrainActivitySampler.takeSample(
            at: sampleDate,
            userExcludedBundleIdentifiers: preferences.activityExcludedBundleIdentifiers,
            userExcludedDomains: preferences.activityExcludedDomains,
            screenText: screenText
        )
        // The switch may have flipped while the sample was being read.
        guard isFeedSwitchedOn else { return }
        isRecording = true
        guard let sample else { return }

        let sampleDayKey = BrainActivityDayKey.dayKey(for: sample.date)
        var dayLog = (todayLog?.dayKey == sampleDayKey ? todayLog : nil)
            ?? logFiles.load(dayKey: sampleDayKey)
            ?? BrainActivityDayLog(dayKey: sampleDayKey, spans: [])
        dayLog.spans = BrainActivitySpanMerger.appending(sample, to: dayLog.spans, sampleIntervalSeconds: Self.sampleIntervalSeconds)
        logFiles.save(dayLog)
        todayLog = dayLog
        refreshTodayPublishedState()
    }

    // MARK: - Today's state

    private func loadTodayLog(now: Date) {
        let todayDayKey = BrainActivityDayKey.dayKey(for: now)
        todayLog = logFiles.load(dayKey: todayDayKey) ?? BrainActivityDayLog(dayKey: todayDayKey, spans: [])
        refreshTodayPublishedState()
    }

    private func refreshTodayPublishedState() {
        guard let todayLog else {
            todaySampleCount = 0
            todaySummary = []
            todayDaySummary = nil
            return
        }
        let daySummary = BrainActivitySummaryBuilder.summarize(todayLog)
        todaySampleCount = todayLog.sampleCount
        todayDaySummary = daySummary
        todaySummary = daySummary.displayRows()
    }

    private func pruneExpiredActivityIfNeeded(now: Date) {
        let todayDayKey = BrainActivityDayKey.dayKey(for: now)
        guard lastRetentionPruneDayKey != todayDayKey else { return }
        lastRetentionPruneDayKey = todayDayKey
        logFiles.deleteFiles(olderThanDays: Self.retentionDays, now: now)
        let keptDayKeys = recorderState.digestedDayKeys.filter {
            !BrainActivityDayKey.isExpired(dayKey: $0, now: now, retentionDays: Self.retentionDays)
        }
        if keptDayKeys != recorderState.digestedDayKeys {
            recorderState.digestedDayKeys = keptDayKeys
            saveRecorderState()
        }
    }

    // MARK: - Daily digest

    private func runDueDigestsIfNeeded(now: Date) {
        guard preferences.isBrainEnabled, !isDigesting else { return }
        if let lastFailedDigestAttemptDate = recorderState.lastFailedDigestAttemptDate,
           now.timeIntervalSince(lastFailedDigestAttemptDate) < Self.failedDigestRetryIntervalSeconds {
            return
        }
        let dueDayKeys = BrainActivityDigestSchedule.dayKeysDueForDigest(
            now: now,
            recordedDayKeys: logFiles.recordedDayKeys(),
            digestedDayKeys: Set(recorderState.digestedDayKeys)
        )
        guard !dueDayKeys.isEmpty else { return }
        Task { await digest(dayKeys: dueDayKeys) }
    }

    private func digest(dayKeys: [String]) async {
        guard !isDigesting else { return }
        isDigesting = true
        defer { isDigesting = false }

        for dayKey in dayKeys {
            let dayLog = (todayLog?.dayKey == dayKey ? todayLog : nil) ?? logFiles.load(dayKey: dayKey)
            let daySummary = dayLog.map(BrainActivitySummaryBuilder.summarize)
            guard let daySummary, let compactSummary = BrainActivityDigestText.compactSummary(of: daySummary) else {
                // Too little that day to be worth a model call.
                markDayDigested(dayKey, summaryLine: "nothing notable on \(dayKey)")
                continue
            }

            let sourceMaterial = BrainKnowledgeExtractor.SourceMaterial(
                title: "activity \(dayKey)",
                text: compactSummary,
                materialDescription: "a summary of the apps, documents and websites the user worked in at their Mac on one day",
                extraInstructions: BrainActivityDigestText.extraInstructions(forDayKey: dayKey),
                // A digest files facts onto real pages; it is not a source to cite.
                createsSourcePage: false
            )
            do {
                // Always the local model: see the header on privacy.
                let proposals = try await BrainKnowledgeExtractor.proposeEdits(
                    for: sourceMaterial,
                    modelProvider: ModelProviderFactory.make(.localOllama)
                )
                let provenance = BrainEditProvenance(origin: .activity, label: "activity \(dayKey)", trust: .external)
                let applyResult = proposals.isEmpty
                    ? BrainApplyResult.nothing
                    : BrainStore.shared.apply(proposals: proposals, provenance: provenance)
                let pageCount = applyResult.touchedSlugs.count
                let summaryLine = pageCount == 0
                    ? "nothing to file from \(dayKey)"
                    : "updated \(pageCount) page\(pageCount == 1 ? "" : "s") from \(dayKey)"
                markDayDigested(dayKey, summaryLine: summaryLine)
            } catch {
                print("⚠️ Brain activity: digest of \(dayKey) failed — \(error.localizedDescription)")
                recorderState.lastFailedDigestAttemptDate = Date()
                saveRecorderState()
                lastDigestSummary = "couldn't digest \(dayKey): \(error.localizedDescription)"
                return
            }
        }
    }

    private func markDayDigested(_ dayKey: String, summaryLine: String) {
        if !recorderState.digestedDayKeys.contains(dayKey) {
            recorderState.digestedDayKeys.append(dayKey)
            recorderState.digestedDayKeys.sort()
        }
        let digestDate = Date()
        recorderState.lastDigestDate = digestDate
        recorderState.lastFailedDigestAttemptDate = nil
        saveRecorderState()
        lastDigestDate = digestDate
        lastDigestSummary = summaryLine
        print("🧠 Brain activity: \(summaryLine)")
    }

    // MARK: - State file

    private func loadRecorderState() {
        guard let data = try? Data(contentsOf: stateFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loadedState = try? decoder.decode(BrainActivityRecorderState.self, from: data) else { return }
        recorderState = loadedState
        lastDigestDate = loadedState.lastDigestDate
    }

    private func saveRecorderState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recorderState) else { return }
        try? FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFileURL, options: .atomic)
    }
}
