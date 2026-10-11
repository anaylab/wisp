//
//  SchedulingCardComponents.swift
//  leanring-buddy
//
//  Small pieces shared by the Siri-style calendar and reminder panels — the
//  confirmation panel (`SchedulingConfirmationView`) and the result cards in
//  the notch — so asking and confirming look like one object:
//
//  • `CalendarDateTile`: Calendar's own icon shape — weekday on a red band,
//    the day number large beneath — so an event reads as "a date" at a glance.
//  • `ReminderCheckRing`: the empty ring Reminders draws as each item's
//    checkbox, in the list's colour.
//  • `InlineEditableTitle`: a title that reads as plain text until hovered or
//    clicked, then edits in place (the message bubble's pattern), for the
//    one field the user most often wants to fix.
//
//  System red and the list colours are deliberate, not brand tokens: like the
//  iMessage blue on the message panel, they say "this is Calendar/Reminders".
//

import AppKit
import SwiftUI

struct CalendarDateTile: View {
    let date: Date
    var size: CGFloat = 52

    private var weekdayText: String {
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")
        return weekdayFormatter.string(from: date).uppercased()
    }

    private var dayNumberText: String {
        String(Calendar.current.component(.day, from: date))
    }

    var body: some View {
        let tileShape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        VStack(spacing: 0) {
            Text(weekdayText)
                .font(.system(size: size * 0.19, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: size * 0.3)
                .background(Color(nsColor: .systemRed))
            Text(dayNumberText)
                .font(.system(size: size * 0.44, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        }
        .frame(width: size, height: size)
        .clipShape(tileShape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SchedulingPhrasing.fullDayText(for: date))
    }
}

struct ReminderCheckRing: View {
    let color: Color
    var diameter: CGFloat = 20

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 2)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

/// A title shown as large text that becomes a text field on hover/click.
/// Nil `onTextChange` makes it plain, non-editable text.
struct InlineEditableTitle: View {
    let text: String
    let isEdited: Bool
    let onTextChange: ((String) -> Void)?
    let onEditingActivity: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        let fieldShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: WispSpacing.xs) {
            if let onTextChange {
                TextField("", text: Binding(get: { text }, set: onTextChange), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(WispColor.OnGlass.textPrimary)
                    .lineLimit(1...3)
                    .focused($isFocused)
                    .accessibilityLabel("Title, editable")
            } else {
                Text(text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(WispColor.OnGlass.textPrimary)
                    .lineLimit(3)
            }
            if isEdited {
                EditedConfirmationFieldMark()
            } else if onTextChange != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WispColor.OnGlass.textTertiary)
                    .opacity(isHovered || isFocused ? 1 : 0)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(fieldShape.fill(onTextChange != nil && (isHovered || isFocused) ? WispColor.OnGlass.chipFill : Color.clear))
        .overlay(fieldShape.strokeBorder(isFocused ? WispColor.OnGlass.borderStrong : Color.clear, lineWidth: 0.75))
        // Pulled back by its own padding so the text lines up with the rows
        // below it while at rest.
        .padding(.horizontal, -6)
        .contentShape(fieldShape)
        .onTapGesture { if onTextChange != nil { isFocused = true } }
        .onHover { hovering in
            guard onTextChange != nil else { return }
            isHovered = hovering
            if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
        }
        .onChange(of: isFocused) { _, isNowFocused in
            if isNowFocused { onEditingActivity() }
        }
        .animation(WispMotion.quick, value: isHovered)
        .animation(WispMotion.quick, value: isFocused)
    }
}
