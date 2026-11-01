//
//  AgentWindowRimView.swift
//  A calm tint around the window Wisp is acting in.
//
//  The agent cursor says where the next click lands; it does not say which
//  window the next twenty actions belong to. This answers that with one even
//  rim of the accent and a soft fall inward. It deliberately does not move: a
//  task runs for minutes, and anything that breathes for that long pulls the eye
//  away from the work.
//
//  Draws only inside the given frame, takes no clicks, and is hidden from
//  VoiceOver (the notch's progress line already announces the task).
//

import SwiftUI

struct AgentWindowRimView: View {
    /// The window's frame in the display's own top-left point space.
    let windowFrameInDisplaySpace: CGRect
    @ObservedObject private var cursorAppearance = CursorAppearanceStore.shared

    /// The rounded corner of a macOS window, so the rim follows its shape.
    private let windowCornerRadius: CGFloat = 12

    var body: some View {
        let accent = cursorAppearance.color
        let windowShape = RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)

        ZStack {
            // A far, wide fall that takes the hue out slowly, so the window reads
            // as tinted rather than outlined.
            windowShape
                .strokeBorder(accent.opacity(0.16), lineWidth: 90)
                .blur(radius: 36)
            // A nearer fall that carries most of the hue.
            windowShape
                .strokeBorder(accent.opacity(0.32), lineWidth: 30)
                .blur(radius: 14)
            // The rim itself, even the whole way round.
            windowShape
                .strokeBorder(accent.opacity(0.85), lineWidth: 2)
        }
        .frame(width: windowFrameInDisplaySpace.width, height: windowFrameInDisplaySpace.height)
        // The blurred falls are meant to land inside the window, not spill over
        // the desktop around it.
        .clipShape(windowShape)
        .position(x: windowFrameInDisplaySpace.midX, y: windowFrameInDisplaySpace.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
