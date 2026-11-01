//
//  AgentCursorView.swift
//  The cursor Wisp draws while it is acting for the user (the browser loop),
//  as opposed to the pulsing marker it draws to point something out.
//
//  One persistent dart per display glides from each point to the next along a
//  planned move (`AgentCursorMotion`), instead of a marker popping in at every
//  step. The dart's tip is the point the agent aimed at, so the cursor stands on
//  the right spot even if animation is off.
//

import SwiftUI

/// Where the agent cursor should stand on one display, in that display's own
/// top-left point space, and what it is about to do there.
struct AgentCursorTarget: Equatable {
    let pointInDisplaySpace: CGPoint
    let actionText: String
}

struct AgentCursorView: View {
    let target: AgentCursorTarget
    @ObservedObject private var cursorAppearance = CursorAppearanceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the cursor rests when no move is playing: the last target reached.
    @State private var restingPoint: CGPoint
    /// The move being played, and when it began.
    @State private var currentMove: AgentCursorMove = []
    @State private var currentMoveStartDate = Date()
    /// Whether the clock needs to run. Off at rest so the overlay costs nothing.
    @State private var isAnimating = false
    @State private var settleTask: Task<Void, Never>?

    /// How long the arrival ring takes to fade, after the glide ends.
    private let arrivalRingMilliseconds: Double = 450

    init(target: AgentCursorTarget) {
        self.target = target
        _restingPoint = State(initialValue: target.pointInDisplaySpace)
    }

    var body: some View {
        TimelineView(.animation(paused: !isAnimating)) { timeline in
            let elapsedMilliseconds = timeline.date.timeIntervalSince(currentMoveStartDate) * 1000
            let glideMilliseconds = AgentCursorMotion.durationMilliseconds(of: currentMove)
            let cursorPoint = AgentCursorMotion.point(on: currentMove, atElapsedMilliseconds: elapsedMilliseconds)
                ?? restingPoint
            let arrivalProgress = glideMilliseconds > 0
                ? min(1, max(0, (elapsedMilliseconds - glideMilliseconds) / arrivalRingMilliseconds))
                : 1

            ZStack {
                // A ring that opens and fades where the cursor lands, so the
                // spot registers a beat before the click.
                if arrivalProgress < 1 {
                    Circle()
                        .stroke(cursorAppearance.color.opacity(0.55 * (1 - arrivalProgress)), lineWidth: 2)
                        .frame(width: 20 + 26 * arrivalProgress, height: 20 + 26 * arrivalProgress)
                        .position(cursorPoint)
                }

                AgentCursorDart()
                    .fill(cursorAppearance.color)
                    .overlay(AgentCursorDart().stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
                    .frame(width: 18, height: 20)
                    // The dart's tip is its top-left corner, so anchor there.
                    .offset(x: 9, y: 10)
                    .position(cursorPoint)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)

                if !target.actionText.isEmpty {
                    Text(target.actionText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .fixedSize()
                        .position(x: cursorPoint.x + 18, y: cursorPoint.y + 30)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: target.pointInDisplaySpace) { newPoint in
            travel(to: newPoint)
        }
    }

    /// Starts a move from wherever the cursor is on screen right now (not from
    /// where an interrupted move was heading) to the new point.
    private func travel(to newPoint: CGPoint) {
        let pointOnScreenNow = AgentCursorMotion.point(
            on: currentMove,
            atElapsedMilliseconds: Date().timeIntervalSince(currentMoveStartDate) * 1000
        ) ?? restingPoint

        settleTask?.cancel()
        restingPoint = newPoint

        if reduceMotion {
            currentMove = []
            isAnimating = false
            return
        }

        currentMove = AgentCursorMotion.planMove(from: pointOnScreenNow, to: newPoint)
        currentMoveStartDate = Date()
        let runMilliseconds = AgentCursorMotion.durationMilliseconds(of: currentMove) + arrivalRingMilliseconds + 50
        isAnimating = !currentMove.isEmpty
        settleTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(runMilliseconds * 1_000_000))
            if !Task.isCancelled {
                isAnimating = false
            }
        }
    }
}

/// A dart with its tip at the top-left corner: a shape no desktop pointer has,
/// so it reads as "something other than the user is driving".
private struct AgentCursorDart: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.41))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.63))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.31, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
