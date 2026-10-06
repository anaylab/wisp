//
//  MessageSendConfirmationView.swift
//  leanring-buddy
//
//  The confirmation panel for sending a message, drawn the way Siri shows one:
//  who it goes to (avatar, name, number), the text as a message bubble, and
//  Cancel / Send. It replaces the generic tool panel for `send_imessage` — the
//  "needs your ok" header, key/value table and raw JSON chip told the user
//  about a tool call, when all they need to check is the person and the words.
//
//  Same consent flow underneath: the coordinator's timeout, the spoken "yes",
//  and deny-by-default are unchanged; only the presentation differs.
//
//  The bubble is editable: click it to reword the message before sending
//  (the recipient and number never are). Edits go to the coordinator, so a
//  spoken "yes" sends the edited text, and typing holds off the timeout.
//

import Combine
import SwiftUI

/// What a pending `send_imessage` confirmation will send, read from the
/// prepared tool input (resolved contact name, handle, message).
struct MessageSendDraft: Equatable {
    let recipientDisplayName: String
    let recipientHandle: String
    let messageText: String
    /// The Contacts card, for its photo; nil for a number or address given outright.
    let recipientContactIdentifier: String?

    /// Nil unless this is a `send_imessage` call with all three fields.
    init?(toolName: String, toolInput: JSONValue) {
        guard ToolCallInspection.bareToolName(toolName) == MessagingToolNames.sendIMessage,
              let recipientDisplayName = ToolCallInspection.stringValue(forAnyOf: ["to"], in: toolInput),
              let recipientHandle = ToolCallInspection.stringValue(forAnyOf: ["handle"], in: toolInput),
              let messageText = ToolCallInspection.stringValue(forAnyOf: ["message"], in: toolInput) else {
            return nil
        }
        self.recipientDisplayName = recipientDisplayName
        self.recipientHandle = recipientHandle
        self.messageText = messageText
        self.recipientContactIdentifier = ToolCallInspection.stringValue(forAnyOf: ["contact_id"], in: toolInput)
    }

    /// "Jane Doe" → "JD", "mom" → "M"; nil for a bare number or address,
    /// which gets a person glyph instead.
    var recipientInitials: String? {
        guard recipientDisplayName != recipientHandle else { return nil }
        let nameWords = recipientDisplayName.split(separator: " ").filter { $0.first?.isLetter == true }
        let initials = nameWords.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return initials.isEmpty ? nil : initials
    }

    /// Whether the handle is worth a second line under the name — it isn't
    /// when the name already is the number or address.
    var showsHandleUnderName: Bool { recipientDisplayName != recipientHandle }
}

struct MessageSendConfirmationView: View {
    let messageDraft: MessageSendDraft
    /// The message as an editable field; nil when the caller asked without
    /// allowing edits, and the bubble is then plain text as before.
    let editableMessageField: EditableConfirmationField?
    /// The text in the bubble now: the user's edit, or the original.
    let currentMessageText: String
    /// When the prompt expires; moves later while the user edits.
    let expiryDate: Date?
    let onMessageTextChange: (String) -> Void
    let onEditingActivity: () -> Void
    let onSend: () -> Void
    let onCancel: () -> Void

    /// Loaded from Contacts when the panel appears; initials show until then,
    /// and stay when the card has no photo.
    @State private var recipientPhoto: NSImage?
    @State private var secondsRemaining = Int(ToolConfirmationCoordinator.confirmationTimeoutSeconds)
    @State private var isBubbleHovered = false
    @FocusState private var isBubbleFocused: Bool
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isMessageEdited: Bool {
        guard let editableMessageField else { return false }
        return currentMessageText != editableMessageField.originalText
    }

    /// The iMessage bubble colour. A system colour, not a brand token: the
    /// bubble should read as "a message in Messages" at a glance.
    private let messageBubbleFill = Color(nsColor: .systemBlue)

