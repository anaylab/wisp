//
//  ResearchReportView.swift
//  leanring-buddy
//
//  A research report as a Chat page entry (phase 11): the question, the short
//  answer, numbered claims with their quote, and the sources. Every [n] and
//  every source row is a button: it brings that source's Chrome tab forward
//  and marks the quote in the page (`ResearchSessionController.openCitation`).
//  Below: Save to Brain, Copy, and Close research tabs.
//

import AppKit
import SwiftUI

struct ResearchReportView: View {
    let report: ResearchReport
    @ObservedObject private var researchSession = ResearchSessionController.shared
    @ObservedObject private var brainPreferences = BrainPreferences.shared

    @State private var statusLine: String?
    @State private var hasSavedToBrain = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 10) {
                header
                Text(report.summary)
                    .font(.system(size: 13.5))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !report.claims.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.claims, id: \.number) { claim in
                            claimRow(claim)
                        }
                    }
                }
                if !report.sources.isEmpty {
                    sourcesList
                }
                if report.droppedClaimCount > 0 {
                    Text(ResearchReportText.droppedClaimsNote(count: report.droppedClaimCount))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                actionRow
                if let statusLine {
                    Text(statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(WispColor.surface2.opacity(0.9))
            )
            Spacer(minLength: 40)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Research · \(report.topic)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("\(report.createdAt.formatted(date: .omitted, time: .shortened)) · \(report.sources.count) cited sources · \(report.usedLocalModel ? "written on this Mac" : "written by your cloud model")")
                .font(.system(size: 10.5))
                .foregroundStyle(DS.Colors.textTertiary)
        }
    }

    private func claimRow(_ claim: ResearchReport.Claim) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(claim.number).")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(claim.text)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                citationButton(claim)
            }
            Text("“\(claim.quote)”")
                .font(.system(size: 11.5).italic())
                .foregroundStyle(DS.Colors.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
        }
    }

    private func citationButton(_ claim: ResearchReport.Claim) -> some View {
        Button {
            open(claim)
        } label: {
            Text("[\(claim.sourceNumber)]")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(WispColor.accentText)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(report.source(numbered: claim.sourceNumber).map { "Show this quote in \($0.title)" } ?? "Show the source")
        .accessibilityLabel("Source \(claim.sourceNumber): show the quote")
    }

    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
            ForEach(report.sources, id: \.number) { source in
                Button {
                    if let firstClaim = report.claims.first(where: { $0.sourceNumber == source.number }) {
                        open(firstClaim)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("[\(source.number)]")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(WispColor.accentText)
                        Text(source.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(URLComponents(string: source.url)?.host ?? "")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip(source.url)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if brainPreferences.isBrainEnabled && !report.claims.isEmpty {
                Button(hasSavedToBrain ? "Saved to Brain" : "Save to Brain") {
                    statusLine = researchSession.saveToBrain(report)
                    hasSavedToBrain = true
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .disabled(hasSavedToBrain)
                .pointerCursor(isEnabled: !hasSavedToBrain)
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.plainText, forType: .string)
                statusLine = "Copied the report."
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .pointerCursor()
            if researchSession.hasOpenResearchTabs {
                Button("Close research tabs") {
                    Task { statusLine = await researchSession.closeResearchTabs(askingAboutUsedTabs: true) }
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .pointerCursor()
            }
        }
        .controlSize(.small)
    }

    private func open(_ claim: ResearchReport.Claim) {
        Task {
            statusLine = await researchSession.openCitation(claim, in: report)
        }
    }
}
