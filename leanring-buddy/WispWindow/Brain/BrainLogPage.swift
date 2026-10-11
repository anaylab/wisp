//
//  BrainLogPage.swift
//  leanring-buddy
//
//  Brain → Log: every change made to the brain, newest first — who made it
//  (you, a conversation digest, the inbox, a notes import, screen activity,
//  the agent), how far its source can be trusted, what it changed, and what
//  the planner refused. Each change can be undone; if a page was edited after
//  the change, undoing would lose that edit, so Wisp says which pages and asks
//  before forcing it.
//

import SwiftUI

struct BrainLogPage: View {
    @ObservedObject private var brainStore = BrainStore.shared

    @State private var originFilter: BrainEditProvenance.Origin?
    /// A change whose undo hit pages edited since, awaiting "Undo anyway".
    @State private var conflictedUndo: (changeID: UUID, pageTitles: [String])?
    @State private var undoFeedback: String?

    private var visibleRecords: [BrainChangeRecord] {
        brainStore.changeRecords.filter { record in
            originFilter.map { record.provenance.origin == $0 } ?? true
        }
    }

    private var visibleRecordsByDay: [(dayTitle: String, records: [BrainChangeRecord])] {
        var dayGroups: [(dayTitle: String, records: [BrainChangeRecord])] = []
        for record in visibleRecords {
            let dayTitle = Self.dayTitle(for: record.date)
            if dayGroups.last?.dayTitle == dayTitle {
                dayGroups[dayGroups.count - 1].records.append(record)
            } else {
                dayGroups.append((dayTitle: dayTitle, records: [record]))
            }
        }
        return dayGroups
    }

