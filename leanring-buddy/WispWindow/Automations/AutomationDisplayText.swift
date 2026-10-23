//
//  AutomationDisplayText.swift
//  leanring-buddy
//
//  Plain-words descriptions of an automation's parts, shared by every automations view so the
//  list, the chips, the run history and the Today tile all say the same thing the same way.
//  Strings only, no SwiftUI, so nothing here can drift into view logic.
//

import Foundation

nonisolated enum AutomationDisplayText {

    // MARK: - Trigger

    static func triggerSummary(_ trigger: AutomationTrigger) -> String {
        switch trigger {
        case .schedule(let schedule):
            return schedule.summary(calendar: .current)
        case .event(let event):
            return eventSummary(event)
        case .manual:
            return "When I run it"
        }
    }

    static func eventSummary(_ event: AutomationEvent) -> String {
        switch event {
        case .newCanvasItem:
            return "When a new Canvas item shows up"
        case .meetingStarting(let minutesBefore):
            return minutesBefore == 1 ? "1 minute before a meeting" : "\(minutesBefore) minutes before a meeting"
        case .screenTextAppears(let text):
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedText.isEmpty ? "When some text shows on screen" : "When “\(trimmedText)” shows on screen"
        case .fileDropped(let folderPath):
            let folderName = (folderPath as NSString).lastPathComponent
            return folderName.isEmpty ? "When a file lands in a folder" : "When a file lands in \(folderName)"
        case .chromePageWatchMatched(let watchDescription):
            let trimmedDescription = watchDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedDescription.isEmpty
                ? "When a Chrome page watch matches"
                : "When the Chrome page watch for “\(trimmedDescription)” matches"
        case .chromeTabOpened(let host):
            return "When you open \(chromeSiteDisplayName(host)) in Chrome"
        case .chromeTimeOnSite(let host, let minutes):
            return "After \(minutes == 1 ? "1 minute" : "\(minutes) minutes") on \(chromeSiteDisplayName(host)) in Chrome"
        }
    }

    /// "youtube" or "youtube.com" → "YouTube"; blank → "a site".
    private static func chromeSiteDisplayName(_ storedSite: String) -> String {
        let trimmedSite = storedSite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSite.isEmpty else { return "a site" }
        return ChromeSiteMatching.displayName(forSiteHost: ChromeSiteMatching.siteHost(fromSpokenName: trimmedSite) ?? trimmedSite)
    }

    // MARK: - Source

    static func sourceSummary(_ source: AutomationSource) -> String {
        switch source {
        case .nothing:
            return "Nothing extra"
        case .todaysCalendar:
            return "Today's calendar"
        case .canvasDeadlines(let withinDays):
            return withinDays == 1 ? "Canvas, next day" : "Canvas, next \(withinDays) days"
        case .reminders(let listName):
            let trimmedName = listName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedName.isEmpty ? "Reminders" : "Reminders: \(trimmedName)"
        case .clipboard:
            return "Clipboard"
        case .screenText:
            return "Text on screen"
        case .folderFiles(let path):
            let folderName = (path as NSString).lastPathComponent
            return folderName.isEmpty ? "Files in a folder" : "Files in \(folderName)"
        }
    }

    static func sourceSymbolName(_ source: AutomationSource) -> String {
        switch source {
        case .nothing: return "circle.dashed"
        case .todaysCalendar: return "calendar"
        case .canvasDeadlines: return "graduationcap"
        case .reminders: return "checklist"
        case .clipboard: return "doc.on.clipboard"
        case .screenText: return "text.viewfinder"
        case .folderFiles: return "folder"
        }
    }

    // MARK: - Outputs

    static func outputTitle(_ output: AutomationOutput) -> String {
        switch output {
        case .notchCard: return "Notch card"
        case .remindersChecklist(let listTitle):
            let trimmedTitle = listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTitle.isEmpty ? "Reminders" : "Reminders: \(trimmedTitle)"
        case .calendarBlock: return "Calendar block"
        case .notification: return "Notification"
        case .buddyThreadMessage: return "Buddy's thread"
        case .spokenLine: return "Spoken line"
        }
    }

    static func outputsSummary(_ outputs: [AutomationOutput]) -> String {
        guard let firstOutput = outputs.first else { return "Nowhere yet" }
        if outputs.count == 1 { return outputTitle(firstOutput) }
        return "\(outputTitle(firstOutput)) + \(outputs.count - 1) more"
    }

    // MARK: - Notify

    static func notifyTitle(_ policy: AutomationNotifyPolicy) -> String {
        switch policy {
        case .always: return "Every time"
        case .onlyWhenSomethingNew: return "Only when new"
        case .onlyOnFailure: return "Only if it fails"
        case .never: return "Never"
        }
    }

    static func notifyDetail(_ policy: AutomationNotifyPolicy) -> String {
        switch policy {
        case .always: return "Tell me after every run."
        case .onlyWhenSomethingNew: return "Stay quiet when nothing changed."
        case .onlyOnFailure: return "Only speak up when something goes wrong."
        case .never: return "Run silently. Results wait in the history."
        }
    }

    // MARK: - Run history

    static func reasonTitle(_ reason: AutomationRunReason) -> String {
        switch reason {
        case .schedule: return "Scheduled"
        case .missedSchedule: return "Caught up"
        case .event: return "Event"
        case .manual: return "Run now"
        case .shortcutDigit: return "Shortcut"
        case .testRun: return "Test"
        }
    }

    /// One line for a finished (or running) record.
    static func outcomeText(_ outcome: AutomationRunOutcome?) -> String {
        guard let outcome else { return "Running…" }
        switch outcome {
        case .succeeded(let summary):
            return summary.isEmpty ? "Done" : summary
        case .succeededNothingNew:
            return "Nothing new"
        case .failed(let reason):
            return reason
        case .needsApproval:
            return "Needed your OK and didn't get it"
        case .skippedBusy:
            return "Skipped, it was already running"
        case .skippedPaused:
            return "Skipped, it was paused"
        }
    }

    // MARK: - Time

    /// "Today 7:45 AM", "Tomorrow 8:00 AM", "Fri 6:00 PM", "Oct 30, 9:00 AM".
    static func whenText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let timeText = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(timeText)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(timeText)"
        }
        let secondsAway = date.timeIntervalSince(now)
        if secondsAway > 0 && secondsAway < 6 * 24 * 60 * 60 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(timeText)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(timeText)"
    }

    /// "2 min ago", "3 hr ago", "Yesterday".
    static func agoText(_ date: Date, now: Date = Date()) -> String {
        let secondsAgo = max(0, now.timeIntervalSince(date))
        if secondsAgo < 60 { return "Just now" }
        if secondsAgo < 3600 { return "\(Int(secondsAgo / 60)) min ago" }
        if secondsAgo < 24 * 3600 { return "\(Int(secondsAgo / 3600)) hr ago" }
        return whenText(date, now: now)
    }
}
