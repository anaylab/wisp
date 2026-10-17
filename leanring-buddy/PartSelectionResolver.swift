//
//  PartSelectionResolver.swift
//  leanring-buddy
//
//  Turns a spoken part ("the third answer", "option C", "step 2", the text
//  `x = 6`) into one rectangle in screenshot pixels, using only the OCR lines
//  Wisp already has for the turn (`ScreenTextSnapshotEntry`, each with an exact
//  box). Pure and model-free.
//
//  How a list is found: a line that starts like a list item (`A)`, `(b)`,
//  `2.`, `Step 3`, `•`) is a marker. A bare "A" that Vision read as its own line
//  counts too, with the answer text beside it joined on afterwards. Markers of
//  one kind that line up in a column (or along a row) and run in order make a
//  list; ordinals count over that list's markers top-to-bottom (left-to-right
//  for a row). Anything that leaves two readings open — two lists that both
//  fit, a label found twice, text on screen twice — resolves to NOTHING, so the
//  caller falls back to an ordinary model turn instead of selecting the wrong
//  part.
//
//  Tested by `Tests/PartSelection`.
//

import CoreGraphics
import Foundation

nonisolated struct PartSelectionResolvedRegion: Equatable {
    let regionInScreenshotPixels: CGRect
    /// 1-based, matching `ScreenTextSnapshotEntry.screenNumber`.
    let screenNumber: Int
}

nonisolated enum PartSelectionResolution: Equatable {
    case resolved(PartSelectionResolvedRegion)
    /// Nothing on screen fits the target.
    case notFound
    /// More than one place fits; guessing could select the wrong part.
    case ambiguous
}

/// How a list item begins.
nonisolated enum PartSelectionMarkerKind: Equatable, CaseIterable {
    case letter, number, step, bullet
}

nonisolated struct PartSelectionMarker: Equatable {
    let kind: PartSelectionMarkerKind
    /// Lowercase letter or digits; nil for a bullet.
    let label: String?
    let entry: ScreenTextSnapshotEntry
}