    private static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if brainStore.changeRecords.isEmpty {
                ContentUnavailableView {
                    Label("No changes yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Every change to your brain, with where it came from. Undo any of them.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRecords.isEmpty {
                ContentUnavailableView {
                    Label("Nothing from \(originFilter.map(BrainOriginStyle.displayName(for:)) ?? "here")", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No changes came from this source.")
                } actions: {
                    Button("Show All") { originFilter = nil }
                        .pointerCursor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                        ForEach(visibleRecordsByDay, id: \.dayTitle) { dayGroup in
                            Section {
                                ForEach(dayGroup.records) { record in
                                    BrainChangeRecordRow(record: record, onUndo: { undo(record, force: false) })
                                }
                            } header: {
                                Text(dayGroup.dayTitle.uppercased())
                                    .font(WispFont.overline)
                                    .tracking(0.6)
                                    .foregroundStyle(WispColor.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(WispColor.windowBackground)
                            }
                        }
                    }
                    .padding(.horizontal, WispSpacing.xxl)
                    .padding(.vertical, WispSpacing.lg)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(WispColor.windowBackground)
        .alert(
            "Pages changed since",
            isPresented: Binding(
                get: { conflictedUndo != nil },
                set: { isPresented in if !isPresented { conflictedUndo = nil } }
            )
        ) {
            Button("Undo Anyway", role: .destructive) {
                if let conflictedUndo {
                    finishUndo(outcome: brainStore.undo(changeID: conflictedUndo.changeID, force: true))
                }
                conflictedUndo = nil
            }
            Button("Cancel", role: .cancel) { conflictedUndo = nil }
        } message: {
            Text("\(conflictedUndo?.pageTitles.joined(separator: ", ") ?? "Some pages") changed after this. Undoing puts them back the way they were before it, and the later edits are lost.")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("From", selection: $originFilter) {
                Text("Everything").tag(BrainEditProvenance.Origin?.none)
                Divider()
                ForEach(BrainOriginStyle.allOrigins, id: \.self) { origin in
                    Label(BrainOriginStyle.displayName(for: origin), systemImage: BrainOriginStyle.symbolName(for: origin))
                        .tag(Optional(origin))
                }
            }
            .fixedSize()
            .pointerCursor()
            if let undoFeedback {
                Text(undoFeedback)
                    .font(.caption)
                    .foregroundStyle(WispColor.textSecondary)
                    .transition(.opacity)
            }
            Spacer()
            Text("\(visibleRecords.count) \(visibleRecords.count == 1 ? "change" : "changes")")
                .font(.caption)
                .foregroundStyle(WispColor.textTertiary)
            Button("Open log.md") { NSWorkspace.shared.open(brainStore.logFileURL) }
                .buttonStyle(.link)
                .pointerCursor()
                .help("The same record as a markdown file in the vault")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func undo(_ record: BrainChangeRecord, force: Bool) {
        let outcome = brainStore.undo(changeID: record.id, force: force)
        if case .conflicted(let pageTitles) = outcome {
            conflictedUndo = (changeID: record.id, pageTitles: pageTitles)
            return
        }
        finishUndo(outcome: outcome)
    }

    private func finishUndo(outcome: BrainUndoOutcome) {
        let feedback: String
        switch outcome {
        case .undone: feedback = "Undone."
        case .alreadyUndone: feedback = "That change was already undone."
        case .notFound: feedback = "That change is too old to undo."
        case .conflicted: feedback = "Not undone."
        }
        withAnimation { undoFeedback = feedback }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation { if undoFeedback == feedback { undoFeedback = nil } }
        }
    }
}

// MARK: - Row

private struct BrainChangeRecordRow: View {
    let record: BrainChangeRecord
    let onUndo: () -> Void

    @ObservedObject private var brainStore = BrainStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: BrainOriginStyle.symbolName(for: record.provenance.origin))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(record.isUndone ? WispColor.textTertiary : WispColor.accentText)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(record.isUndone ? WispColor.surface2 : WispColor.accentSubtle)
                )
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.provenance.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(record.isUndone ? WispColor.textTertiary : WispColor.textPrimary)
                        .strikethrough(record.isUndone, color: WispColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    BrainChip(
                        text: BrainOriginStyle.trustLabel(for: record.provenance.trust),
                        tint: BrainOriginStyle.trustColor(for: record.provenance.trust)
                    )
                    .help(BrainOriginStyle.trustExplanation(for: record.provenance.trust))
                    if record.isUndone {
                        BrainChip(text: "Undone", symbolName: "arrow.uturn.backward", tint: WispColor.textTertiary)
                    }
                    Spacer(minLength: 6)
                    Text(record.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(WispColor.textTertiary)
                }
                Text(BrainOriginStyle.displayName(for: record.provenance.origin))
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(record.changeDescriptions.enumerated()), id: \.offset) { _, changeDescription in
                        Text("• \(changeDescription)")
                            .font(.callout)
                            .foregroundStyle(record.isUndone ? WispColor.textTertiary : WispColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(record.refusals.enumerated()), id: \.offset) { _, refusal in
                        Label(refusal, systemImage: "hand.raised")
                            .font(.caption)
                            .foregroundStyle(WispColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help("The planner refused this part of the change")
                    }
                }

                touchedPagesRow
            }
            if !record.isUndone {
                Button("Undo", action: onUndo)
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .pointerCursor()
                    .help("Put the pages back the way they were before this change")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(WispColor.groupedCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
        )
    }

    /// Created and modified pages that still exist, as links; deleted ones as text.
    @ViewBuilder
    private var touchedPagesRow: some View {
        let existingTouchedPages = (record.createdSlugs + record.modifiedSlugs).compactMap { touchedSlug in
            brainStore.pages.first { $0.slug == touchedSlug }
        }
        if !existingTouchedPages.isEmpty || !record.deletedSlugs.isEmpty {
            BrainFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(existingTouchedPages) { touchedPage in
                    BrainPageLinkChip(title: touchedPage.title, kind: touchedPage.kind) {
                        BrainNavigator.openPageInWindow(slug: touchedPage.slug)
                    }
                }
                ForEach(record.deletedSlugs, id: \.self) { deletedSlug in
                    if !brainStore.pages.contains(where: { $0.slug == deletedSlug }) {
                        BrainChip(text: deletedSlug, symbolName: "trash", tint: WispColor.textTertiary)
                    }
                }
            }
        }
    }
}
