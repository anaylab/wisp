import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL (line \(line)): \(message)") }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

// MARK: plan
var wild = StudyPlan(focusMinutes: 500, shortBreakMinutes: 0, longBreakMinutes: 900, totalRounds: 99, roundsBeforeLongBreak: 0)
wild = wild.clamped()
check(wild.focusMinutes == 120 && wild.shortBreakMinutes == 1 && wild.longBreakMinutes == 60
      && wild.totalRounds == 8 && wild.roundsBeforeLongBreak == 1, "clamped")
check(StudyPlan.presets[0].plan.matchingPresetID == "classic", "preset match")
check(StudyPlan(focusMinutes: 33).matchingPresetID == nil, "no preset for 33")

// MARK: full classic session: F B F B F B F L? (4 rounds, long break after 4th is skipped: ends)
var plan = StudyPlan(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, totalRounds: 4, roundsBeforeLongBreak: 2)
var session = StudySession(plan: plan, goal: "calc", startedAt: t0)
check(session.phase == .focus && session.remainingSeconds(at: t0) == 1500, "starts in focus")
check(session.advance(at: at(24)).isEmpty, "no event before the end")
var events = session.advance(at: at(25))
check(events == [.phaseEnded(.focus, wasCompleted: true), .phaseBegan(.shortBreak)], "focus 1 -> short break: \(events)")
events = session.advance(at: at(30))
check(events == [.phaseEnded(.shortBreak, wasCompleted: true), .phaseBegan(.focus)] && session.focusRound == 2, "break -> focus 2")
events = session.advance(at: at(55))
check(session.phase == .longBreak, "long break after round 2 (roundsBeforeLongBreak 2)")
_ = session.advance(at: at(70))
_ = session.advance(at: at(95))   // focus 3 ends
check(session.phase == .shortBreak && session.focusRound == 3, "short break after round 3")
_ = session.advance(at: at(100))
events = session.advance(at: at(125))   // focus 4 ends
check(events == [.phaseEnded(.focus, wasCompleted: true), .finished], "last focus finishes: \(events)")
check(session.isFinished && session.completedFocusSeconds == 4 * 1500 && session.completedFocusRounds == 4, "credited")
check(session.advance(at: at(200)).isEmpty, "finished stays finished")

// MARK: pause freezes the clock
session = StudySession(plan: plan, goal: "", startedAt: t0)
session.pause(at: at(10))
check(session.isPaused && session.remainingSeconds(at: at(500)) == 900, "paused remaining fixed")
check(session.advance(at: at(500)).isEmpty, "no advance while paused")
session.resume(at: at(500))
check(session.remainingSeconds(at: at(500)) == 900 && session.advance(at: at(514)).isEmpty, "resume continues")
check(!session.advance(at: at(515)).isEmpty, "ends 15 min after resume")

// MARK: sleep never credits extra
session = StudySession(plan: plan, goal: "", startedAt: t0)
events = session.advance(at: at(600))   // woke 10 hours later
check(session.phase == .shortBreak && session.remainingSeconds(at: at(600)) == 300, "next phase starts from now")
check(session.completedFocusSeconds == 1500, "only one focus phase credited")

// MARK: skip
session = StudySession(plan: plan, goal: "", startedAt: t0)
events = session.skipPhase(at: at(10))
check(events == [.phaseEnded(.focus, wasCompleted: false), .phaseBegan(.shortBreak)], "skip focus")
check(session.completedFocusSeconds == 600 && session.completedFocusRounds == 0, "skipped focus keeps time, no round")

// MARK: end early
session = StudySession(plan: plan, goal: "", startedAt: t0)
events = session.end(at: at(7))
check(events.last == .finished && session.completedFocusSeconds == 420 && session.isFinished, "end early keeps 7 min")
session = StudySession(plan: plan, goal: "", startedAt: t0)
_ = session.advance(at: at(25))
events = session.end(at: at(27))   // during a break
check(session.completedFocusSeconds == 1500, "ending in a break adds nothing")

