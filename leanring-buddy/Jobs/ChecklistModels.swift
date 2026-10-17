//
//  ChecklistModels.swift
//  leanring-buddy
//
//  Value types shared by the daily checklist (Job 2) and the two EventKit
//  writers. Foundation only, so the swiftc suite in Tests/DayChecklist can
//  compile this file without the rest of the app.
//
//  Everything is marked `nonisolated` because the app builds with main-actor
//  default isolation, and these types are used from the EventKit actors.
//

import Foundation

/// One row of the "Wisp Today" checklist.
nonisolated struct ChecklistItem: Identifiable, Equatable, Codable, Sendable {
    enum Origin: String, Codable, Sendable {
        case canvasDue
        case calendarEvent
        case studyBlock
        case rolledOver
    }

    /// Stable job-item key: "<origin>:<sourceUID>:<yyyyMMdd>". It is the key of the
    /// Reminders map, so two builds for the same input must produce the same id.
    let id: String
    let title: String
    /// "ENGL101 · due 11:59 PM"
    let subtitle: String?
    let dueDate: Date?
    let origin: Origin
    /// 0 for new items.
    let rolloverCount: Int
    var isCompleted: Bool
    var completionDate: Date?
}

/// A calendar event reduced to what the checklist needs, so the builder stays
/// free of EventKit.
nonisolated struct ChecklistCalendarEvent: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

nonisolated enum WispEventKitError: Error, Equatable, Sendable {
    case accessDenied
    case noWritableSource
    case calendarMissing
    case itemMissing
}

nonisolated enum JobsAccessState: String, Sendable {
    case notDetermined
    case granted
    case denied
}

/// Small helper for the 0600 JSON files the Jobs writers keep in
/// `~/Library/Application Support/Wisp/`. They hold identifiers and titles of
/// the user's own calendar and reminders, so they are owner-only.
nonisolated enum JobsPrivateJSONFile {
    static func fileURL(named fileName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wisp/\(fileName)")
    }

    /// Returns nil when the file is missing or unreadable; callers then rebuild
    /// the map from the stamps they left in the events / reminders.
    static func load<Value: Decodable>(_ valueType: Value.Type, from fileURL: URL) -> Value? {
        guard let fileData = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(valueType, from: fileData)
    }

    static func save<Value: Encodable>(_ value: Value, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedData = try encoder.encode(value)
        try encodedData.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
