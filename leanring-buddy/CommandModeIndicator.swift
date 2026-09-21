//
//  CommandModeIndicator.swift
//  leanring-buddy
//
//  A brief on-screen badge naming which push-to-talk gesture the user just
//  triggered — Talk, Dictate, Type or Hands-free.
//
//  The four modes look identical while they are happening: the same chord,
//  held or tapped, with one extra modifier deciding whether your words are
//  answered aloud or typed into whatever field has focus. That one modifier is
//  the whole design, so the moment it takes effect is exactly when the user
//  needs to be told what it did. This badge is that feedback. It restores what
//  the old cursor waveform's dictation label used to show, now that the cursor
//  is gone, and it does it centred under the notch where the user is looking
//  rather than beside a cursor they are no longer watching.
//

import SwiftUI

/// Which push-to-talk gesture the user just triggered. Set on `CompanionManager`
/// when a gesture fires and cleared when it ends; observed by the overlay so it
/// can show the matching badge on the screen the user is looking at.
enum PushToTalkCommandMode: Equatable {
    /// Hold the chord: a spoken question, answered aloud and in the notch.
    case talk
    /// Hold the chord + shift: your words are typed into the focused field.
    case dictate(destination: String)
    /// Tap the chord: the text composer opens to type a question.
    case type
    /// Double-tap a bare modifier: dictation without a key held down.
    case handsFree(destination: String)

    /// The label shown on the badge.
    var title: String {
        switch self {
        case .talk: return "Talk"
        case .dictate: return "Dictating"
        case .type: return "Type"
        case .handsFree: return "Hands-free"
        }
    }

    /// An SF Symbol naming the action.
    var iconSystemName: String {
        switch self {
        case .talk: return "mic.fill"
        case .dictate: return "character.cursor.ibeam"
        case .type: return "keyboard"
        case .handsFree: return "waveform"
        }
    }

    /// The app the dictated text will land in, when this mode routes text into a
    /// field. Nil for the modes that answer a question instead.
    var destination: String? {
        switch self {
        case .dictate(let destination), .handsFree(let destination):
            let trimmed = destination.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case .talk, .type:
            return nil
        }
    }

    /// Whether this mode types your words into a field rather than answering a
    /// question. The two families are tinted differently — a wrong guess here is
    /// the mistake the badge exists to prevent — so this drives the colour.
    var routesTextIntoField: Bool {
        switch self {
        case .dictate, .handsFree: return true
        case .talk, .type: return false
        }
    }
}

/// The badge itself: a small glass capsule with an icon and label, and — for the
/// dictation modes — the destination app, since "I thought I was in Slack" is the
/// other way this goes wrong and it is only recoverable before you speak.
struct CommandModeIndicator: View {
    let mode: PushToTalkCommandMode

    /// Green for the modes that type into a field, the brand accent for the ones
    /// that answer a question. Colour alone is a weak signal, so the icon and
    /// label carry the meaning and the tint only reinforces it.
    private var tint: Color {
        mode.routesTextIntoField ? DS.Colors.success : DS.Colors.accent
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: mode.iconSystemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)

            Text(mode.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            if let destination = mode.destination {
                // A soft divider then the destination, so "Dictating → Notes"
                // reads as one phrase without the arrow crowding the label.
                Text("→")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(destination)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
        )
        .fixedSize()
    }
}
