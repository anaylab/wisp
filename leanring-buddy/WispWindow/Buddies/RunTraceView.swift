//
//  RunTraceView.swift
//  leanring-buddy
//
//  A run's Trace, opened from the "4 steps 11s ›" line above an answer (after
//  OpenBot): the totals along the top, then every step as a bar on one shared
//  time axis, the slowest marked.
//

import SwiftUI

struct RunTraceView: View {
    let runRecord: AgentTaskRecord
    let buddy: WispBuddy
    var onClose: () -> Void

    var body: some View {
        let trace = RunTraceBuilder.trace(
            steps: runRecord.steps, runStartedAt: runRecord.startedAt, runTotalSeconds: runRecord.elapsedSeconds)
        let accent = BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Trace").font(.system(size: 14, weight: .semibold)).foregroundStyle(WispColor.textPrimary)
                Spacer()
                BuddyIconButton(symbolName: "xmark", label: "Close", size: 26, action: onClose)
            }
            .padding(.horizontal, 18).frame(height: 48)
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)

            HStack(spacing: 0) {
                stat("Duration", BuddyFormatting.durationText(trace.totalSeconds))
                stat("Steps", "\(trace.stepCount)")
                stat("Model calls", "\(trace.modelCallCount)")
                stat("Tool calls", "\(trace.toolCallCount)")
                stat("Errors", "\(trace.errorCount)", isAlert: trace.errorCount > 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(trace.rows) { row in
                        HStack(spacing: 12) {
                            Image(systemName: row.isModelCall ? "sparkle" : "wrench.and.screwdriver")
                                .font(.system(size: 10.5))
                                .foregroundStyle(WispColor.textTertiary)
                                .frame(width: 16)
                            Text(row.title)
                                .font(.system(size: 12))
                                .foregroundStyle(WispColor.textPrimary)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: 210, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(WispColor.surface3.opacity(0.5))
                                    Capsule()
                                        .fill(row.isError ? DS.Colors.destructive : (row.isModelCall ? accent : WispColor.textSecondary))
                                        .frame(width: max(3, geometry.size.width * row.widthFraction))
                                        .offset(x: geometry.size.width * row.offsetFraction)
                                }
                            }
                            .frame(height: 8)
                            Text(BuddyFormatting.durationText(row.durationSeconds))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(WispColor.textSecondary)
                                .frame(width: 44, alignment: .trailing)
                            if row.isSlowest {
                                Text("Slowest").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WispColor.warningText)
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(Capsule().fill(WispColor.warning.opacity(0.16)))
                            }
                        }
                        .padding(.horizontal, 18).frame(height: 34)
                    }
                    if trace.rows.isEmpty {
                        Text("This run recorded no steps.").font(.system(size: 12.5)).foregroundStyle(WispColor.textTertiary)
                            .padding(18)
                    }
                }
            }
        }
        .frame(width: 720, height: 420)
        .background(WispColor.background)
    }

    private func stat(_ title: String, _ value: String, isAlert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(WispColor.textTertiary)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(isAlert ? DS.Colors.destructiveText : WispColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
