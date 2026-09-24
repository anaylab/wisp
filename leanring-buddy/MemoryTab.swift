//
//  MemoryTab.swift
//  leanring-buddy
//
//  The dashboard's Memory tab: what Wisp remembers about the user
//  (`~/.wisp/memory.md`, via `MemoryStore`) and the saved recent conversation
//  (`ConversationHistoryStore`).
//
//  The memory file stays the place to edit — this tab lists its facts with a
//  delete button each, and opens the file in Finder for anything more. The
//  history card says what is saved and offers the one action a privacy-minded
//  user needs: clear it.
//

import SwiftUI

struct MemoryTab: View {
    @ObservedObject private var memoryStore = MemoryStore.shared
    @ObservedObject private var conversationHistoryStore = ConversationHistoryStore.shared

    @State private var isConfirmingClearConversationHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                rememberedFactsCard
                conversationHistoryCard
            }
            .padding(16)
        }
        .background(DS.Colors.background)
        // Pick up hand edits made in a text editor since the tab was last shown.
        .onAppear { memoryStore.reloadIfFileChanged() }
    }

    // MARK: - Remembered facts

    private var rememberedFactsCard: some View {
        DashboardCard(title: "What Wisp remembers about you") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stored on this Mac in ~/.wisp/memory.md, one fact per bullet. Ask Wisp to \"remember that…\" or \"forget…\" (agent mode), or edit the file directly. The most recent facts are included with each question.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if memoryStore.facts.isEmpty {
                    Text("Nothing remembered yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textTertiary)
                } else {
                    VStack(spacing: 6) {
                        // Indexed rather than keyed by the fact text: a
                        // hand-edited file can hold the same line twice.
                        ForEach(Array(memoryStore.facts.enumerated()), id: \.offset) { _, fact in
                            RememberedFactRow(
                                fact: fact,
                                onDelete: { memoryStore.removeFact(fact) }
                            )
                        }
                    }
                }

                Divider().overlay(DS.Colors.borderSubtle)

                HStack(spacing: 8) {
                    Button("Reveal memory.md in Finder") { memoryStore.revealMemoryFileInFinder() }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                    Button("Reload") { memoryStore.reload() }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                    Spacer()
                }
            }
        }
    }

    // MARK: - Conversation history

    private var conversationHistoryCard: some View {
        DashboardCard(title: "Conversation history") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The last \(ConversationHistoryCodec.maximumPersistedTurnCount) exchanges are saved on this Mac (text only — never screenshots) so Wisp can pick up where you left off. Only exchanges from the last \(resumeWindowDescription) are carried into a new session; older ones are kept for reference.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(savedHistorySummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)

                Divider().overlay(DS.Colors.borderSubtle)

                HStack(spacing: 8) {
                    Button("Clear conversation history") { isConfirmingClearConversationHistory = true }
                        .buttonStyle(DSDestructiveButtonStyle())
                        .disabled(conversationHistoryStore.persistedTurns.isEmpty)
                    Button("Reveal in Finder") { conversationHistoryStore.revealHistoryFileInFinder() }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                    Spacer()
                }
            }
        }
        .confirmationDialog(
            "Clear conversation history?",
            isPresented: $isConfirmingClearConversationHistory
        ) {
            Button("Clear history", role: .destructive) { conversationHistoryStore.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wisp forgets the current conversation and deletes the saved copy. Your remembered facts are not affected.")
        }
    }

    private var savedHistorySummary: String {
        let savedTurns = conversationHistoryStore.persistedTurns
        guard let newestTurn = savedTurns.last else { return "Nothing saved." }
        let exchangeWord = savedTurns.count == 1 ? "exchange" : "exchanges"
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .full
        let newestTurnRelativeTime = relativeFormatter.localizedString(for: newestTurn.startedAt, relativeTo: Date())
        return "\(savedTurns.count) saved \(exchangeWord) · latest \(newestTurnRelativeTime)"
    }

    private var resumeWindowDescription: String {
        let resumeWindowHours = Int(ConversationHistoryCodec.maximumResumedTurnAge / 3600)
        return resumeWindowHours == 1 ? "hour" : "\(resumeWindowHours) hours"
    }
}

/// One remembered fact with a delete button that appears clearly on hover.
private struct RememberedFactRow: View {
    let fact: String
    let onDelete: () -> Void

    @State private var isRowHovered = false
    @State private var isDeleteButtonHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(DS.Colors.accentText)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            Text(fact)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isDeleteButtonHovered ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(isDeleteButtonHovered ? DS.Colors.destructive.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Forget this")
            .accessibilityLabel("Forget \(fact)")
            // Quiet at rest so the list reads as content, fully visible when the
            // row is hovered so it is obvious which fact the button acts on.
            .opacity(isRowHovered ? 1 : 0.45)
            .onHover { hovering in isDeleteButtonHovered = hovering }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(isRowHovered ? DS.Colors.surface2 : Color.clear)
        )
        .onHover { hovering in isRowHovered = hovering }
        .animation(.easeOut(duration: DS.Animation.fast), value: isRowHovered)
    }
}
