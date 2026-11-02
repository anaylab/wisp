//
//  StudySessionController.swift
//  leanring-buddy
//
//  Owns Study mode while the app runs: the saved plan and blocklist, the running
//  `StudySession`, a half-second tick, the distraction blocker (focus phases only),
//  the sound cue, notification and island flash at each phase change, and the
//  finished-session log (`study-log.json`, 0600, numbers plus the goal text).
//  The session itself lives only in memory: quitting Wisp ends it.
//

import AppKit
import Combine
import UserNotifications

@MainActor
final class StudySessionController: ObservableObject {
    static let shared = StudySessionController()

    @Published var plan: StudyPlan { didSet { persistSettings() } }
    @Published var blocklist: StudyBlocklist { didSet { persistSettings() } }
    @Published var goal = ""

    @Published private(set) var session: StudySession?
    /// The session that just ended, kept so the window can show the "nice work" screen.
    @Published private(set) var finishedSummary: StudyLogEntry?
    /// Refreshed every tick; views read the clock from here so they redraw as one.
    @Published private(set) var now = Date()
    @Published private(set) var distractionsHeldBack = 0
    @Published private(set) var lastHeldBackLine: String?
    @Published private(set) var browserPermissionNote: String?
    @Published private(set) var log: [StudyLogEntry] = []
    /// A few words the notch flank shows for a moment after a phase change ("Break!").
    @Published private(set) var phaseBanner: String?
    /// What the study buddy is saying right now, if anything (a line, sometimes with a one-tap offer).
    @Published private(set) var buddyMessage: StudyBuddyMessage?
    /// Goes up whenever the buddy speaks or is poked, so its character can squish.
    @Published private(set) var buddyBounce = 0
    /// True for a few seconds after a finished block or a held-back distraction.
    @Published private(set) var isBuddyCheering = false

    /// Set by `NotchWindowController` so a phase change can flash the island.
    var flashIslandSuccess: (() -> Void)?

    private let blocker = StudyDistractionBlocker()
    private var tickTimer: Timer?
    private var heldBackLineClearWorkItem: DispatchWorkItem?
    private var phaseBannerClearWorkItem: DispatchWorkItem?
    private var buddyMessageClearWorkItem: DispatchWorkItem?
    private var buddyCheerClearWorkItem: DispatchWorkItem?
    private var nudgesShownThisPhase: Set<StudyBuddyNudgeKind> = []
    private var pausedSince: Date?
    private var buddyLineCount = 0
    private var lastBuddySpeechAt = Date()
    /// A quiet buddy checks in with a short word after this long.
    private static let buddyCheckInSeconds: TimeInterval = 7 * 60

    private static let settingsPlanKey = "wisp.study.plan"
    private static let settingsBlocklistKey = "wisp.study.blocklist"

    private init() {
        plan = Self.loadStored(StudyPlan.self, forKey: Self.settingsPlanKey) ?? StudyPlan()
        blocklist = Self.loadStored(StudyBlocklist.self, forKey: Self.settingsBlocklistKey) ?? StudyBlocklist()
        log = Self.loadLog()

        blocker.onHeldBack = { [weak self] line in self?.recordHeldBack(line) }
        blocker.onBrowserPermissionMissing = { [weak self] browserName in
            self?.browserPermissionNote = "Allow Wisp to control \(browserName) in System Settings → Privacy & Security → Automation to block sites there."
        }
    }

    // MARK: - State for the UI

    var isSessionActive: Bool { session != nil }

    var buddyFeeling: StudyBuddyFeeling {
        StudyBuddyFeeling.feeling(for: session, isCheering: isBuddyCheering)
    }

    /// The preset the buddy suggests, from the user's usual block length.
    var recommendedPresetID: String { StudyBuddyAdvisor.recommendedPresetID(from: log) }

    var todayFocusSeconds: TimeInterval {
        StudyStats.focusSeconds(on: now, in: log) + (session?.focusSecondsEarned(at: now) ?? 0)
    }

    /// Plants in today's garden: rounds finished today, including the running session's.
    var todayCompletedRounds: Int {
        StudyStats.completedRounds(on: now, in: log) + (session?.completedFocusRounds ?? 0)
    }

    var streakDays: Int { StudyStats.streakDays(endingAt: now, in: log) }

    var lastSevenDays: [(day: Date, seconds: TimeInterval)] {
        StudyStats.dailyFocusSeconds(lastDays: 7, endingAt: now, in: log)
    }

