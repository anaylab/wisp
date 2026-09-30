//
//  ToolConfirmationView.swift
//  leanring-buddy
//
//  The visible half of asking permission to run a tool — now rendered as Wisp's
//  Dynamic-Island confirmation panel. When the companion needs an explicit ok
//  before an external or sensitive action, the island expands into this compact
//  pane of glass: the request itself is visually dominant, the exact call is
//  legible beneath it, and two clear (but not enormous) choices sit at the
//  bottom, with "or just say yes" as the voice affordance.
//
//  The spoken question still comes first — this is a voice assistant — but the
//  card exists for every case speech alone fails: a failed synth, a noisy room,
//  disconnected headphones, or simply wanting to read the exact request before
//  allowing it. The presentation/interactivity plumbing is unchanged; only the
//  look is the new liquid-glass identity.
//
//  When the coordinator attached a confirmation card (built deterministically
//  from the call by `ToolConfirmationCardBuilder` — "New Email" with To and
//  Subject, a file write with its path), it is drawn with the generic glance-
//  card renderer between the request and the buttons, and the raw call chip
//  shrinks to a single line beneath it. Without a card the panel is exactly the
//  plain summary it always was. The card is display-only; inline-editable
//  fields (VoiceOS-style `{{param}}` bindings) are a deliberate future extension.
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

    private var hasArguments: Bool {
        confirmation.argumentSummary != "{}" && !confirmation.argumentSummary.isEmpty
    }

    var body: some View {
        // A message send is shown as the message itself, not as a tool call.
        if let messageDraft = confirmation.messageDraft {
            MessageSendConfirmationView(
                messageDraft: messageDraft,
                requestedAt: confirmation.requestedAt,
                onSend: onApprove,
                onCancel: onDeny
            )
        } else {
            toolCallPanel
        }
    }

    private var toolCallPanel: some View {
        WispGlassPanel(cornerRadius: WispRadius.panel, padding: WispSpacing.lg, shadow: .island) {
            VStack(alignment: .leading, spacing: WispSpacing.md) {
                header
                requestBlock
                actions
                Text("or just say yes")
                    .font(WispFont.caption)
                    .foregroundColor(WispColor.OnGlass.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(
            WispStateWash(color: WispColor.warning, strength: 0.3)
                .clipShape(RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous))
        )
        .frame(width: 312)
        // Only this card takes clicks. The overlay behind it must stay
        // transparent to the mouse or the whole desktop becomes unclickable.
        .allowsHitTesting(true)
        .onReceive(countdownTimer) { _ in
            let elapsed = Int(Date().timeIntervalSince(confirmation.requestedAt))
            secondsRemaining = max(0, 45 - elapsed)
        }
    }

    // MARK: - Header — the wisp mark asking

    private var header: some View {
        HStack(spacing: WispSpacing.sm) {
            WispMark(state: .thinking, size: 18)
            Text("Wisp")
                .font(WispFont.headline)
                .foregroundColor(WispColor.OnGlass.textPrimary)
            Text("needs your ok")
                .font(WispFont.caption)
                .foregroundColor(WispColor.OnGlass.textTertiary)

            Spacer(minLength: WispSpacing.sm)

            Text("\(secondsRemaining)s")
                .font(WispFont.mono)
                .foregroundColor(secondsRemaining <= 10 ? WispColor.destructiveText : WispColor.OnGlass.textTertiary)
        }
    }

    // MARK: - The request (visually dominant)

    private var requestBlock: some View {
        VStack(alignment: .leading, spacing: WispSpacing.sm) {
            // The spoken request, given the most weight on the card.
            Text(confirmation.spokenQuestion)
                .font(WispFont.title)
                .foregroundColor(WispColor.OnGlass.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // What the call will do, laid out as a card, when its shape is
            // one Wisp recognises.
            if let confirmationCard = confirmation.confirmationCard {
                GlanceCardView(card: confirmationCard)
            }

            // The exact call + arguments, so a decision is made on what will
            // actually run rather than on a spoken paraphrase. With a card
            // above, the raw arguments shrink to one (still selectable) line —
            // the card already shows them legibly.
            VStack(alignment: .leading, spacing: WispSpacing.xs) {
                Text(confirmation.toolName)
                    .font(WispFont.mono)
                    .foregroundColor(WispColor.Brand.sage)
                if hasArguments {
                    Text(confirmation.argumentSummary)
                        .font(WispFont.mono)
                        .foregroundColor(WispColor.OnGlass.textTertiary)
                        .lineLimit(confirmation.confirmationCard == nil ? 3 : 1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(WispSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                    .fill(WispColor.OnGlass.chipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                    .strokeBorder(WispColor.OnGlass.borderSubtle, lineWidth: 0.75)
            )
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: WispSpacing.sm) {
            // Cancel leads and is the wider target — approving runs something,
            // declining only costs a repeated request.
            Button("Cancel", action: onDeny)
                .wispGlassButtonStyle(prominence: .subtle)

            Button(action: onApprove) {
                HStack(spacing: WispSpacing.xs) {
                    Text("Allow")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .wispGlassButtonStyle(prominence: .prominent)
        }
    }
}
