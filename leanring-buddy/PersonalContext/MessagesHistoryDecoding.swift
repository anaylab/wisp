//
//  MessagesHistoryDecoding.swift
//  leanring-buddy
//
//  Pure helpers for reading the Messages history database
//  (`~/Library/Messages/chat.db`) for personal context, kept apart from the
//  SQLite reading so they're testable without the database
//  (`Tests/PersonalContext`):
//
//  • `plainText(fromAttributedBody:)` — recent macOS versions often leave the
//    `text` column empty and store the message only in `attributedBody`, an
//    `NSAttributedString` archived as a "typedstream". The text is the first
//    NSString in it: the bytes after `NSString`, a `+` (0x2B) marker and a
//    length (one byte, or 0x81 followed by a two-byte little-endian length).
//  • `date(fromMessagesTimestamp:)` — Messages counts from 2001-01-01, in
//    nanoseconds on current systems and seconds on old ones.
//  • `normalizedHandle(_:)` — phone numbers compared by their last ten digits
//    and emails lowercased, so a handle can be matched to a contact's name.
//

import Foundation

nonisolated enum MessagesHistoryDecoding {

    static func plainText(fromAttributedBody attributedBodyBytes: Data) -> String? {
        let bodyBytes = [UInt8](attributedBodyBytes)
        let classNameMarker = Array("NSString".utf8)
        guard let classNameRange = firstRange(of: classNameMarker, in: bodyBytes) else { return nil }

        // The '+' that starts the string's bytes follows within a few bytes.
        var searchIndex = classNameRange.upperBound
        let searchLimit = min(bodyBytes.count, searchIndex + 12)
        while searchIndex < searchLimit, bodyBytes[searchIndex] != 0x2B { searchIndex += 1 }
        guard searchIndex < searchLimit else { return nil }

        var lengthIndex = searchIndex + 1
        guard lengthIndex < bodyBytes.count else { return nil }
        let textLength: Int
        if bodyBytes[lengthIndex] == 0x81 {
            guard lengthIndex + 2 < bodyBytes.count else { return nil }
            textLength = Int(bodyBytes[lengthIndex + 1]) | (Int(bodyBytes[lengthIndex + 2]) << 8)
            lengthIndex += 3
        } else if bodyBytes[lengthIndex] == 0x82 {
            guard lengthIndex + 4 < bodyBytes.count else { return nil }
            textLength = Int(bodyBytes[lengthIndex + 1]) | (Int(bodyBytes[lengthIndex + 2]) << 8)
                | (Int(bodyBytes[lengthIndex + 3]) << 16) | (Int(bodyBytes[lengthIndex + 4]) << 24)
            lengthIndex += 5
        } else {
            textLength = Int(bodyBytes[lengthIndex])
            lengthIndex += 1
        }
        guard textLength > 0, lengthIndex + textLength <= bodyBytes.count else { return nil }
        return String(bytes: bodyBytes[lengthIndex..<(lengthIndex + textLength)], encoding: .utf8)
    }

    /// Seconds since 2001 before macOS 10.13, nanoseconds after.
    static func date(fromMessagesTimestamp messagesTimestamp: Int64) -> Date {
        let secondsSinceReferenceDate = messagesTimestamp > 1_000_000_000_000
            ? Double(messagesTimestamp) / 1_000_000_000
            : Double(messagesTimestamp)
        return Date(timeIntervalSinceReferenceDate: secondsSinceReferenceDate)
    }

    /// "+1 (555) 010-2030" → "5550102030"; "Sam@Example.com" → "sam@example.com".
    static func normalizedHandle(_ rawHandle: String) -> String {
        if rawHandle.contains("@") {
            return rawHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let digits = rawHandle.filter(\.isNumber)
        return String(digits.suffix(10))
    }

    private static func firstRange(of marker: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
        guard marker.count <= bytes.count else { return nil }
        for startIndex in 0...(bytes.count - marker.count) where bytes[startIndex] == marker[0] {
            if Array(bytes[startIndex..<(startIndex + marker.count)]) == marker {
                return startIndex..<(startIndex + marker.count)
            }
        }
        return nil
    }
}
