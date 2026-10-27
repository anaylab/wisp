//
//  ToolConfirmationView.swift
//  leanring-buddy
//
//  The visible half of asking permission to run a tool — now rendered as Wisp's
//  Dynamic-Island confirmation panel. When the companion needs an explicit ok
//  before an external or sensitive action, the island expands into this compact
//  island-surface card below the notch (solid black, or Liquid Glass when the
//  user chose it for the island): a plain-words headline, what will happen,
//  the exact call folded into one line, and two clear choices, with "or just
//  say yes" as the voice affordance.
//
//  The spoken question still comes first — this is a voice assistant — but the
//  card exists for every case speech alone fails: a failed synth, a noisy room,
//  disconnected headphones, or simply wanting to read the exact request before
//  allowing it.
//
//  When the coordinator attached a confirmation card (built deterministically
//  from the call by `ToolConfirmationCardBuilder` — "New Email" with To and
//  Subject, a file write with its path), it is drawn with the generic glance-
//  card renderer between the headline and the buttons. Without a card the
//  headline names the tool in plain words.
//
//  The call's human-text fields (subject, body, message, event title, …, as
//  decided by `EditableConfirmationFields`) are drawn as editable text boxes in
//  place of their card rows, so the user can fix the wording before Allow. The
//  typed text goes straight to the coordinator — which is what makes a spoken
//  "yes" approve the edited version — and the call details show the call as
//  it will run with those edits. Recipients, paths and the like stay read-only.
//

import SwiftUI

struct ToolConfirmationView: View {
    let confirmation: ToolConfirmationCoordinator.PendingConfirmation
    /// Holds the edits and the (movable) expiry. Observed so the fields and
    /// the countdown follow it.
    @ObservedObject var confirmationCoordinator: ToolConfirmationCoordinator
    let onApprove: () -> Void
    let onDeny: () -> Void

    /// The island's surface choice (black by default, Liquid Glass when the
    /// user opted in), so the card reads as the island expanding.
    @ObservedObject private var islandStylePreference = NotchIslandStylePreference.shared

