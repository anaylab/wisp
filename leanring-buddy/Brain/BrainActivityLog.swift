//
//  BrainActivityLog.swift
//  leanring-buddy
//
//  The activity feed's record of a day: consecutive identical samples merged
//  into spans ("09:12–09:47 in Figma, 'Atlas spec'"), persisted per day as
//
//      ~/.wisp/brain/raw/activity/YYYY-MM-DD.md    human-readable span list
//      ~/.wisp/brain/raw/activity/YYYY-MM-DD.json  the same spans, for summaries
//
//  Raw files are evidence, never edited by the page writers. They are kept 30
//  days and can be deleted all at once from the Brain page. Screenshots are
//  never stored — a span holds names, a cleaned URL and (opt-in) ≤300
//  characters of already-recognised screen text.
//

import Foundation

/// A stretch of time spent in one app/window/page.
nonisolated struct BrainActivitySpan: Codable, Equatable, Sendable {
    var startDate: Date
    /// First sample time plus one sample interval: each sample stands for the
    /// minute that follows it.
    var endDate: Date
    var applicationName: String
    var bundleIdentifier: String
    var windowTitle: String?
    var domain: String?
    var url: String?
    var screenText: String?
    var sampleCount: Int

    var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }

    /// Whether a sample shows the same thing as this span.
    func showsSameActivity(as sample: BrainActivitySample) -> Bool {
        bundleIdentifier == sample.bundleIdentifier
            && windowTitle == sample.windowTitle
            && url == sample.url
    }
}

/// One day's spans. `dayKey` is "YYYY-MM-DD" in the user's calendar.
nonisolated struct BrainActivityDayLog: Codable, Equatable, Sendable {
    var dayKey: String
    var spans: [BrainActivitySpan]

    var sampleCount: Int { spans.reduce(0) { $0 + $1.sampleCount } }
}

// MARK: - Merging

nonisolated enum BrainActivitySpanMerger {
    /// Largest gap between a span's end and the next identical sample that
    /// still continues the span (timer jitter, a sample skipped while a call
    /// flickered). A longer gap means the user was away: a new span.
    static let continuationToleranceSeconds: TimeInterval = 45

    /// Adds a sample to a day's spans: extends the last span when the sample
    /// shows the same thing and follows on, otherwise starts a new one.
    static func appending(
        _ sample: BrainActivitySample,
        to spans: [BrainActivitySpan],
        sampleIntervalSeconds: TimeInterval
    ) -> [BrainActivitySpan] {
        var mergedSpans = spans
        let sampleEndDate = sample.date.addingTimeInterval(sampleIntervalSeconds)
        if var lastSpan = mergedSpans.last {
            let secondsAfterLastSpanEnded = sample.date.timeIntervalSince(lastSpan.endDate)
            if lastSpan.showsSameActivity(as: sample), secondsAfterLastSpanEnded <= continuationToleranceSeconds {
                lastSpan.endDate = max(lastSpan.endDate, sampleEndDate)
                lastSpan.sampleCount += 1
                // Keep the newest text excerpt: it describes the latest minute.
                if let screenText = sample.screenText { lastSpan.screenText = screenText }
                mergedSpans[mergedSpans.count - 1] = lastSpan
                return mergedSpans
            }
            // A different activity that started before the last span's
            // credited minute ran out: the last span ends where this begins.
            if secondsAfterLastSpanEnded < 0 {
                lastSpan.endDate = max(lastSpan.startDate, sample.date)
                mergedSpans[mergedSpans.count - 1] = lastSpan
            }
        }
        mergedSpans.append(BrainActivitySpan(
            startDate: sample.date,
            endDate: sampleEndDate,
            applicationName: sample.applicationName,
            bundleIdentifier: sample.bundleIdentifier,
            windowTitle: sample.windowTitle,
            domain: sample.domain,
            url: sample.url,
            screenText: sample.screenText,
            sampleCount: 1
        ))
        return mergedSpans
    }
}

// MARK: - Day keys