    var body: some View {
        WispGlassPanel(cornerRadius: WispRadius.panel, padding: WispSpacing.lg, shadow: .island) {
            VStack(alignment: .leading, spacing: WispSpacing.md) {
                recipientHeader
                messageBubble
                actions
                Text("or just say yes")
                    .font(WispFont.caption)
                    .foregroundColor(WispColor.OnGlass.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: 312)
        // Only this card takes clicks; the overlay behind it stays click-through.
        .allowsHitTesting(true)
        .task(id: messageDraft.recipientContactIdentifier) {
            guard let recipientContactIdentifier = messageDraft.recipientContactIdentifier else { return }
            recipientPhoto = await ContactsDirectory.shared.thumbnailImage(forContactIdentifier: recipientContactIdentifier)
        }
        .onReceive(countdownTimer) { _ in
            refreshSecondsRemaining()
        }
        .onChange(of: expiryDate) { _, _ in
            refreshSecondsRemaining()
        }
        .onChange(of: isBubbleFocused) { _, isNowFocused in
            if isNowFocused { onEditingActivity() }
        }
    }

    private func refreshSecondsRemaining() {
        guard let expiryDate else { return }
        secondsRemaining = max(0, Int(expiryDate.timeIntervalSinceNow.rounded(.up)))
    }

    // MARK: - Recipient

    private var recipientHeader: some View {
        HStack(spacing: WispSpacing.sm + 2) {
            recipientAvatar

            VStack(alignment: .leading, spacing: 1) {
                Text(messageDraft.recipientDisplayName)
                    .font(WispFont.headline)
                    .foregroundColor(WispColor.OnGlass.textPrimary)
                    .lineLimit(1)
                if messageDraft.showsHandleUnderName {
                    Text(messageDraft.recipientHandle)
                        .font(WispFont.callout)
                        .foregroundColor(WispColor.OnGlass.textTertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: WispSpacing.sm)

            Text("\(secondsRemaining)s")
                .font(WispFont.mono)
                .foregroundColor(secondsRemaining <= 10 ? WispColor.destructiveText : WispColor.OnGlass.textTertiary)
        }
    }

    /// The contact's photo, or Contacts-style initials on a grey disc.
    private var recipientAvatar: some View {
        ZStack {
            if let recipientPhoto {
                Image(nsImage: recipientPhoto)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                initialsAvatar
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var initialsAvatar: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(nsColor: .systemGray), Color(nsColor: .darkGray)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            if let recipientInitials = messageDraft.recipientInitials {
                Text(recipientInitials)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
    }

    // MARK: - Message

    /// The text as it will appear in the thread: a right-aligned blue bubble,
    /// with the app it goes through underneath.
    private var messageBubble: some View {
        let bubbleShape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        return VStack(alignment: .trailing, spacing: 4) {
            bubbleText
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleShape.fill(messageBubbleFill))
                // Hover/focus ring: the bubble looks like a sent message until
                // the pointer finds it, then shows it can be edited.
                .overlay(
                    bubbleShape.strokeBorder(
                        Color.white.opacity(isBubbleFocused ? 0.7 : (isBubbleHovered ? 0.35 : 0)),
                        lineWidth: 1
                    )
                )
                .frame(maxWidth: 236, alignment: .trailing)
                .onHover { hovering in
                    guard editableMessageField != nil else { return }
                    isBubbleHovered = hovering
                    if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
                }
                .animation(WispMotion.quick, value: isBubbleHovered)
                .animation(WispMotion.quick, value: isBubbleFocused)

            HStack(spacing: WispSpacing.xs) {
                if isMessageEdited {
                    EditedConfirmationFieldMark()
                } else if editableMessageField != nil && (isBubbleHovered || isBubbleFocused) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(WispColor.OnGlass.textTertiary)
                }
                Text("Messages")
                    .font(WispFont.caption)
                    .foregroundColor(WispColor.OnGlass.textTertiary)
            }
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The message: an editable field that grows with its text when the panel
    /// allows edits (Return does not send — Cmd-Return does), plain
    /// selectable text otherwise.
    @ViewBuilder
    private var bubbleText: some View {
        if editableMessageField != nil {
            TextField("", text: Binding(get: { currentMessageText }, set: { onMessageTextChange($0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .lineLimit(1...8)
                .focused($isBubbleFocused)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Message, editable")
        } else {
            Text(messageDraft.messageText)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(8)
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: WispSpacing.sm) {
            Button("Cancel", action: onCancel)
                .wispGlassButtonStyle(prominence: .subtle)

            Button(action: onSend) {
                HStack(spacing: WispSpacing.xs) {
                    Text("Send")
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MessageSendButtonStyle(fill: messageBubbleFill))
            // Cmd-Return sends from inside the bubble; plain Return never does.
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

/// The Send button in iMessage blue, matching the bubble above it, so the one
/// action that sends reads as Messages' own send. Sized and shaped like the
/// Wisp glass buttons beside it.
private struct MessageSendButtonStyle: ButtonStyle {
    let fill: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let buttonShape = RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
        return configuration.label
            .font(WispFont.bodyMedium)
            .foregroundColor(.white)
            .padding(.horizontal, WispSpacing.md)
            .padding(.vertical, WispSpacing.sm + 1)
            // Hover brightens, press dims, like the glass buttons' fill states.
            .background(buttonShape.fill(fill.opacity(configuration.isPressed ? 0.75 : (isHovered ? 1.0 : 0.9))))
            .clipShape(buttonShape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : WispMotion.quick, value: configuration.isPressed)
            .animation(reduceMotion ? nil : WispMotion.quick, value: isHovered)
            .contentShape(buttonShape)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
