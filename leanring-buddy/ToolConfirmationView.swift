//
//  ToolConfirmationView.swift
//  leanring-buddy
//
//  The visible half of asking permission to run a tool.
//
//  The spoken question came first, and mostly it is enough — this is a voice
//  assistant and answering out loud is the natural thing. It is not always
//  sufficient though. Speech synthesis can fail, the room can be noisy, the
//  user may not have caught which tool was named, and someone wearing
//  headphones that are not connected hears nothing at all. In each of those
//  cases a voice-only prompt leaves no way to say yes, and the request
//  silently expires.
//
//  So this shows what was asked, including the arguments, and offers two
//  buttons. It also lets someone read the exact request rather than trusting
//  a spoken paraphrase of it, which matters more the more consequential the
//  tool.
//

import Combine
import SwiftUI

struct ToolConfirmationView: View {
    let confirmation: ToolConfirmationCoordinator.PendingConfirmation
    let onApprove: () -> Void
    let onDeny: () -> Void

    /// Counts down alongside the coordinator's own timeout, so the card
    /// doesn't sit there looking live after the request has expired.
    @State private var secondsRemaining: Int = 45

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.warningText)
                Text("Permission needed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)

                Spacer(minLength: 12)

                Text("\(secondsRemaining)s")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(secondsRemaining <= 10 ? DS.Colors.destructiveText : DS.Colors.textTertiary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(confirmation.spokenQuestion)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // The exact call, so a decision can be made on what will
                // actually run rather than on a spoken summary of it.
                Text(confirmation.toolName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Colors.accentText)

                if confirmation.argumentSummary != "{}" && !confirmation.argumentSummary.isEmpty {
                    Text(confirmation.argumentSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                // Deny leads, and is the wider target. Approving runs
                // something; declining costs a repeated request.
                Button(action: onDeny) {
                    Text("Don't")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface3)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: onApprove) {
                    Text("Allow")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Text("or just say yes")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderStrong, lineWidth: 1)
        )
        // Only this card takes clicks. The overlay behind it must stay
        // transparent to the mouse or the whole desktop becomes unclickable.
        .allowsHitTesting(true)
        .onReceive(countdownTimer) { _ in
            let elapsed = Int(Date().timeIntervalSince(confirmation.requestedAt))
            secondsRemaining = max(0, 45 - elapsed)
        }
    }
}
