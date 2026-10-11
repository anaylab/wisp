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
//  plain summary it always was.
//
//  The call's human-text fields (subject, body, message, event title, …, as
//  decided by `EditableConfirmationFields`) are drawn as editable text boxes in
//  place of their card rows, so the user can fix the wording before Allow. The
//  typed text goes straight to the coordinator — which is what makes a spoken
//  "yes" approve the edited version — and the raw call chip shows the call as
//  it will run with those edits. Recipients, paths and the like stay read-only.
//

import Combine
import SwiftUI

struct ToolConfirmationView: View {
    let confirmation: ToolConfirmationCoordinator.PendingConfirmation
    /// Holds the edits and the (movable) expiry. Observed so the fields and
    /// the countdown follow it.
    @ObservedObject var confirmationCoordinator: ToolConfirmationCoordinator
    let onApprove: () -> Void
    let onDeny: () -> Void

    /// Counts down alongside the coordinator's own timeout, so the card
    /// doesn't sit there looking live after the request has expired.
    @State private var secondsRemaining: Int = Int(ToolConfirmationCoordinator.confirmationTimeoutSeconds)

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The call as it will run: the asked-about input with the current edits
    /// applied, through the same rule the executor uses.
    private var argumentSummaryWithEdits: String {
        guard let toolInput = confirmation.toolInput,
              !confirmationCoordinator.editedTextsByArgumentKey.isEmpty else {
            return confirmation.argumentSummary
        }
        return EditableConfirmationFields.applyingEdits(
            confirmationCoordinator.editedTextsByArgumentKey,
            toToolInput: toolInput,
            toolNamed: confirmation.toolName
        ).toolInput.compactDescription
    }

    private var hasArguments: Bool {
        confirmation.argumentSummary != "{}" && !confirmation.argumentSummary.isEmpty
    }

    var body: some View {
        // A message send is shown as the message itself, not as a tool call.
        if let messageDraft = confirmation.messageDraft {
            let editableMessageField = confirmation.editableFields.first { $0.argumentKey == "message" }
            MessageSendConfirmationView(
                messageDraft: messageDraft,
                editableMessageField: editableMessageField,
                currentMessageText: editableMessageField.map(currentText(for:)) ?? messageDraft.messageText,
                expiryDate: confirmationCoordinator.pendingConfirmationExpiryDate,
                onMessageTextChange: { editedMessageText in
                    guard let editableMessageField else { return }
                    confirmationCoordinator.updateEditedText(editedMessageText, forArgumentKey: editableMessageField.argumentKey)
                },
                onEditingActivity: { confirmationCoordinator.extendTimeoutForEditing() },
                onSend: onApprove,
                onCancel: onDeny
            )
        } else if let toolInput = confirmation.toolInput,
                  let schedulingPreview = SchedulingConfirmationPreview(toolName: confirmation.toolName, toolInput: toolInput) {
            // An event or reminder is shown as what it will add, Siri-style.
            SchedulingConfirmationView(
                preview: schedulingPreview,
                editableFields: confirmation.editableFields,
                editedTextsByArgumentKey: confirmationCoordinator.editedTextsByArgumentKey,
                expiryDate: confirmationCoordinator.pendingConfirmationExpiryDate,
                onTextChange: { argumentKey, editedText in
                    confirmationCoordinator.updateEditedText(editedText, forArgumentKey: argumentKey)
                },
                onEditingActivity: { confirmationCoordinator.extendTimeoutForEditing() },
                onAdd: onApprove,
                onCancel: onDeny
            )
        } else {
            toolCallPanel
        }
    }

    /// What a field shows now: the user's edit, or the model's original.
    private func currentText(for editableField: EditableConfirmationField) -> String {
        confirmationCoordinator.editedTextsByArgumentKey[editableField.argumentKey] ?? editableField.originalText
    }

    private var toolCallPanel: some View {
        WispGlassPanel(
            cornerRadius: WispRadius.panel,
            padding: WispSpacing.lg,
            shadow: .island,
            // A decision is pending, so the whole rim glows in the warning tone.
            rimLight: .glowing(WispColor.warning)
        ) {
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
            refreshSecondsRemaining()
        }
        // Editing moves the expiry; follow it at once rather than on the next tick.
        .onChange(of: confirmationCoordinator.pendingConfirmationExpiryDate) { _, _ in
            refreshSecondsRemaining()
        }
    }

    private func refreshSecondsRemaining() {
        let expiryDate = confirmationCoordinator.pendingConfirmationExpiryDate
            ?? confirmation.requestedAt.addingTimeInterval(ToolConfirmationCoordinator.confirmationTimeoutSeconds)
        secondsRemaining = max(0, Int(expiryDate.timeIntervalSinceNow.rounded(.up)))
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
            // The rows that became editable fields are left off the card so
            // nothing is shown twice.
            if let confirmationCard = confirmation.confirmationCard {
                GlanceCardView(card: EditableConfirmationFields.card(
                    confirmationCard,
                    hidingRowsShownBy: confirmation.editableFields
                ))
            }

            if confirmation.offersEditableFields {
                VStack(alignment: .leading, spacing: WispSpacing.xs) {
                    ForEach(confirmation.editableFields) { editableField in
                        EditableConfirmationFieldView(
                            editableField: editableField,
                            currentText: currentText(for: editableField),
                            onTextChange: { editedText in
                                confirmationCoordinator.updateEditedText(editedText, forArgumentKey: editableField.argumentKey)
                            },
                            onEditingActivity: { confirmationCoordinator.extendTimeoutForEditing() }
                        )
                    }
                }
            }

            // The exact call + arguments, so a decision is made on what will
            // actually run rather than on a spoken paraphrase. With a card
            // above, the raw arguments shrink to one (still selectable) line —
            // the card already shows them legibly. Edits are reflected here.
            VStack(alignment: .leading, spacing: WispSpacing.xs) {
                Text(confirmation.toolName)
                    .font(WispFont.mono)
                    .foregroundColor(WispColor.Brand.sage)
                if hasArguments {
                    Text(argumentSummaryWithEdits)
                        .font(WispFont.mono)
                        .foregroundColor(WispColor.OnGlass.textTertiary)
                        .lineLimit(confirmation.confirmationCard == nil && !confirmation.offersEditableFields ? 3 : 1)
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
            // Cmd-Return approves from inside a field. Plain Return never
            // does: there is deliberately no default button on this card.
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