nonisolated enum BrainActivityDayKey {
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", dateComponents.year ?? 0, dateComponents.month ?? 0, dateComponents.day ?? 0)
    }

    /// The start of the day a key names, or nil for a malformed key.
    static func date(fromDayKey dayKey: String, calendar: Calendar = .current) -> Date? {
        let keyParts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard keyParts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: keyParts[0], month: keyParts[1], day: keyParts[2]))
    }

    /// Whether a file name is an activity log ("2026-09-29.md" / ".json").
    static func dayKey(fromFileName fileName: String) -> String? {
        let baseName = (fileName as NSString).deletingPathExtension
        let pathExtension = (fileName as NSString).pathExtension.lowercased()
        guard pathExtension == "md" || pathExtension == "json",
              baseName.count == 10,
              date(fromDayKey: baseName) != nil else { return nil }
        return baseName
    }

    /// Day keys older than `retentionDays` before `now`.
    static func isExpired(dayKey: String, now: Date, retentionDays: Int, calendar: Calendar = .current) -> Bool {
        guard let dayStartDate = date(fromDayKey: dayKey, calendar: calendar),
              let oldestKeptDayStart = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return dayStartDate < oldestKeptDayStart
    }
}

// MARK: - Markdown rendering

nonisolated enum BrainActivityLogMarkdown {
    /// The human-readable day file: one line per span, in time order.
    static func render(_ dayLog: BrainActivityDayLog, calendar: Calendar = .current) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        var lines = [
            "# Activity \(dayLog.dayKey)",
            "",
            "Recorded by Wisp's activity feed (Brain → Sources). Apps, window titles and sites only — no screenshots.",
            ""
        ]
        if dayLog.spans.isEmpty {
            lines.append("_Nothing recorded._")
        }
        for span in dayLog.spans {
            var line = "- \(timeFormatter.string(from: span.startDate))–\(timeFormatter.string(from: span.endDate)) · \(span.applicationName)"
            if let windowTitle = span.windowTitle, !windowTitle.isEmpty {
                line += " · \(singleLine(windowTitle))"
            }
            if let url = span.url {
                line += " — <\(url)>"
            } else if let domain = span.domain {
                line += " — \(domain)"
            }
            lines.append(line)
            if let screenText = span.screenText {
                lines.append("  > \(singleLine(screenText))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - Files

/// Reads and writes the per-day files under `raw/activity/`.
nonisolated struct BrainActivityLogFiles: Sendable {
    let activityFolderURL: URL

    func jsonFileURL(forDayKey dayKey: String) -> URL {
        activityFolderURL.appendingPathComponent(dayKey + ".json")
    }

    func markdownFileURL(forDayKey dayKey: String) -> URL {
        activityFolderURL.appendingPathComponent(dayKey + ".md")
    }

    func load(dayKey: String) -> BrainActivityDayLog? {
        guard let data = try? Data(contentsOf: jsonFileURL(forDayKey: dayKey)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BrainActivityDayLog.self, from: data)
    }

    func save(_ dayLog: BrainActivityDayLog) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: activityFolderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Owner-only: this is a record of what the user did all day.
        let ownerOnlyAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if let data = try? encoder.encode(dayLog) {
            let jsonFileURL = jsonFileURL(forDayKey: dayLog.dayKey)
            try? data.write(to: jsonFileURL, options: .atomic)
            try? fileManager.setAttributes(ownerOnlyAttributes, ofItemAtPath: jsonFileURL.path)
        }
        let markdownFileURL = markdownFileURL(forDayKey: dayLog.dayKey)
        try? BrainActivityLogMarkdown.render(dayLog).write(to: markdownFileURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes(ownerOnlyAttributes, ofItemAtPath: markdownFileURL.path)
    }

    /// Day keys that have a JSON log, oldest first.
    func recordedDayKeys() -> [String] {
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: activityFolderURL.path)) ?? []
        let jsonDayKeys = fileNames
            .filter { $0.lowercased().hasSuffix(".json") }
            .compactMap(BrainActivityDayKey.dayKey(fromFileName:))
        return Array(Set(jsonDayKeys)).sorted()
    }

    /// Deletes activity files older than the retention window.
    func deleteFiles(olderThanDays retentionDays: Int, now: Date) {
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: activityFolderURL.path)) ?? []
        for fileName in fileNames {
            guard let dayKey = BrainActivityDayKey.dayKey(fromFileName: fileName),
                  BrainActivityDayKey.isExpired(dayKey: dayKey, now: now, retentionDays: retentionDays) else { continue }
            try? FileManager.default.removeItem(at: activityFolderURL.appendingPathComponent(fileName))
        }
    }

    /// Deletes every activity log file (only files this feed wrote).
    func deleteAllFiles() {
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: activityFolderURL.path)) ?? []
        for fileName in fileNames where BrainActivityDayKey.dayKey(fromFileName: fileName) != nil {
            try? FileManager.default.removeItem(at: activityFolderURL.appendingPathComponent(fileName))
        }
    }
}