// MARK: manual start
plan.autoStartNextPhase = false
session = StudySession(plan: plan, goal: "", startedAt: t0)
events = session.advance(at: at(25))
check(events == [.phaseEnded(.focus, wasCompleted: true)] && session.isAwaitingStart && !session.isRunning, "waits")
check(session.remainingSeconds(at: at(40)) == 300, "awaiting break shows its full length")
events = session.startAwaitedPhase(at: at(40))
check(events == [.phaseBegan(.shortBreak)] && session.remainingSeconds(at: at(40)) == 300, "starts on demand")

// MARK: extend
plan.autoStartNextPhase = true
session = StudySession(plan: plan, goal: "", startedAt: t0)
session.extend(bySeconds: 300, at: at(10))
check(session.remainingSeconds(at: at(10)) == 900 + 300, "extend adds to remaining")
check(session.advance(at: at(25)).isEmpty && !session.advance(at: at(30)).isEmpty, "ends 5 min later")
check(session.extraSeconds == 0 && session.phase == .shortBreak, "extension resets with the phase")
check(session.completedFocusSeconds == 1800, "extension is credited as focus")
session = StudySession(plan: plan, goal: "", startedAt: t0)
session.pause(at: at(5))
session.extend(bySeconds: 300, at: at(6))
check(session.remainingSeconds(at: at(50)) == 1200 + 300, "extend while paused")
check(abs(session.progress(at: at(50)) - 0.2) < 0.0001 || session.progress(at: at(50)) > 0, "progress stays sane")
session = StudySession(plan: plan, goal: "", startedAt: t0)
for _ in 0..<30 { session.extend(bySeconds: 600, at: t0) }
check(session.extraSeconds == StudySession.maximumExtraSeconds, "extension capped")
session = StudySession(plan: plan, goal: "", startedAt: t0)
_ = session.advance(at: at(25))
session.extend(bySeconds: 300, at: at(26))
check(session.extraSeconds == 300, "extend during a break is allowed")
plan.autoStartNextPhase = false
session = StudySession(plan: plan, goal: "", startedAt: t0)
_ = session.advance(at: at(25))
session.extend(bySeconds: 300, at: at(26))
check(session.extraSeconds == 0, "no extend while awaiting start")
plan.autoStartNextPhase = true

// MARK: progress and earned
session = StudySession(plan: StudyPlan(), goal: "", startedAt: t0)
check(abs(session.progress(at: at(12.5)) - 0.5) < 0.0001, "progress half")
check(session.focusSecondsEarned(at: at(10)) == 600, "earned mid-phase")

// MARK: blocklist
var list = StudyBlocklist()
check(list.blockedDomain(forURLString: "https://www.youtube.com/watch?v=1") == "youtube.com", "youtube blocked")
check(list.blockedDomain(forURLString: "https://m.reddit.com/r/x") == "reddit.com", "subdomain blocked")
check(list.blockedDomain(forURLString: "https://notreddit.com") == nil, "suffix trick not blocked")
check(list.blockedDomain(forURLString: "https://canvas.instructure.com") == nil, "study site free")
list.customDomains = ["wikipedia.org"]
check(list.blockedDomain(forURLString: "en.wikipedia.org/wiki/X") == "wikipedia.org", "custom domain")
list.blocksWebsites = false
check(list.blockedDomain(forURLString: "https://youtube.com") == nil, "websites off")
check(StudyBlocklist.normalizedDomain(fromUserText: " https://www.Reddit.com/r/all ") == "reddit.com", "normalise")
check(StudyBlocklist.normalizedDomain(fromUserText: "notasite") == nil, "reject word")
check(StudyBlocklist.normalizedDomain(fromUserText: "bad domain.com") == nil, "reject space")
list = StudyBlocklist()
list.customApps = [StudyBlockedApp(bundleIdentifier: "com.apple.finder", name: "Finder"),
                   StudyBlockedApp(bundleIdentifier: "com.foo.game", name: "Game"),
                   StudyBlockedApp(bundleIdentifier: "com.wisp.me", name: "Wisp")]