    /// For the menu bar: "Focus 18:24", "Break 03:10", or nil with no session.
    var menuBarStatusText: String? {
        guard let session else { return nil }
        if session.isAwaitingStart { return "\(session.phase.title) ready" }
        let paused = session.isPaused ? " · paused" : ""
        return "\(session.phase.title) \(StudyTimeFormatter.clock(session.remainingSeconds(at: now)))\(paused)"
    }

    // MARK: - Control

    func startSession() {
        guard session == nil else { return }
        let startDate = Date()
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        session = StudySession(plan: plan, goal: trimmedGoal, startedAt: startDate)
        finishedSummary = nil
        distractionsHeldBack = 0
        lastHeldBackLine = nil
        browserPermissionNote = nil
        now = startDate
        nudgesShownThisPhase = []
        pausedSince = nil
        beginTicking()
        updateBlocker()
        WispSoundPlayer.shared.play(.listening)
        say(StudyBuddyVoice.startLine(goal: trimmedGoal, round: 1, totalRounds: plan.totalRounds, variant: buddyLineCount))
    }

    /// One-tap start from the notch: adopt the preset's plan (so the Study page shows the same one) and go.
    func startSession(using preset: StudyPlan) {
        guard session == nil else { return }
        plan = preset
        startSession()
    }

    func pause() {
        mutateSession { $0.pause(at: Date()) }
        pausedSince = Date()
        updateBlocker()
    }

    func resume() {
        mutateSession { $0.resume(at: Date()) }
        pausedSince = nil
        nudgesShownThisPhase.remove(.longPause)
        updateBlocker()
    }

    /// Five more minutes on the running phase.
    func extendPhase() {
        mutateSession { $0.extend(bySeconds: 5 * 60, at: Date()) }
    }

    func skipPhase() {
        guard var current = session else { return }
        let events = current.skipPhase(at: Date())
        session = current
        handle(events)
    }

    func startNextPhase() {
        guard var current = session else { return }
        let events = current.startAwaitedPhase(at: Date())
        session = current
        handle(events)
    }

    /// Ends the session now, keeping the focus time already spent.
    func endSession() {
        guard var current = session else { return }
        let events = current.end(at: Date())
        session = current
        handle(events)
    }

    // MARK: - Buddy

    /// A tap on the buddy: a short encouraging line and a squish.
    func pokeBuddy() {
        buddyLineCount += 1
        let phase = session?.phase ?? .focus
        say(StudyBuddyVoice.pokeLine(phase: phase, isPaused: session?.isPaused ?? false, variant: buddyLineCount))
    }

    /// The user took the buddy's offer: do it.
    func acceptBuddyOffer() {
        guard let offer = buddyMessage?.offer else { return }
        dismissBuddyMessage()
        switch offer {
        case .extend: extendPhase()
        case .resume: resume()
        case .startNext: startNextPhase()
        }
        buddyBounce += 1
    }

    func dismissBuddyMessage() {
        buddyMessageClearWorkItem?.cancel()
        buddyMessage = nil
    }

