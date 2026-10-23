//
//  ChromePageWatchRow.swift
//  leanring-buddy
//
//  One Chrome page watch in the notch's live section (phase 08), beside the
//  screen watches: what it waits for, on which tab, how long it has run, and
//  Stop. Its own file so NotchHUDView.swift only gains a ForEach line.
//

import SwiftUI

struct ChromePageWatchRow: View {
    let activeChromePageWatch: ActiveChromePageWatch

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activeChromePageWatch.reloadEveryMinutes == nil ? "eye" : "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WispColor.Brand.lavender)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text("Watching until \(activeChromePageWatch.condition.summaryText)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                // Read from a clock so "just started" moves on while the panel is open.
                TimelineView(.periodic(from: activeChromePageWatch.startDate, by: 30)) { timelineContext in
                    let elapsedMinutes = Int(timelineContext.date.timeIntervalSince(activeChromePageWatch.startDate) / 60)
                    let elapsedText = elapsedMinutes < 1 ? "just started" : "\(elapsedMinutes) min"
                    Text("\(activeChromePageWatch.tabDisplayName) · \(elapsedText)")
                        .font(.system(size: 10.5))
                        .foregroundColor(WispColor.Island.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                ChromePageWatchStore.shared.stopWatching(watchID: activeChromePageWatch.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("Stop")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(WispColor.Island.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule(style: .continuous).fill(WispColor.Island.controlFill))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableScaleButtonStyle())
            .pointerCursor()
            .nativeTooltip("Stop watching this tab")
        }
    }
}
