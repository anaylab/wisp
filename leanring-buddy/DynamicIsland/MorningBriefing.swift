//
//  MorningBriefing.swift
//  leanring-buddy
//
//  The "morning notch": the first time the user is at the Mac each day, a
//  banner drops out of the notch — "I can do 5 things for you today" — with
//  Dismiss and Show me. Show me opens the notch panel on a TODAY list; each row
//  runs with one click. If the banner is ignored it tucks into a small ✦ count
//  beside the notch until dismissed.
//
//  The suggestions are built deterministically, with no model call: today's
//  meetings and due reminders (only when that access was already granted —
//  this never prompts), then the user's pinned and recently used routines. A
//  3B local model inventing "things I could do" each morning would be slow to
//  produce and hard to trust; these are all things Wisp can actually do.
//
//  It waits while `QuietModeMonitor` says the user is on a call, and can be
//  turned off in the dashboard's Agent tab (`AnnouncementPreferences`).
//

import AppKit
import Combine
import CoreGraphics
import EventKit
import Foundation

/// One thing the banner offers to do.
struct MorningSuggestion: Identifiable, Equatable {
    enum Action: Equatable {
        /// Run a saved routine (its instruction goes through the normal turn).
        case runRoutine(routineID: UUID)
        /// Ask Wisp a question, exactly as if the user had typed it.
        case askQuestion(String)
    }

    let id: String
    let title: String
    let symbolName: String
    let action: Action
}

/// Builds the day's suggestions from what Wisp knows it can do. Pure, so the
/// ordering and caps are testable.
enum MorningSuggestionBuilder {
    /// The most suggestions offered in one morning.
    static let maximumSuggestions = 7
    /// A routine not pinned to the notch is suggested only if it was used this
    /// recently — otherwise it's just clutter from a routine the user forgot.
    static let recentRoutineUseWindowSeconds: TimeInterval = 14 * 24 * 60 * 60

    static func buildSuggestions(
        routines: [WispRoutine],
        remainingMeetingCountToday: Int?,
        hasRemindersAccess: Bool,
        now: Date
    ) -> [MorningSuggestion] {
        var suggestions: [MorningSuggestion] = []

        // nil means no Calendar access, 0 means a clear day — neither is worth offering.
        if let remainingMeetingCountToday, remainingMeetingCountToday > 0 {
            let meetingsPhrase = remainingMeetingCountToday == 1
                ? "today's meeting"
                : "today's \(remainingMeetingCountToday) meetings"
            suggestions.append(MorningSuggestion(
                id: "calendar-today",
                title: "Go over \(meetingsPhrase)",
                symbolName: "calendar",
                action: .askQuestion("What's on my calendar today?")
            ))
        }

        if hasRemindersAccess {
            suggestions.append(MorningSuggestion(
                id: "reminders-today",
                title: "Check what's due today",
                symbolName: "checklist",
                action: .askQuestion("What reminders are due today?")
            ))
        }

        let recentUseCutoffDate = now.addingTimeInterval(-recentRoutineUseWindowSeconds)
        let suggestedRoutines = routines
            .filter { routine in
                if routine.isPinnedInNotch { return true }
                guard let lastRunAt = routine.lastRunAt else { return false }
                return lastRunAt >= recentUseCutoffDate
            }
            .sorted { firstRoutine, secondRoutine in
                // Pinned first, then most recently used.
                if firstRoutine.isPinnedInNotch != secondRoutine.isPinnedInNotch {
                    return firstRoutine.isPinnedInNotch
                }
                return (firstRoutine.lastRunAt ?? .distantPast) > (secondRoutine.lastRunAt ?? .distantPast)
            }
        for routine in suggestedRoutines {
            suggestions.append(MorningSuggestion(
                id: "routine-\(routine.id.uuidString)",
                title: routine.name,
                symbolName: routine.symbolName,
                action: .runRoutine(routineID: routine.id)
            ))
        }

        return Array(suggestions.prefix(maximumSuggestions))
    }
}

/// When the banner may appear: once per calendar day, during the day, only
/// once the user is actually at the Mac (so it isn't waiting, stale, on an
/// empty room at 6am).
enum MorningBriefingSchedule {
    static let earliestPresentationHour = 5
    /// After this the day's suggestions would arrive too late to be useful.
    static let latestPresentationHour = 17
    /// The user counts as present if they touched the keyboard or mouse this recently.
    static let maximumIdleSecondsToCountAsPresent: TimeInterval = 120