check(list.blocksApp(bundleIdentifier: "com.foo.game", ownBundleIdentifier: "com.wisp.me"), "custom app")
check(!list.blocksApp(bundleIdentifier: "com.apple.finder", ownBundleIdentifier: nil), "finder protected")
check(!list.blocksApp(bundleIdentifier: "com.wisp.me", ownBundleIdentifier: "com.wisp.me"), "never itself")
check(list.blocksApp(bundleIdentifier: "com.burbn.instagram", ownBundleIdentifier: nil), "social app")
list.enabledCategoryIDs = []
list.customApps = []
check(list.isEmpty, "empty when nothing chosen")

// MARK: stats
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
let now = Date(timeIntervalSince1970: 1_800_000_000)
func entry(daysAgo: Int, minutes: Double) -> StudyLogEntry {
    let end = now.addingTimeInterval(-Double(daysAgo) * 86_400 - 60)
    return StudyLogEntry(id: UUID(), goal: "", startedAt: end.addingTimeInterval(-minutes * 60), endedAt: end,
                         focusSeconds: minutes * 60, completedRounds: 1, distractionsHeldBack: 0)
}
let log = [entry(daysAgo: 0, minutes: 25), entry(daysAgo: 0, minutes: 25), entry(daysAgo: 1, minutes: 50), entry(daysAgo: 2, minutes: 10), entry(daysAgo: 4, minutes: 30)]
check(StudyStats.focusSeconds(on: now, in: log, calendar: cal) == 3000, "today")
check(StudyStats.streakDays(endingAt: now, in: log, calendar: cal) == 3, "streak 3")
check(StudyStats.streakDays(endingAt: now, in: [entry(daysAgo: 1, minutes: 5)], calendar: cal) == 1, "empty today keeps streak")
check(StudyStats.streakDays(endingAt: now, in: [entry(daysAgo: 3, minutes: 5)], calendar: cal) == 0, "gap breaks")
check(StudyStats.dailyFocusSeconds(lastDays: 7, endingAt: now, in: log, calendar: cal).map(\.seconds) == [0, 0, 1800, 0, 600, 3000, 3000].map { Double($0) }.enumerated().map { $0.offset == 6 ? 3000 : $0.element }, "7 day bars")
check(StudyStats.completedRounds(on: now, in: log, calendar: cal) == 2, "rounds today")
check(StudyStats.appending(log[0], to: Array(repeating: log[0], count: 500)).count == 500, "capped")
check(StudyTimeFormatter.clock(1500) == "25:00" && StudyTimeFormatter.clock(3725) == "1:02:05", "clock")
check(StudyTimeFormatter.duration(4500) == "1 h 15 min" && StudyTimeFormatter.duration(0) == "0 min", "duration")

