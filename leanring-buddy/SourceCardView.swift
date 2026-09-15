//
//  SourceCardView.swift
//  leanring-buddy
//
//  Renders a user-configured source card in the notch. The fetched values are
//  mapped into a generic `GlanceCard` (by `RESTSourceDataProvider`) and drawn
//  with the shared `GlanceCardView`, plus a "Live · <source>" label because the
//  data came off the machine. Non-loaded states show a plain, matching card so
//  the source can appear immediately and fill in — or explain why it can't.
//

import SwiftUI

/// What a user-configured source card is showing right now. The source name is
/// carried through every state so the card is always labelled.
enum SourceCardState: Equatable {
    case loading(sourceName: String)
    case failed(sourceName: String)
    /// The model named a source that isn't in `~/.wisp/sources.json`.
    case notConfigured(sourceName: String)
    /// Live card data is turned off, so the network source can't be fetched.
    case disabled(sourceName: String)
    case loaded(sourceName: String, card: GlanceCard)
}

struct SourceCardView: View {
    let state: SourceCardState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case let .loaded(sourceName, card):
                GlanceCardView(card: card)
                liveAttribution(sourceName: sourceName)
            case let .loading(sourceName):
                placeholderCard(sourceName: sourceName, message: "Loading…")
            case let .failed(sourceName):
                placeholderCard(sourceName: sourceName, message: "Couldn't reach this source.")
            case let .notConfigured(sourceName):
                placeholderCard(sourceName: sourceName, message: "No source named “\(sourceName)” in ~/.wisp/sources.json.")
            case let .disabled(sourceName):
                placeholderCard(sourceName: sourceName, message: "Live card data is off — turn it on to load this source.")
            }
        }
    }

    private func placeholderCard(sourceName: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                Text(sourceName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func liveAttribution(sourceName: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(DS.Colors.accentText)
                .frame(width: 5, height: 5)
            Text("Live · \(sourceName)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.leading, 2)
    }
}