    private func say(_ text: String, offer: StudyBuddyOffer? = nil) {
        let message = StudyBuddyMessage(text: text, offer: offer)
        buddyLineCount += 1
        buddyBounce += 1
        lastBuddySpeechAt = Date()
        buddyMessage = message
        buddyMessageClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // Only clear this very line, not a newer one that replaced it.
            if self?.buddyMessage?.id == message.id { self?.buddyMessage = nil }
        }
        buddyMessageClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + message.lifetimeSeconds, execute: workItem)
    }

    private func cheerBriefly() {
        isBuddyCheering = true
        buddyCheerClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.isBuddyCheering = false }
        buddyCheerClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    /// Lets the buddy speak up on its own when something is worth saying, but never over a line still showing.
    private func speakUpIfNeeded(session: StudySession) {
        guard buddyMessage == nil else { return }
        if let nudge = StudyBuddyNudgePlanner.nextNudge(
            session: session, now: now, pausedSince: pausedSince, alreadyShown: nudgesShownThisPhase
        ) {
            nudgesShownThisPhase.insert(nudge.kind)
            say(nudge.text, offer: nudge.offer)
            return
        }
        // Nothing planned for a while: a short unprompted word keeps the buddy feeling alive.
        if session.isRunning, !session.isPaused, now.timeIntervalSince(lastBuddySpeechAt) >= Self.buddyCheckInSeconds {
            say(StudyBuddyVoice.pokeLine(phase: session.phase, isPaused: false, variant: buddyLineCount))
        }
    }

    func dismissFinishedSummary() {
        finishedSummary = nil
    }

    func clearLog() {
        log = []
        Self.saveLog([])
    }

    // MARK: - Ticking

    private func beginTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        guard var current = session else { return }
        let events = current.advance(at: now)
        if !events.isEmpty {
            session = current
            handle(events)
        } else {
            speakUpIfNeeded(session: current)
        }
    }

    private func mutateSession(_ change: (inout StudySession) -> Void) {
        guard var current = session else { return }
        change(&current)
        session = current
    }

    // MARK: - Events

    private func handle(_ events: [StudyEvent]) {
        guard !events.isEmpty else { return }
        now = Date()
        if session?.isAwaitingStart == true { showPhaseBanner("Ready") }
        for event in events {
            switch event {
            case .phaseEnded(let phase, let wasCompleted):
                nudgesShownThisPhase = []
                if wasCompleted && phase == .focus { cheerBriefly() }
                if wasCompleted {
                    WispSoundPlayer.shared.play(phase == .focus ? .success : .reply)
                    flashIslandSuccess?()
                    notifyPhaseEnded(phase)
                }
            case .phaseBegan(let phase):
                showPhaseBanner(phase == .focus ? "Focus!" : "Break!")
                if let current = session {
                    say(phase == .focus
                        ? StudyBuddyVoice.startLine(goal: "", round: current.focusRound, totalRounds: current.plan.totalRounds, variant: buddyLineCount)
                        : StudyBuddyVoice.breakLine(isLong: phase == .longBreak, variant: buddyLineCount))
                }
            case .finished:
                showPhaseBanner("Done!")
                finishSession()
                return
            }
        }
        updateBlocker()
    }

    private func finishSession() {
        guard let current = session else { return }
        stopTicking()
        blocker.stop()
        let endedAt = current.endedAt ?? Date()
        let entry = StudyLogEntry(
            id: UUID(),
            goal: current.goal,
            startedAt: current.startedAt,
            endedAt: endedAt,
            focusSeconds: current.completedFocusSeconds,
            completedRounds: current.completedFocusRounds,
            distractionsHeldBack: distractionsHeldBack
        )
        session = nil
        pausedSince = nil
        // A session abandoned before any focus time isn't worth a log line or a celebration.
        guard entry.focusSeconds >= 60 else { return }
        log = StudyStats.appending(entry, to: log)
        Self.saveLog(log)
        finishedSummary = entry
        cheerBriefly()
        say(StudyBuddyVoice.finishedLine(rounds: entry.completedRounds, focusSeconds: entry.focusSeconds))
        WispSoundPlayer.shared.play(.success)
        flashIslandSuccess?()
    }

    private func showPhaseBanner(_ text: String) {
        phaseBanner = text
        phaseBannerClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.phaseBanner = nil
        }
        phaseBannerClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Blocking is on only while a focus phase is actually running.
    private func updateBlocker() {
        guard let session, session.phase == .focus, session.isRunning, !session.isPaused else {
            blocker.stop()
            return
        }
        if !blocker.isActive {
            blocker.start(blocklist: blocklist)
        }
    }

    private func recordHeldBack(_ line: String) {
        distractionsHeldBack += 1
        lastHeldBackLine = line
        cheerBriefly()
        say(StudyBuddyVoice.heldBackLine(detail: line))
        heldBackLineClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.lastHeldBackLine = nil
        }
        heldBackLineClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func notifyPhaseEnded(_ phase: StudyPhase) {
        guard NSApp.isActive == false else { return }
        let title = phase == .focus ? "Focus block done" : "Break over"
        let body = phase == .focus ? "Nice. Take a breather." : "Ready for the next round?"
        Task {
            let notificationCenter = UNUserNotificationCenter.current()
            let isAuthorized = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
            guard isAuthorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await notificationCenter.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - Persistence

    private func persistSettings() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(plan.clamped()) {
            UserDefaults.standard.set(data, forKey: Self.settingsPlanKey)
        }
        if let data = try? encoder.encode(blocklist) {
            UserDefaults.standard.set(data, forKey: Self.settingsBlocklistKey)
        }
    }

    private static func loadStored<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static var logFileURL: URL {
        WispDemoMode.applicationSupportDirectory
            .appendingPathComponent("Wisp", isDirectory: true)
            .appendingPathComponent("study-log.json")
    }

    private static func loadLog() -> [StudyLogEntry] {
        guard let data = try? Data(contentsOf: logFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StudyLogEntry].self, from: data)) ?? []
    }

    private static func saveLog(_ entries: [StudyLogEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        let directoryURL = logFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: logFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
    }
}