    /// "2026-09-25" — which day a presentation belongs to, in local time.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            dateComponents.year ?? 0,
            dateComponents.month ?? 0,
            dateComponents.day ?? 0
        )
    }

    static func shouldPresent(
        now: Date,
        calendar: Calendar,
        lastPresentedDayKey: String?,
        secondsSinceLastUserInput: TimeInterval
    ) -> Bool {
        guard lastPresentedDayKey != dayKey(for: now, calendar: calendar) else { return false }
        let hour = calendar.component(.hour, from: now)
        guard hour >= earliestPresentationHour, hour < latestPresentationHour else { return false }
        return secondsSinceLastUserInput <= maximumIdleSecondsToCountAsPresent
    }
}

/// Decides when to present the briefing and holds the day's pending suggestions.
@MainActor
final class MorningBriefingController: ObservableObject {
    static let shared = MorningBriefingController()

    private static let lastPresentedDayUserDefaultsKey = "wisp.morningBriefing.lastPresentedDay"
    private static let checkIntervalSeconds: TimeInterval = 60

    /// The suggestions not yet run or dismissed today. Empty when there is no
    /// briefing to show.
    @Published private(set) var pendingSuggestions: [MorningSuggestion] = []

    /// Bumped each time a briefing is freshly presented, so the notch can drop
    /// the banner for it. A plain "has suggestions" flag can't do that — the
    /// notch must open once when the briefing arrives, not every time it reopens.
    @Published private(set) var presentationSequenceNumber = 0

    private var checkTimer: Timer?
    private var isBuildingBriefing = false

    private init() {}

    var hasPendingBriefing: Bool { !pendingSuggestions.isEmpty }

    /// Starts the once-a-minute check. Safe to call more than once.
    func start() {
        guard checkTimer == nil else { return }
        let timer = Timer(timeInterval: Self.checkIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentIfDue()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        presentIfDue()
    }

    /// The dashboard's "Show now" — builds and presents today's briefing on
    /// demand, ignoring the once-a-day schedule (but not the on/off switch).
    func presentNow() {
        Task { await buildAndPresentBriefing() }
    }

    func dismiss() {
        pendingSuggestions = []
    }

    /// Runs one suggestion and takes it off the list; when the last one goes,
    /// the briefing is done.
    func perform(_ suggestion: MorningSuggestion, companionManager: CompanionManager) {
        pendingSuggestions.removeAll { $0.id == suggestion.id }
        switch suggestion.action {
        case .runRoutine(let routineID):
            companionManager.runRoutine(withID: routineID)
        case .askQuestion(let question):
            // Clear Wisp's own surfaces first and let them animate out, as a
            // routine does, so a screenshot (if the turn takes one) shows the
            // user's work rather than the notch.
            NotificationCenter.default.post(name: .wispDismissPanel, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                companionManager.askTypedQuestion(question)
            }
        }
    }

    private func presentIfDue() {
        guard AnnouncementPreferences.shared.areMorningSuggestionsEnabled,
              !QuietModeMonitor.shared.isQuiet,
              !isBuildingBriefing else { return }

        let secondsSinceLastUserInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            // kCGAnyInputEventType: any keyboard, mouse or trackpad event.
            eventType: CGEventType(rawValue: ~0)!
        )
        guard MorningBriefingSchedule.shouldPresent(
            now: Date(),
            calendar: .current,
            lastPresentedDayKey: UserDefaults.standard.string(forKey: Self.lastPresentedDayUserDefaultsKey),
            secondsSinceLastUserInput: secondsSinceLastUserInput
        ) else { return }

        Task { await buildAndPresentBriefing() }
    }

    private func buildAndPresentBriefing() async {
        guard AnnouncementPreferences.shared.areMorningSuggestionsEnabled, !isBuildingBriefing else { return }
        isBuildingBriefing = true
        defer { isBuildingBriefing = false }

        let now = Date()
        // Marked before building so a slow calendar read can't lead to a second
        // presentation, and so a day with nothing to suggest isn't re-checked
        // every minute.
        UserDefaults.standard.set(
            MorningBriefingSchedule.dayKey(for: now, calendar: .current),
            forKey: Self.lastPresentedDayUserDefaultsKey
        )

        let remainingMeetingCountToday = await CalendarDataProvider.shared
            .remainingTimedEventCountTodayIfAuthorized(now: now)
        let hasRemindersAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        let suggestions = MorningSuggestionBuilder.buildSuggestions(
            routines: RoutineStore.shared.routines,
            remainingMeetingCountToday: remainingMeetingCountToday,
            hasRemindersAccess: hasRemindersAccess,
            now: now
        )
        guard !suggestions.isEmpty else { return }

        pendingSuggestions = suggestions
        presentationSequenceNumber += 1
    }
}
