//
//  GlanceCardView.swift
//  leanring-buddy
//
//  Renders a `GlanceCard` — the read-only visual answer surface parsed out of a
//  model reply by `GlanceCardParser` — inside the notch HUD's expanded panel.
//
//  The card is deliberately non-interactive in v1 (it shows an answer; it does
//  not act on one), so there are no click targets and therefore no pointer-
//  cursor affordances to add. Every colour, radius and surface comes from `DS.*`
//  so the card sits in the notch's dark-glass panel and stays theme-correct.
//
//  One private subview per block kind, mirroring the fixed block vocabulary in
//  `GlanceBlock`. Tone is resolved to a concrete `DS.Colors` value here — the
//  model only ever sends the word (good / bad / neutral), never a colour.
//

import SwiftUI

struct GlanceCardView: View {
    let card: GlanceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The block vocabulary is small and fixed; iterate by position since
            // GlanceBlock carries no identity of its own.
            ForEach(Array(card.blocks.enumerated()), id: \.offset) { _, block in
                blockView(for: block)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Block dispatch

    @ViewBuilder
    private func blockView(for block: GlanceBlock) -> some View {
        switch block {
        case let .header(title, iconName, trailingText):
            headerBlock(title: title, iconName: iconName, trailingText: trailingText)
        case let .list(rows):
            listBlock(rows: rows)
        case let .keyValue(pairs):
            keyValueBlock(pairs: pairs)
        case let .stats(items):
            statsBlock(items: items)
        }
    }

    // MARK: - Header

    private func headerBlock(title: String, iconName: String?, trailingText: String?) -> some View {
        HStack(spacing: 8) {
            if let iconName {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - List

    private func listBlock(rows: [GlanceListRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let iconName = row.iconName {
                        Image(systemName: iconName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(toneColor(row.tone, neutralFallback: DS.Colors.textTertiary))
                            .frame(width: 15, alignment: .center)
                    }
                    Text(row.text)
                        .font(.system(size: 12))
                        .foregroundColor(toneColor(row.tone, neutralFallback: DS.Colors.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Key / value

    private func keyValueBlock(pairs: [GlanceKeyValuePair]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pair.key)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer(minLength: 8)
                    Text(pair.value)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(toneColor(pair.tone, neutralFallback: DS.Colors.textPrimary))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    // MARK: - Stats

    private func statsBlock(items: [GlanceStat]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.value)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(toneColor(stat.tone, neutralFallback: DS.Colors.textPrimary))
                        .lineLimit(1)
                    if !stat.label.isEmpty {
                        Text(stat.label)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Tone

    /// Resolves a semantic tone to a concrete colour. `neutral` has no fixed
    /// colour of its own — it reads as ordinary text — so the caller passes the
    /// text colour appropriate to where it sits (a body line, a value, a stat).
    private func toneColor(_ tone: GlanceTone, neutralFallback: Color) -> Color {
        switch tone {
        case .good:
            return DS.Colors.success
        case .bad:
            return DS.Colors.destructiveText
        case .neutral:
            return neutralFallback
        }
    }
}

#if DEBUG
#Preview {
    GlanceCardView(
        card: GlanceCard(blocks: [
            .header(title: "San Francisco", iconName: "cloud", trailingText: "61°"),
            .keyValue(pairs: [
                GlanceKeyValuePair(key: "Wind", value: "12 mph", tone: .neutral),
                GlanceKeyValuePair(key: "Humidity", value: "78%", tone: .good),
                GlanceKeyValuePair(key: "Air quality", value: "Unhealthy", tone: .bad)
            ]),
            .stats(items: [
                GlanceStat(label: "High", value: "64°", tone: .neutral),
                GlanceStat(label: "Low", value: "52°", tone: .neutral)
            ])
        ])
    )
    .frame(width: 352)
    .padding()
    .background(DS.Colors.surface1)
}
#endif