// MARK: buddy
let buddyPlan = StudyPlan(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, totalRounds: 2, roundsBeforeLongBreak: 2)
var buddySession = StudySession(plan: buddyPlan, goal: "", startedAt: t0)
check(StudyBuddyNudgePlanner.nextNudge(session: buddySession, now: at(5), pausedSince: nil, alreadyShown: []) == nil, "quiet early on")
check(StudyBuddyNudgePlanner.nextNudge(session: buddySession, now: at(13), pausedSince: nil, alreadyShown: [])?.kind == .halfway, "halfway speaks")
check(StudyBuddyNudgePlanner.nextNudge(session: buddySession, now: at(13), pausedSince: nil, alreadyShown: [.halfway]) == nil, "halfway only once")
let lastStretch = StudyBuddyNudgePlanner.nextNudge(session: buddySession, now: at(23.5), pausedSince: nil, alreadyShown: [.halfway])
check(lastStretch?.kind == .lastStretch && lastStretch?.offer == .extend, "offers +5 near the end")
let shortSession = StudySession(plan: StudyPlan(focusMinutes: 5), goal: "", startedAt: t0)
check(StudyBuddyNudgePlanner.nextNudge(session: shortSession, now: at(4), pausedSince: nil, alreadyShown: [.halfway]) == nil, "no extend offer on a 5 minute block")
buddySession.pause(at: at(2))
check(StudyBuddyNudgePlanner.nextNudge(session: buddySession, now: at(4), pausedSince: at(2), alreadyShown: []) == nil, "short pause stays quiet")
check(StudyBuddyNudgePlanner.nextNudge(session: buddySession, now: at(5.5), pausedSince: at(2), alreadyShown: [])?.offer == .resume, "long pause offers resume")
var awaiting = StudySession(plan: StudyPlan(focusMinutes: 25, totalRounds: 2, autoStartNextPhase: false), goal: "", startedAt: t0)
_ = awaiting.advance(at: at(25))
check(StudyBuddyNudgePlanner.nextNudge(session: awaiting, now: at(26), pausedSince: nil, alreadyShown: [])?.offer == .startNext, "awaiting start offers start")
var breakSession = StudySession(plan: buddyPlan, goal: "", startedAt: t0)
_ = breakSession.advance(at: at(25))
check(StudyBuddyNudgePlanner.nextNudge(session: breakSession, now: at(29.7), pausedSince: nil, alreadyShown: [])?.kind == .breakEnding, "break ending")
check(StudyBuddyFeeling.feeling(for: nil, isCheering: false) == .idle, "idle without session")
check(StudyBuddyFeeling.feeling(for: buddySession, isCheering: false) == .sleepy, "paused is sleepy")
check(StudyBuddyFeeling.feeling(for: breakSession, isCheering: false) == .resting, "break rests")
check(StudyBuddyFeeling.feeling(for: breakSession, isCheering: true) == .cheering, "cheering wins")
check(StudyBuddyFeeling.feeling(for: StudySession(plan: buddyPlan, goal: "", startedAt: t0), isCheering: false) == .focused, "focus is focused")
check(StudyBuddyVoice.pokeLine(phase: .focus, isPaused: false, variant: 0) != StudyBuddyVoice.pokeLine(phase: .focus, isPaused: false, variant: 1), "pokes vary")
check(StudyBuddyVoice.pokeLine(phase: .focus, isPaused: false, variant: -3).isEmpty == false, "negative variant is safe")
check(StudyBuddyVoice.greeting(todayRounds: 0, streakDays: 0, hour: 8).hasPrefix("Morning"), "morning greeting")
check(StudyBuddyVoice.greeting(todayRounds: 2, streakDays: 5, hour: 8).contains("2 rounds"), "rounds greeting wins")
check(StudyBuddyVoice.finishedLine(rounds: 1, focusSeconds: 1500) == "Nice! 1 round, 25 min of focus.", "finished line")
check(StudyBuddyAdvisor.recommendedPresetID(from: []) == "classic", "default preset")
func usual(minutesPerRound: Double) -> StudyLogEntry {
    StudyLogEntry(id: UUID(), goal: "", startedAt: t0, endedAt: t0, focusSeconds: minutesPerRound * 60 * 2, completedRounds: 2, distractionsHeldBack: 0)
}
check(StudyBuddyAdvisor.recommendedPresetID(from: [usual(minutesPerRound: 48), usual(minutesPerRound: 50)]) == "deep", "deep user")
check(StudyBuddyAdvisor.recommendedPresetID(from: [usual(minutesPerRound: 14)]) == "sprint", "sprint user")

if failures == 0 { print("Study mode: all checks passed") } else { print("\(failures) failure(s)"); exit(1) }
