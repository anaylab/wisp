//
//  CanvasDiffCardView.swift
//  leanring-buddy
//
//  The one-line "what changed in Canvas" card the notch shows after a sync that
//  actually changed something ("2 new assignments, 1 moved"). A quiet sync never
//  reaches this view. Island styling only (WispColor.Island.*).
//

import SwiftUI

/// Words for a Canvas diff, kept apart from the view so the wording is one place.
enum CanvasDiffCardText {
    /// "2 new assignments, 1 moved" / "Added 34 Canvas items to Wisp".
    static func line(for diff: CanvasDiff) -> String {
        if diff.isFirstSync {
            let itemCount = diff.added.count
            return "Added \(itemCount) Canvas \(itemCount == 1 ? "item" : "items") to Wisp"
        }

        var parts: [String] = []
        if !diff.added.isEmpty {
            // Say "assignments" only when that is all that arrived; a mixed batch
            // would otherwise be mislabelled.
            let allAssignments = diff.added.allSatisfy { $0.kind == .assignment }
            let noun = allAssignments ? "assignment" : "item"
            parts.append("\(diff.added.count) new \(noun)\(diff.added.count == 1 ? "" : "s")")
        }

        let timeFields: Set<CanvasItemChange.Field> = [.start, .end, .allDay]
        let movedCount = diff.changed.filter { !timeFields.isDisjoint(with: $0.changedFields) }.count
        let editedCount = diff.changed.count - movedCount
        if movedCount > 0 { parts.append("\(movedCount) moved") }
        if editedCount > 0 { parts.append("\(editedCount) updated") }
        if !diff.removed.isEmpty { parts.append("\(diff.removed.count) removed") }

        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

struct CanvasDiffCardView: View {
    let diff: CanvasDiff
    let proposedStudyBlockCount: Int
    let onDismiss: () -> Void
    /// Opens the single study-block approval card.
    let onReviewStudyBlocks: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WispColor.Brand.lavender)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(CanvasDiffCardText.line(for: diff))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("Canvas · updated your Wisp calendar")
                    .font(.system(size: 10.5))
                    .foregroundColor(WispColor.Island.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if proposedStudyBlockCount > 0 {
                Button(action: onReviewStudyBlocks) {
                    Text(proposedStudyBlockCount == 1 ? "1 study block" : "\(proposedStudyBlockCount) study blocks")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .wispIslandButtonStyle(prominence: .prominent)
                .pointerCursor()
                .nativeTooltip("Review the study blocks Wisp suggests. Nothing is added until you approve.")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(WispColor.Island.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Dismiss")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(WispColor.Brand.lavender.opacity(0.10))
        )
    }
}