    /// Whether the raw call (tool name + arguments) is unfolded. Folded by
    /// default: the headline and card already say what will happen, and the
    /// JSON underneath is for the user who wants to check it.
    @State private var isShowingCallDetails = false

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
        } else {
            toolCallPanel
        }
    }

    /// What a field shows now: the user's edit, or the model's original.
    private func currentText(for editableField: EditableConfirmationField) -> String {
        confirmationCoordinator.editedTextsByArgumentKey[editableField.argumentKey] ?? editableField.originalText
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous)
    }

    private var toolCallPanel: some View {
        VStack(alignment: .leading, spacing: WispSpacing.md) {
            header
            requestBlock
            actions
            Text("or just say yes")
                .font(WispFont.caption)
                .foregroundColor(WispColor.Island.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(WispSpacing.lg)
        .frame(width: 340)
        // A solid island surface, not translucent glass: the card used to show
        // the user's window through one half and the wallpaper through the
        // other, which made the text muddy. Black by default, like the notch.
        .wispNotchIslandSurface(in: cardShape, style: islandStylePreference.surfaceStyle)
        // A decision is pending, so the rim glows in the warning tone.
        .wispLiquidRim(
            in: cardShape,
            light: .glowing(WispColor.warning),
            showsSpecularHighlight: islandStylePreference.surfaceStyle == .liquidGlass
        )
        .wispShadow(.island)
        // Only this card takes clicks. The overlay behind it must stay
        // transparent to the mouse or the whole desktop becomes unclickable.
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wisp needs your OK")
        .accessibilityAddTraits(.isModal)
    }

    /// What the card asks, in plain words. The spoken question is lowercase
    /// and names the raw tool ("i'd need to run hotkey to do that…"), which
    /// suits speech but not a headline.
    private var headlineText: String {
        if confirmation.confirmationCard != nil || confirmation.offersEditableFields {
            return "Allow Wisp to do this?"
        }
        return "Allow Wisp to run \u{201C}\(readableToolName)\u{201D}?"
    }

    /// `cua-driver__get_window_state` → `get window state (cua-driver)`.
    private var readableToolName: String {
        let actionWords = ToolCallInspection.words(inIdentifier: ToolCallInspection.bareToolName(confirmation.toolName))
            .joined(separator: " ")
        guard let serverNamespace = ToolCallInspection.serverNamespace(of: confirmation.toolName) else {
            return actionWords
        }
        return "\(actionWords) (\(serverNamespace))"
    }

    private func secondsRemaining(at date: Date) -> Int {
        let expiryDate = confirmationCoordinator.pendingConfirmationExpiryDate
            ?? confirmation.requestedAt.addingTimeInterval(ToolConfirmationCoordinator.confirmationTimeoutSeconds)
        return max(0, Int(expiryDate.timeIntervalSince(date).rounded(.up)))
    }

    // MARK: - Header — the wisp mark asking

    private var header: some View {
        HStack(spacing: WispSpacing.sm) {
            WispMark(state: .thinking, size: 16)
                .accessibilityHidden(true)
            Text("Wisp needs your OK")
                .font(WispFont.caption)
                .foregroundColor(WispColor.Island.textSecondary)

            Spacer(minLength: WispSpacing.sm)

            // Derived from the expiry on every tick rather than counted in
            // view state. The old Timer + @State lived in the view struct, so
            // each overlay re-render (the live transcript updates it ~11 times
            // a second) rebuilt it, and the card could flash "45s" or skip.
            TimelineView(.periodic(from: .now, by: 1)) { timelineContext in
                let remainingSeconds = secondsRemaining(at: timelineContext.date)
                Text("\(remainingSeconds)s")
                    .font(WispFont.mono)
                    .monospacedDigit()
                    .foregroundColor(remainingSeconds <= 10 ? WispColor.destructiveText : WispColor.Island.textTertiary)
                    .accessibilityLabel("\(remainingSeconds) seconds to answer")
            }
        }
    }

    // MARK: - The request (visually dominant)

    private var requestBlock: some View {
        VStack(alignment: .leading, spacing: WispSpacing.sm) {
            // A card already says what will happen ("Use Google Calendar"), so
            // a headline above it only repeats "Allow Wisp to do this?".
            if confirmation.confirmationCard == nil {
                Text(headlineText)
                    .font(WispFont.title)
                    .foregroundColor(WispColor.Island.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

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

            callDetails
        }
    }

    /// The exact call, so a decision can be made on what will actually run
    /// rather than on a paraphrase — folded to one quiet line until asked for.
    /// Edits are reflected in it.
    private var callDetails: some View {
        VStack(alignment: .leading, spacing: WispSpacing.xs) {
            Button {
                isShowingCallDetails.toggle()
            } label: {
                HStack(spacing: WispSpacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isShowingCallDetails ? 90 : 0))
                    // Not the raw tool name: the headline or card already says
                    // what will happen, and "composio-connect__COM…IO_MULTI_EXECUTE_TOOL"
                    // is noise. The exact call is still one tap away.
                    Text("Details")
                        .font(WispFont.caption)
                    Spacer(minLength: 0)
                }
                .foregroundColor(WispColor.Island.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .accessibilityLabel(isShowingCallDetails ? "Hide call details" : "Show call details")

            if isShowingCallDetails && hasArguments {
                Text(argumentSummaryWithEdits)
                    .font(WispFont.mono)
                    .foregroundColor(WispColor.Island.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(WispSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                            .fill(WispColor.Island.controlFill)
                    )
            }
        }
        .animation(WispMotion.prefersReducedMotion ? nil : WispMotion.quick, value: isShowingCallDetails)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: WispSpacing.sm) {
            Button(action: onDeny) {
                Text("Cancel")
                    .font(WispFont.bodyMedium)
                    .frame(maxWidth: .infinity)
            }
            .wispIslandButtonStyle(prominence: .subtle)
            // Named explicitly: the custom button style left these as a bare
            // "button" to VoiceOver (and to any automation reading the card).
            .accessibilityLabel("Cancel")

            Button(action: onApprove) {
                HStack(spacing: WispSpacing.xs) {
                    Text("Allow")
                        .font(WispFont.bodyMedium)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .wispIslandButtonStyle(prominence: .prominent)
            .accessibilityLabel("Allow")
            // Cmd-Return approves from inside a field. Plain Return never
            // does: there is deliberately no default button on this card.
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

}
