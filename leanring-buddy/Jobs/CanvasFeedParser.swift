//
//  CanvasFeedParser.swift
//  leanring-buddy
//
//  Turns the text of a Canvas calendar feed (.ics) into `CanvasItem`s.
//  Never throws: a malformed VEVENT is skipped and counted, so one odd entry
//  can't stop a whole sync. Pure Foundation, deterministic.
//

import Foundation

nonisolated enum CanvasFeedParser {
    /// Descriptions can be whole assignment pages; cap them so the snapshot stays small.
    private static let maximumDescriptionLength = 4000

    static func parse(icsText: String, now: Date, calendar: Calendar) -> [CanvasItem] {
        parseReportingSkips(icsText: icsText, now: now, calendar: calendar).items
    }

    /// `skippedEventCount` counts events that were malformed (no UID, no usable
    /// DTSTART) plus earlier duplicates of a repeated UID that were superseded.
    static func parseReportingSkips(icsText: String, now: Date, calendar: Calendar) -> (items: [CanvasItem], skippedEventCount: Int) {
        // `now` is part of the contract so future rules (e.g. dropping very old
        // items) don't change the signature; the parse itself is time-independent.
        _ = now

        var skippedEventCount = 0
        var itemsByUID: [String: CanvasItem] = [:]

        for eventProperties in eventPropertyLists(fromICS: icsText) {
            guard let item = makeItem(from: eventProperties, calendar: calendar) else {
                skippedEventCount += 1
                continue
            }
            if itemsByUID[item.uid] != nil { skippedEventCount += 1 }
            itemsByUID[item.uid] = item
        }

        let sortedItems = itemsByUID.values.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.uid < $1.uid
        }
        return (sortedItems, skippedEventCount)
    }

    // MARK: - Lines and properties

    private struct ICSProperty {
        let name: String                 // upper-cased
        let parameters: [String: String] // upper-cased keys, quotes stripped
        let value: String                // raw, still escaped
    }

    /// RFC 5545 line folding: a line starting with space or tab continues the previous one.
    static func unfoldedLines(from icsText: String) -> [String] {
        let normalizedText = icsText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var logicalLines: [String] = []
        for physicalLine in normalizedText.components(separatedBy: "\n") {
            if let firstCharacter = physicalLine.first, (firstCharacter == " " || firstCharacter == "\t"), !logicalLines.isEmpty {
                logicalLines[logicalLines.count - 1] += String(physicalLine.dropFirst())
            } else {
                logicalLines.append(physicalLine)
            }
        }
        return logicalLines
    }

    /// One property list per VEVENT. Properties of nested components (VALARM)
    /// are dropped because they reuse names like DESCRIPTION.
    private static func eventPropertyLists(fromICS icsText: String) -> [[ICSProperty]] {
        var events: [[ICSProperty]] = []
        var currentEvent: [ICSProperty]?
        var nestedComponentDepth = 0

        for line in unfoldedLines(from: icsText) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let upperLine = trimmedLine.uppercased()

            if upperLine == "BEGIN:VEVENT" {
                currentEvent = []
                nestedComponentDepth = 0
                continue
            }
            if upperLine == "END:VEVENT" {
                if let finishedEvent = currentEvent { events.append(finishedEvent) }
                currentEvent = nil
                continue
            }
            guard currentEvent != nil else { continue }

            if upperLine.hasPrefix("BEGIN:") { nestedComponentDepth += 1; continue }
            if upperLine.hasPrefix("END:") { nestedComponentDepth = max(0, nestedComponentDepth - 1); continue }
            if nestedComponentDepth > 0 { continue }

            if let property = parseProperty(line: trimmedLine) {
                currentEvent?.append(property)
            }
        }
        return events
    }

    private static func parseProperty(line: String) -> ICSProperty? {
        // The first ':' outside double quotes separates name+params from the value.
        var isInsideQuotes = false
        var separatorIndex: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" { isInsideQuotes.toggle() }
            else if character == ":" && !isInsideQuotes { separatorIndex = index; break }
            index = line.index(after: index)
        }
        guard let separatorIndex else { return nil }

        let nameAndParameters = String(line[line.startIndex..<separatorIndex])
        let value = String(line[line.index(after: separatorIndex)...])

        let segments = nameAndParameters.components(separatedBy: ";")
        guard let rawName = segments.first, !rawName.isEmpty else { return nil }

        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let equalsIndex = segment.firstIndex(of: "=") else { continue }
            let key = segment[segment.startIndex..<equalsIndex].uppercased()
            let parameterValue = segment[segment.index(after: equalsIndex)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parameters[key] = parameterValue
        }
        return ICSProperty(name: rawName.uppercased(), parameters: parameters, value: value)
    }

    // MARK: - Event to item

    private static func makeItem(from properties: [ICSProperty], calendar: Calendar) -> CanvasItem? {
        // Last occurrence wins for a repeated property.
        func property(_ name: String) -> ICSProperty? { properties.last { $0.name == name } }

        guard let uidProperty = property("UID") else { return nil }
        let uid = uidProperty.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return nil }

        guard let startProperty = property("DTSTART"),
              let parsedStart = parseDateValue(startProperty, calendar: calendar) else { return nil }

        let startDate = parsedStart.date
        let isAllDay = parsedStart.isAllDay

        var endDate: Date?
        if let endProperty = property("DTEND"), let parsedEnd = parseDateValue(endProperty, calendar: calendar) {
            endDate = parsedEnd.date
        }
        if let candidateEnd = endDate {
            let isSameAsStart = candidateEnd <= startDate
            // An all-day DTEND is exclusive, so "next day" just means a single day.
            let isSingleDayAllDay = isAllDay && calendar.date(byAdding: .day, value: 1, to: startDate) == candidateEnd
            if isSameAsStart || isSingleDayAllDay { endDate = nil }
        }

        let rawSummary = unescapedText(property("SUMMARY")?.value ?? "")
        let (title, courseCode) = splitTitleAndCourseCode(rawSummary)

        let location = nonEmpty(unescapedText(property("LOCATION")?.value ?? ""))
        var descriptionText = nonEmpty(unescapedText(property("DESCRIPTION")?.value ?? ""))
        if let fullDescription = descriptionText, fullDescription.count > maximumDescriptionLength {
            descriptionText = String(fullDescription.prefix(maximumDescriptionLength))
        }
        let linkURLString = nonEmpty(property("URL")?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")

        return CanvasItem(
            uid: uid,
            title: title,
            courseCode: courseCode,
            kind: kind(forUID: uid),
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            descriptionText: descriptionText,
            linkURLString: linkURLString,
            contentFingerprint: fingerprint(title: title, start: startDate, end: endDate, isAllDay: isAllDay, location: location, description: descriptionText)
        )
    }

    private static func kind(forUID uid: String) -> CanvasItem.Kind {
        let lowercasedUID = uid.lowercased()
        if lowercasedUID.hasPrefix("event-assignment") { return .assignment }
        if lowercasedUID.hasPrefix("event-quiz") { return .quiz }
        if lowercasedUID.hasPrefix("event-calendar-event") { return .calendarEvent }
        return .other
    }

    /// "Essay [draft] 2 [ENGL101]" -> ("Essay [draft] 2", "ENGL101"). Only the final bracket group counts.
    private static func splitTitleAndCourseCode(_ summary: String) -> (title: String, courseCode: String?) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSummary.hasSuffix("]"),
              let openingBracketIndex = trimmedSummary.lastIndex(of: "[") else {
            return (trimmedSummary, nil)
        }
        let code = trimmedSummary[trimmedSummary.index(after: openingBracketIndex)..<trimmedSummary.index(before: trimmedSummary.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        let titlePart = trimmedSummary[trimmedSummary.startIndex..<openingBracketIndex]
            .trimmingCharacters(in: .whitespaces)
        // "[ENGL101]" alone, or an empty/nested code, is not a trailing course tag.
        guard !titlePart.isEmpty, !code.isEmpty, !code.contains("[") , !code.contains("]") else {
            return (trimmedSummary, nil)
        }
        return (titlePart, code)
    }

    // MARK: - Dates

    private static func parseDateValue(_ property: ICSProperty, calendar: Calendar) -> (date: Date, isAllDay: Bool)? {
        let text = property.value.trimmingCharacters(in: .whitespaces)
        let isDateOnly = property.parameters["VALUE"]?.uppercased() == "DATE" || (text.count == 8 && !text.contains("T"))

        if isDateOnly {
            guard text.count == 8, let components = dateComponents(fromDigits: text.prefix(8)) else { return nil }
            guard let date = calendar.date(from: components) else { return nil }
            return (date, true)
        }

        // yyyyMMddTHHmmss with an optional trailing Z.
        let isUTC = text.hasSuffix("Z")
        let body = isUTC ? String(text.dropLast()) : text
        let halves = body.components(separatedBy: "T")
        guard halves.count == 2, halves[0].count == 8, halves[1].count == 6,
              var components = dateComponents(fromDigits: halves[0][...]),
              let hour = Int(halves[1].prefix(2)),
              let minute = Int(halves[1].dropFirst(2).prefix(2)),
              let second = Int(halves[1].dropFirst(4).prefix(2)),
              hour <= 23, minute <= 59, second <= 60 else { return nil }
        components.hour = hour
        components.minute = minute
        components.second = min(second, 59)

        var zonedCalendar = calendar
        if isUTC {
            zonedCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        } else if let timeZoneIdentifier = property.parameters["TZID"], let namedTimeZone = TimeZone(identifier: timeZoneIdentifier) {
            zonedCalendar.timeZone = namedTimeZone
        }
        // No Z and no known TZID is a floating time: read it in the user's zone.
        guard let date = zonedCalendar.date(from: components) else { return nil }
        return (date, false)
    }

    private static func dateComponents(fromDigits digits: Substring) -> DateComponents? {
        guard digits.count == 8,
              let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)),
              (1...12).contains(month), (1...31).contains(day), year > 1900 else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    // MARK: - Text

    /// Decodes RFC 5545 TEXT escapes: \n \N \, \; \\.
    private static func unescapedText(_ rawText: String) -> String {
        guard rawText.contains("\\") else { return rawText }
        var result = ""
        var isEscaping = false
        for character in rawText {
            if isEscaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        if isEscaping { result.append("\\") }
        return result
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    // MARK: - Fingerprint

    /// FNV-1a 64 over a fixed field order. Hand-rolled because `hashValue` is
    /// randomised per process and the fingerprint is persisted.
    private static func fingerprint(title: String, start: Date, end: Date?, isAllDay: Bool, location: String?, description: String?) -> String {
        let endText = end.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        let joined = [title, String(Int(start.timeIntervalSince1970)), endText, isAllDay ? "1" : "0", location ?? "", description ?? ""]
            .joined(separator: "|")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