nonisolated enum PartSelectionResolver {
    /// A list needs at least this many markers; a lone "1." is not a list.
    static let minimumMarkersPerList = 2
    /// Markers in one column may drift by this many line heights.
    static let columnToleranceInLineHeights: CGFloat = 1.0
    /// Two markers further apart than this many line heights (top to top) are
    /// different lists.
    static let maximumGapBetweenListMarkersInLineHeights: CGFloat = 9
    /// A wrapped line belongs to its item when it starts within this many line
    /// heights below the item's last line.
    static let maximumContinuationGapInLineHeights: CGFloat = 0.8
    /// Words in a row of options (A. 4   B. 6) may be this far apart.
    static let maximumHorizontalGapInLineHeights: CGFloat = 3
    /// Shortest on-screen text accepted as a target.
    static let minimumTextTargetCharacterCount = 2
    /// Shortest target allowed to match part of a longer line.
    static let minimumContainedTextTargetCharacterCount = 3

    // MARK: Entry point

    static func resolve(
        _ target: PartSelectionTarget,
        in screenTextEntries: [ScreenTextSnapshotEntry]
    ) -> PartSelectionResolution {
        switch target {
        case .ordinalItem(let position, let noun):
            return resolveListItem(entries: screenTextEntries, noun: noun) { markersInList in
                switch position {
                case .last: return markersInList.indices.last
                case .index(let oneBasedIndex):
                    return markersInList.indices.contains(oneBasedIndex - 1) ? oneBasedIndex - 1 : nil
                }
            }
        case .labeledItem(let label, let noun):
            return resolveLabeledItem(label: label, noun: noun, entries: screenTextEntries)
        case .onScreenText(let text):
            return resolveOnScreenText(text, entries: screenTextEntries)
        }
    }

    // MARK: Marker detection

    /// Whether the line begins like a list item, and how.
    static func marker(for entry: ScreenTextSnapshotEntry) -> PartSelectionMarker? {
        let text = entry.text.trimmingCharacters(in: .whitespaces)
        func firstCapture(_ pattern: String, options: NSRegularExpression.Options = []) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captureRange])
        }

        // "Step 3: …" — before the plain number so "Step 3." reads as a step.
        if let stepNumber = firstCapture(#"^step\s*(\d{1,2})\b"#, options: .caseInsensitive) {
            return PartSelectionMarker(kind: .step, label: stepNumber, entry: entry)
        }
        // "A) text", "(A) text", "a. text" (a dot or colon needs a space, so
        // "e.g." and "A.I." are not markers).
        if let letter = firstCapture(#"^\(?([A-Ha-h])\)\s*\S"#) ?? firstCapture(#"^\(?([A-Ha-h])[\.:]\s+\S"#) {
            return PartSelectionMarker(kind: .letter, label: letter.lowercased(), entry: entry)
        }
        // A bare uppercase letter Vision read as its own line ("A"), or "(a)" / "A)" alone.
        if let letter = firstCapture(#"^([A-H])$"#) ?? firstCapture(#"^\(?([A-Ha-h])[\)\.:]$"#) ?? firstCapture(#"^\(([A-Ha-h])\)$"#) {
            return PartSelectionMarker(kind: .letter, label: letter.lowercased(), entry: entry)
        }
        // "2. Divide", "3) x", "(4) y" — but not "2.5 million".
        if let number = firstCapture(#"^(\d{1,2})[\.\)]\s+\S"#)
            ?? firstCapture(#"^\(?(\d{1,2})\)\s*\S"#)
            ?? firstCapture(#"^(\d{1,2})[\.\)]$"#) {
            return PartSelectionMarker(kind: .number, label: number, entry: entry)
        }
        // "• text", "- text".
        if text.range(of: #"^[•·▪◦‣∙●]\s*\S"#, options: .regularExpression) != nil
            || text.range(of: #"^[\-–—\*]\s+\S"#, options: .regularExpression) != nil {
            return PartSelectionMarker(kind: .bullet, label: nil, entry: entry)
        }
        return nil
    }

    // MARK: Lists

    private struct MarkerList {
        let kind: PartSelectionMarkerKind
        let screenNumber: Int
        /// In reading order: top to bottom, or left to right for a row.
        let markers: [PartSelectionMarker]
        let isHorizontalRow: Bool
    }

    private static func lineHeight(of marker: PartSelectionMarker) -> CGFloat {
        marker.entry.boundingBoxInScreenshotPixels.height
    }

    private static func detectLists(in entries: [ScreenTextSnapshotEntry]) -> [MarkerList] {
        let allMarkers = entries.compactMap { entry in marker(for: entry) }
        var lists: [MarkerList] = []
        let screenNumbers = Set(allMarkers.map(\.entry.screenNumber))

        for screenNumber in screenNumbers.sorted() {
            for kind in PartSelectionMarkerKind.allCases {
                let markers = allMarkers.filter { $0.entry.screenNumber == screenNumber && $0.kind == kind }
                guard markers.count >= minimumMarkersPerList else { continue }

                // Rows first: markers sharing one line of the screen, left to right.
                var markersLeftForColumns = markers
                var rowGroups: [[PartSelectionMarker]] = []
                for marker in markers.sorted(by: { $0.entry.boundingBoxInScreenshotPixels.minY < $1.entry.boundingBoxInScreenshotPixels.minY }) {
                    let markerBox = marker.entry.boundingBoxInScreenshotPixels
                    if let rowIndex = rowGroups.firstIndex(where: { rowGroup in
                        abs(rowGroup[0].entry.boundingBoxInScreenshotPixels.midY - markerBox.midY) <= markerBox.height * 0.5
                    }) {
                        rowGroups[rowIndex].append(marker)
                    } else {
                        rowGroups.append([marker])
                    }
                }
                for rowGroup in rowGroups where rowGroup.count >= minimumMarkersPerList {
                    let rowMarkers = rowGroup.sorted { $0.entry.boundingBoxInScreenshotPixels.minX < $1.entry.boundingBoxInScreenshotPixels.minX }
                    if isInOrder(rowMarkers) {
                        lists.append(MarkerList(kind: kind, screenNumber: screenNumber, markers: rowMarkers, isHorizontalRow: true))
                        markersLeftForColumns.removeAll { candidate in rowMarkers.contains(candidate) }
                    }
                }

                // Columns: each marker joins an open column that ends just above it.
                var openColumns: [[PartSelectionMarker]] = []
                for marker in markersLeftForColumns.sorted(by: { $0.entry.boundingBoxInScreenshotPixels.minY < $1.entry.boundingBoxInScreenshotPixels.minY }) {
                    let markerBox = marker.entry.boundingBoxInScreenshotPixels
                    let columnIndex = openColumns.firstIndex { column in
                        guard let columnBottomMarker = column.last else { return false }
                        let columnBox = columnBottomMarker.entry.boundingBoxInScreenshotPixels
                        return abs(columnBox.minX - markerBox.minX) <= max(8, markerBox.height * columnToleranceInLineHeights)
                            && markerBox.minY > columnBox.minY
                            && markerBox.minY - columnBox.minY <= max(40, markerBox.height * maximumGapBetweenListMarkersInLineHeights)
                    }
                    if let columnIndex { openColumns[columnIndex].append(marker) } else { openColumns.append([marker]) }
                }
                for column in openColumns where column.count >= minimumMarkersPerList && isInOrder(column) {
                    lists.append(MarkerList(kind: kind, screenNumber: screenNumber, markers: column, isHorizontalRow: false))
                }
            }
        }
        return lists
    }

    /// Letters and numbers must increase down the list; bullets have no order.
    private static func isInOrder(_ markers: [PartSelectionMarker]) -> Bool {
        guard markers[0].kind != .bullet else { return true }
        let labelValues = markers.map { marker -> Int in
            guard let label = marker.label else { return -1 }
            if let number = Int(label) { return number }
            return Int(label.unicodeScalars.first?.value ?? 0)
        }
        return zip(labelValues, labelValues.dropFirst()).allSatisfy { earlier, later in earlier < later }
    }

    /// Which kinds of list a noun can mean, most likely first. Only the first
    /// group that has any list is used, so "option" prefers lettered choices
    /// but still works on a numbered list when there are none.
    private static func markerKindPreference(for noun: PartSelectionNoun) -> [[PartSelectionMarkerKind]] {
        switch noun {
        case .answer, .option, .choice: return [[.letter], [.number], [.bullet]]
        case .step: return [[.step], [.number]]
        case .bullet: return [[.bullet]]
        case .item, .line, .row: return [[.number, .letter, .bullet, .step]]
        }
    }

    private static func resolveListItem(
        entries: [ScreenTextSnapshotEntry],
        noun: PartSelectionNoun,
        chooseIndex: ([PartSelectionMarker]) -> Int?
    ) -> PartSelectionResolution {
        let lists = detectLists(in: entries)
        for kindGroup in markerKindPreference(for: noun) {
            let listsOfGroup = lists.filter { kindGroup.contains($0.kind) }
            if listsOfGroup.isEmpty { continue }
            guard listsOfGroup.count == 1 else { return .ambiguous }
            let list = listsOfGroup[0]
            guard let chosenIndex = chooseIndex(list.markers) else { return .notFound }
            return .resolved(region(ofItemAt: chosenIndex, in: list, allEntries: entries, allLists: lists))
        }
        return .notFound
    }

    private static func resolveLabeledItem(
        label: String,
        noun: PartSelectionNoun,
        entries: [ScreenTextSnapshotEntry]
    ) -> PartSelectionResolution {
        let lists = detectLists(in: entries)
        for kindGroup in markerKindPreference(for: noun) {
            let labelMatches: [(list: MarkerList, index: Int)] = lists
                .filter { kindGroup.contains($0.kind) }
                .compactMap { list in
                    list.markers.firstIndex(where: { $0.label == label }).map { (list, $0) }
                }
            if labelMatches.isEmpty { continue }
            guard labelMatches.count == 1 else { return .ambiguous }
            return .resolved(region(ofItemAt: labelMatches[0].index, in: labelMatches[0].list, allEntries: entries, allLists: lists))
        }
        return .notFound
    }

    /// The item's marker, the answer text beside it, and any wrapped lines
    /// under it up to the next item.
    private static func region(
        ofItemAt itemIndex: Int,
        in list: MarkerList,
        allEntries: [ScreenTextSnapshotEntry],
        allLists: [MarkerList]
    ) -> PartSelectionResolvedRegion {
        let marker = list.markers[itemIndex]
        let markerBox = marker.entry.boundingBoxInScreenshotPixels
        let markerLineHeight = markerBox.height
        let nextMarkerBox = itemIndex + 1 < list.markers.count
            ? list.markers[itemIndex + 1].entry.boundingBoxInScreenshotPixels
            : nil

        // Lines that start a different item of any list never belong to this one.
        let otherMarkerLineIDs = Set(allLists.flatMap { $0.markers.map(\.entry.lineID) })
            .subtracting([marker.entry.lineID])
        let candidateLines = allEntries.filter {
            $0.screenNumber == list.screenNumber
                && $0.lineID != marker.entry.lineID
                && !otherMarkerLineIDs.contains($0.lineID)
        }

        var itemRect = markerBox

        // Text on the marker's own row to its right ("A" … "Paris"). In a row of
        // options it stops at the next option.
        let sameRowLines = candidateLines
            .filter { line in
                let box = line.boundingBoxInScreenshotPixels
                return box.minX >= markerBox.maxX - 2
                    && abs(box.midY - markerBox.midY) <= markerLineHeight * 0.6
                    && (!list.isHorizontalRow || nextMarkerBox == nil || box.minX < nextMarkerBox!.minX)
            }
            .sorted { $0.boundingBoxInScreenshotPixels.minX < $1.boundingBoxInScreenshotPixels.minX }
        for line in sameRowLines {
            let box = line.boundingBoxInScreenshotPixels
            guard box.minX - itemRect.maxX <= markerLineHeight * maximumHorizontalGapInLineHeights else { break }
            itemRect = itemRect.union(box)
        }

        // Wrapped lines below, in a column list: indented at least as far as the
        // marker, close under the last line, above the next item.
        if !list.isHorizontalRow {
            var didExtend = true
            while didExtend {
                didExtend = false
                for line in candidateLines {
                    let box = line.boundingBoxInScreenshotPixels
                    guard !itemRect.contains(box),
                          box.minY >= itemRect.maxY - markerLineHeight * 0.5,
                          box.minY - itemRect.maxY <= markerLineHeight * maximumContinuationGapInLineHeights,
                          box.minX >= markerBox.minX - markerLineHeight,
                          nextMarkerBox == nil || box.minY < nextMarkerBox!.minY - 1 else { continue }
                    itemRect = itemRect.union(box)
                    didExtend = true
                }
            }
        }
        return PartSelectionResolvedRegion(regionInScreenshotPixels: itemRect, screenNumber: list.screenNumber)
    }

    // MARK: On-screen text

    /// Lowercase with spaces and sentence punctuation removed, so "x = 6",
    /// "X=6" and "x =6." compare equal. Operators are kept: they are the point.
    static func squashedForComparison(_ text: String) -> String {
        let removedCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;:!?\"'“”‘’"))
        return String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { !removedCharacters.contains($0) }))
    }

    private static func resolveOnScreenText(_ text: String, entries: [ScreenTextSnapshotEntry]) -> PartSelectionResolution {
        let squashedTarget = squashedForComparison(text)
        guard squashedTarget.count >= minimumTextTargetCharacterCount else { return .notFound }

        let exactMatches = entries.filter { squashedForComparison($0.text) == squashedTarget }
        let containingMatches = squashedTarget.count >= minimumContainedTextTargetCharacterCount
            ? entries.filter { squashedForComparison($0.text).contains(squashedTarget) }
            : []
        var matchingEntries = exactMatches.isEmpty ? containingMatches : exactMatches

        if matchingEntries.isEmpty {
            // Tolerant fallback: the same word matcher fast pointing uses (plurals,
            // one letter of OCR error). It must land on exactly one place.
            let candidates = entries.map { entry in
                PointingCandidate(
                    elementID: entry.lineID,
                    text: entry.text,
                    accessibilityRoleName: nil,
                    regionInScreenshotPixels: entry.boundingBoxInScreenshotPixels,
                    screenNumber: entry.screenNumber
                )
            }
            let places = PointingTargetMatcher.bestPlaces(
                for: PointingRequest(targetText: text, roleHint: nil),
                among: candidates,
                maximumPlaceCount: 2
            )
            matchingEntries = places.compactMap { place in entries.first { $0.lineID == place.candidate.elementID } }
        }

        guard !matchingEntries.isEmpty else { return .notFound }
        // Two matching lines are one place only when they are the same text seen twice.
        let distinctPlaces = matchingEntries.reduce(into: [ScreenTextSnapshotEntry]()) { kept, entry in
            let entryCandidate = pointingCandidate(for: entry)
            if !kept.contains(where: { PointingTargetMatcher.isSamePlace(pointingCandidate(for: $0), entryCandidate) }) {
                kept.append(entry)
            }
        }
        guard distinctPlaces.count == 1, let onlyPlace = distinctPlaces.first else { return .ambiguous }
        return .resolved(PartSelectionResolvedRegion(
            regionInScreenshotPixels: onlyPlace.boundingBoxInScreenshotPixels,
            screenNumber: onlyPlace.screenNumber
        ))
    }

    private static func pointingCandidate(for entry: ScreenTextSnapshotEntry) -> PointingCandidate {
        PointingCandidate(
            elementID: entry.lineID,
            text: entry.text,
            accessibilityRoleName: nil,
            regionInScreenshotPixels: entry.boundingBoxInScreenshotPixels,
            screenNumber: entry.screenNumber
        )
    }
}
