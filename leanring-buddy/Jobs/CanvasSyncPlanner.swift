//
//  CanvasSyncPlanner.swift
//  leanring-buddy
//
//  Pure diff between the last snapshot and the freshly parsed feed. Keyed by
//  Canvas UID so that applying the same diff twice is a no-op downstream.
//

import Foundation

nonisolated enum CanvasSyncPlanner {
    /// `previous == nil` means this is the first sync: everything is "added".
    static func diff(previous: [CanvasItem]?, current: [CanvasItem]) -> CanvasDiff {
        let currentItemsByUID = itemsByUID(current)

        guard let previous else {
            return CanvasDiff(
                added: sorted(Array(currentItemsByUID.values)),
                changed: [],
                removed: [],
                unchangedCount: 0,
                isFirstSync: true
            )
        }

        let previousItemsByUID = itemsByUID(previous)

        var addedItems: [CanvasItem] = []
        var changes: [CanvasItemChange] = []
        var unchangedCount = 0

        for (uid, currentItem) in currentItemsByUID {
            guard let previousItem = previousItemsByUID[uid] else {
                addedItems.append(currentItem)
                continue
            }
            // Equal fingerprints mean every compared field is equal; skip the
            // field-by-field comparison for the common case.
            if previousItem.contentFingerprint == currentItem.contentFingerprint {
                unchangedCount += 1
                continue
            }
            let changedFields = changedFields(from: previousItem, to: currentItem)
            if changedFields.isEmpty {
                // Only a non-compared attribute (e.g. link) moved; nothing to write.
                unchangedCount += 1
            } else {
                changes.append(CanvasItemChange(before: previousItem, after: currentItem, changedFields: changedFields))
            }
        }

        let removedItems = previousItemsByUID
            .filter { currentItemsByUID[$0.key] == nil }
            .map { $0.value }

        return CanvasDiff(
            added: sorted(addedItems),
            changed: changes.sorted { orderedBefore($0.after, $1.after) },
            removed: sorted(removedItems),
            unchangedCount: unchangedCount,
            isFirstSync: false
        )
    }

    // MARK: - Helpers

    /// A feed can repeat a UID (override events); the last occurrence wins, matching the parser.
    private static func itemsByUID(_ items: [CanvasItem]) -> [String: CanvasItem] {
        var result: [String: CanvasItem] = [:]
        for item in items { result[item.uid] = item }
        return result
    }

    private static func changedFields(from before: CanvasItem, to after: CanvasItem) -> [CanvasItemChange.Field] {
        var fields: [CanvasItemChange.Field] = []
        if before.title != after.title { fields.append(.title) }
        if before.startDate != after.startDate { fields.append(.start) }
        if before.endDate != after.endDate { fields.append(.end) }
        if before.location != after.location { fields.append(.location) }
        if before.descriptionText != after.descriptionText { fields.append(.description) }
        if before.isAllDay != after.isAllDay { fields.append(.allDay) }
        return fields.sorted { $0.rawValue < $1.rawValue }
    }

    private static func sorted(_ items: [CanvasItem]) -> [CanvasItem] {
        items.sorted(by: orderedBefore)
    }

    private static func orderedBefore(_ first: CanvasItem, _ second: CanvasItem) -> Bool {
        if first.startDate != second.startDate { return first.startDate < second.startDate }
        return first.uid < second.uid
    }
}
