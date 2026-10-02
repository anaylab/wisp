//
//  WispCompanion.swift
//  leanring-buddy
//
//  Wisp's companion: a little cloud (the same character as a buddy's
//  `BuddyAvatar`, in Wisp's signature sage→lavender) that lives in the notch
//  and has feelings about what's going on. It breathes, blinks, watches the
//  cursor, hops when an agent finishes or something needs you, droops when
//  something fails, dozes off when nothing has happened for a while, and minds
//  being poked — three pokes in a row and it's dizzy.
//
//  `WispCompanionController` holds the short reactions (greeting, pokes,
//  celebrations); the mood itself is decided by the pure
//  `WispCompanionMoodResolver`. `WispCompanionFace` draws it. The clock only
//  runs while the face is on screen and animating, and Reduce Motion keeps
//  the expressions but drops the motion (no hops, shakes or eye tracking).
//
//  Off (Settings → General → Notch), the notch shows the Wisp mark as before.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Preference

@MainActor
final class WispCompanionPreference: ObservableObject {
    static let shared = WispCompanionPreference()
    private static let enabledKey = "wispCompanionEnabled"

    @Published var isCompanionEnabled: Bool {
        didSet { UserDefaults.standard.set(isCompanionEnabled, forKey: Self.enabledKey) }
    }

    private init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        isCompanionEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }
}

// MARK: - Controller

@MainActor
final class WispCompanionController: ObservableObject {
    static let shared = WispCompanionController()

    static let greetingSeconds: TimeInterval = 2.6
    static let celebrationSeconds: TimeInterval = 2.4
    static let commiserationSeconds: TimeInterval = 2.4

    @Published private(set) var activeReaction: WispCompanionReaction?
    /// When anything last happened; the companion dozes off after a long quiet.
    @Published private(set) var lastActivityDate = Date()

    private var pokeTracker = WispCompanionPokeTracker()
    private var reactionClearWorkItem: DispatchWorkItem?

    private init() {}

    /// Whether a reaction is playing — the notch shows itself for it, so a
    /// greeting or a celebration is seen even on an otherwise idle notch.
    var isReacting: Bool {
        guard let activeReaction else { return false }
        return activeReaction.endsAt > Date()
    }

    func greet() {
        play(.greeting, forSeconds: Self.greetingSeconds)
    }

    func celebrate() {
        play(.happy, forSeconds: Self.celebrationSeconds)
    }

    func commiserate() {
        play(.sad, forSeconds: Self.commiserationSeconds)
    }

    func poke() {
        noteActivity()
        let pokeReaction = pokeTracker.registerPoke(at: Date())
        if pokeReaction.mood == .dizzy {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        } else {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        setReaction(pokeReaction)
    }

    func noteActivity() {
        lastActivityDate = Date()
    }

    private func play(_ mood: WispCompanionMood, forSeconds durationSeconds: TimeInterval) {
        noteActivity()
        setReaction(WispCompanionReaction(mood: mood, endsAt: Date().addingTimeInterval(durationSeconds)))
    }

    private func setReaction(_ reaction: WispCompanionReaction) {
        activeReaction = reaction
        reactionClearWorkItem?.cancel()
        let clearWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.activeReaction == reaction else { return }
            self.activeReaction = nil
        }
        reactionClearWorkItem = clearWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, reaction.endsAt.timeIntervalSinceNow), execute: clearWorkItem)
    }
}

extension WispIslandState {
    /// The island's state, as the companion feels it.
    var companionActivity: WispCompanionActivity {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .processing, .executing, .responding: return .working
        case .preview: return .answerShowing
        case .confirmation: return .awaitingConfirmation
        case .success: return .succeeded
        case .error: return .failed
        }
    }
}

// MARK: - Face

struct WispCompanionFace: View {
    let mood: WispCompanionMood
    var size: CGFloat = 18
    /// Whether the pupils follow the cursor (only when the face is on screen
    /// and not too tiny to read).
    var followsCursor: Bool = true
    /// False pauses the clock entirely — used while the island is hidden.
    var isAnimating: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var faceCenterOnScreen: CGPoint?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating || reduceMotion)) { timeline in
            let elapsedSeconds = timeline.date.timeIntervalSinceReferenceDate
            let motion = bodyMotion(at: elapsedSeconds)
            ZStack {
                cloudBody
                    .scaleEffect(x: 1, y: motion.breathingScale, anchor: .bottom)
                Canvas { context, canvasSize in
                    drawFace(in: &context, canvasSize: canvasSize, elapsedSeconds: elapsedSeconds)
                }
                .frame(width: size, height: size)
                .allowsHitTesting(false)
            }
            .rotationEffect(.degrees(motion.tiltDegrees), anchor: .bottom)
            .offset(x: motion.horizontalOffset, y: motion.verticalOffset)
        }
        .frame(width: size, height: size)
        .background {
            // Only needed to aim the eyes at the cursor.
            if followsCursor {
                ScreenFrameReader { screenFrame in
                    let newCenter = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
                    if faceCenterOnScreen != newCenter { faceCenterOnScreen = newCenter }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var isMotionEnabled: Bool { isAnimating && !reduceMotion }

    // MARK: Body

    /// The cloud: the same four puffs as a buddy's avatar, merged into ONE
    /// path so a single gradient and shadow cover it without seams.
    private var cloudBody: some View {
        CloudPuffsShape()
            .fill(LinearGradient(colors: bodyColors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .shadow(color: bodyColors[1].opacity(0.55), radius: size * 0.14)
    }

    /// The cloud takes on the mood: lavender while it's busy or needs you, a
    /// warm rose when it's upset, sage otherwise. Deep enough that the white
    /// eyes always read.
    private var bodyColors: [Color] {
        switch mood {
        case .needsYou, .thinking, .working, .listening:
            return [WispColor.Brand.lavender, Color(red: 0.43, green: 0.41, blue: 0.69)]
        case .sad, .annoyed, .dizzy:
            return [Color(red: 0.80, green: 0.56, blue: 0.53), Color(red: 0.60, green: 0.37, blue: 0.35)]
        default:
            return [WispColor.Brand.sage, Color(red: 0.37, green: 0.42, blue: 0.34)]
        }
    }

    private struct BodyMotion {
        var breathingScale: CGFloat = 1
        var verticalOffset: CGFloat = 0
        var horizontalOffset: CGFloat = 0
        var tiltDegrees: Double = 0
    }

    private func bodyMotion(at elapsedSeconds: TimeInterval) -> BodyMotion {
        var motion = BodyMotion()
        guard isMotionEnabled else {
            if mood == .sad { motion.verticalOffset = size * 0.04 }
            return motion
        }
        let breathingSpeed = mood == .sleepy ? 1.2 : 2.2
        motion.breathingScale = 1 + 0.03 * CGFloat(sin(elapsedSeconds * breathingSpeed))
        switch mood {
        case .working:
            motion.verticalOffset = CGFloat(sin(elapsedSeconds * 3.2)) * size * 0.04
        case .happy:
            motion.verticalOffset = -CGFloat(abs(sin(elapsedSeconds * 6.5))) * size * 0.16
        case .needsYou:
            motion.verticalOffset = -CGFloat(abs(sin(elapsedSeconds * 4.2))) * size * 0.08
        case .greeting:
            motion.tiltDegrees = sin(elapsedSeconds * 9) * 10
            motion.verticalOffset = -CGFloat(abs(sin(elapsedSeconds * 4.5))) * size * 0.05
        case .annoyed:
            motion.horizontalOffset = CGFloat(sin(elapsedSeconds * 42)) * size * 0.05
        case .dizzy:
            motion.tiltDegrees = sin(elapsedSeconds * 4.5) * 9
        case .sad:
            motion.verticalOffset = size * 0.04
        case .content, .listening, .thinking, .sleepy:
            break
        }
        return motion
    }

    // MARK: Eyes

    private func drawFace(in context: inout GraphicsContext, canvasSize: CGSize, elapsedSeconds: TimeInterval) {
        let eyeSpacing = size * 0.17
        let eyeCenterY = size * 0.56
        let leftEyeCenter = CGPoint(x: size / 2 - eyeSpacing, y: eyeCenterY)
        let rightEyeCenter = CGPoint(x: size / 2 + eyeSpacing, y: eyeCenterY)
        let strokeWidth = max(1.1, size * 0.06)
        let eyeColor = Color.white

        switch mood {
        case .happy, .greeting:
            for eyeCenter in [leftEyeCenter, rightEyeCenter] {
                context.stroke(happyEyePath(centeredAt: eyeCenter), with: .color(eyeColor),
                               style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            }
            drawBlush(in: &context, leftEyeCenter: leftEyeCenter, rightEyeCenter: rightEyeCenter)

        case .sad:
            // Downcast eyes under worried brows (inner ends raised).
            let eyeWidth = size * 0.14
            let eyeHeight = size * 0.13
            let pupilDiameter = eyeWidth * 0.55
            for (eyeCenter, side) in [(leftEyeCenter, -1.0), (rightEyeCenter, 1.0)] {
                let lowerEyeCenter = CGPoint(x: eyeCenter.x, y: eyeCenter.y + size * 0.02)
                context.fill(Path(ellipseIn: CGRect(x: lowerEyeCenter.x - eyeWidth / 2, y: lowerEyeCenter.y - eyeHeight / 2,
                                                    width: eyeWidth, height: eyeHeight)), with: .color(eyeColor))
                context.fill(Path(ellipseIn: CGRect(x: lowerEyeCenter.x - pupilDiameter / 2,
                                                    y: lowerEyeCenter.y + eyeHeight / 2 - pupilDiameter,
                                                    width: pupilDiameter, height: pupilDiameter)), with: .color(WispColor.Brand.ink))
                var browPath = Path()
                let innerX = eyeCenter.x - CGFloat(side) * size * 0.07
                let outerX = eyeCenter.x + CGFloat(side) * size * 0.07
                browPath.move(to: CGPoint(x: innerX, y: eyeCenter.y - size * 0.13))
                browPath.addLine(to: CGPoint(x: outerX, y: eyeCenter.y - size * 0.075))
                context.stroke(browPath, with: .color(eyeColor), style: StrokeStyle(lineWidth: max(1, size * 0.045), lineCap: .round))
            }

        case .sleepy:
            for eyeCenter in [leftEyeCenter, rightEyeCenter] {
                var closedEyePath = Path()
                closedEyePath.move(to: CGPoint(x: eyeCenter.x - size * 0.06, y: eyeCenter.y))
                closedEyePath.addLine(to: CGPoint(x: eyeCenter.x + size * 0.06, y: eyeCenter.y))
                context.stroke(closedEyePath, with: .color(eyeColor), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            }
            if size >= 16 { drawSnooze(in: &context, elapsedSeconds: elapsedSeconds) }

        case .annoyed:
            context.stroke(chevronPath(centeredAt: leftEyeCenter, pointingRight: true), with: .color(eyeColor),
                           style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            context.stroke(chevronPath(centeredAt: rightEyeCenter, pointingRight: false), with: .color(eyeColor),
                           style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))

        case .dizzy:
            let spinAngle = isMotionEnabled ? Angle.radians(elapsedSeconds * 7) : .zero
            for eyeCenter in [leftEyeCenter, rightEyeCenter] {
                context.stroke(spiralPath(centeredAt: eyeCenter, rotation: spinAngle), with: .color(eyeColor),
                               style: StrokeStyle(lineWidth: max(0.8, size * 0.032), lineCap: .round))
            }

        case .content, .listening, .thinking, .working, .needsYou:
            drawOpenEyes(in: &context, eyeCenters: [leftEyeCenter, rightEyeCenter], elapsedSeconds: elapsedSeconds)
        }
    }

    private func drawOpenEyes(in context: inout GraphicsContext, eyeCenters: [CGPoint], elapsedSeconds: TimeInterval) {
        let eyeWidth = size * 0.15
        let openHeightScale: CGFloat
        switch mood {
        case .listening: openHeightScale = 1.15
        case .needsYou: openHeightScale = 1.25
        case .working: openHeightScale = 0.62
        default: openHeightScale = 1
        }
        let blinkOpenness = isMotionEnabled ? WispCompanionBlink.eyeOpenness(at: elapsedSeconds) : 1
        let eyeHeight = max(size * 0.03, size * 0.19 * openHeightScale * blinkOpenness)
        let pupilDiameter = eyeWidth * (mood == .needsYou || mood == .listening ? 0.5 : 0.62)
        let pupilTravel = CGSize(width: (eyeWidth - pupilDiameter) / 2, height: max(0, (eyeHeight - pupilDiameter) / 2))
        let gaze = currentGaze(elapsedSeconds: elapsedSeconds)

        for eyeCenter in eyeCenters {
            let eyeRect = CGRect(x: eyeCenter.x - eyeWidth / 2, y: eyeCenter.y - eyeHeight / 2, width: eyeWidth, height: eyeHeight)
            context.fill(Path(ellipseIn: eyeRect), with: .color(.white))
            // A nearly shut eye (mid-blink, focused) shows no pupil.
            guard eyeHeight > pupilDiameter * 0.8 else { continue }
            let pupilCenter = CGPoint(
                x: eyeCenter.x + gaze.dx * pupilTravel.width,
                y: eyeCenter.y + gaze.dy * pupilTravel.height
            )
            let pupilRect = CGRect(x: pupilCenter.x - pupilDiameter / 2, y: pupilCenter.y - pupilDiameter / 2,
                                   width: pupilDiameter, height: pupilDiameter)
            context.fill(Path(ellipseIn: pupilRect), with: .color(WispColor.Brand.ink))
        }
    }

    /// Where the eyes look: up and aside while thinking, at the cursor
    /// otherwise (when allowed), straight ahead with motion off.
    private func currentGaze(elapsedSeconds: TimeInterval) -> CGVector {
        if mood == .thinking {
            let drift = isMotionEnabled ? CGFloat(sin(elapsedSeconds * 0.9)) * 0.25 : 0
            return CGVector(dx: 0.65 + drift, dy: -0.8)
        }
        guard isMotionEnabled, followsCursor, let faceCenterOnScreen else { return CGVector(dx: 0, dy: 0) }
        return WispCompanionGaze.pupilOffset(faceCenter: faceCenterOnScreen, cursorLocation: NSEvent.mouseLocation)
    }

    private func drawBlush(in context: inout GraphicsContext, leftEyeCenter: CGPoint, rightEyeCenter: CGPoint) {
        guard size >= 14 else { return }
        let blushSize = CGSize(width: size * 0.11, height: size * 0.06)
        for (eyeCenter, side) in [(leftEyeCenter, -1.0), (rightEyeCenter, 1.0)] {
            let blushRect = CGRect(
                x: eyeCenter.x + CGFloat(side) * size * 0.07 - blushSize.width / 2,
                y: eyeCenter.y + size * 0.08,
                width: blushSize.width,
                height: blushSize.height
            )
            context.fill(Path(ellipseIn: blushRect), with: .color(Color(red: 0.96, green: 0.62, blue: 0.70).opacity(0.75)))
        }
    }

    private func drawSnooze(in context: inout GraphicsContext, elapsedSeconds: TimeInterval) {
        let floatProgress = isMotionEnabled ? CGFloat((elapsedSeconds * 0.5).truncatingRemainder(dividingBy: 1)) : 0.4
        let snoozeText = Text("z").font(.system(size: size * 0.32, weight: .bold, design: .rounded)).foregroundColor(.white)
        context.opacity = Double(1 - floatProgress)
        context.draw(snoozeText, at: CGPoint(x: size * 0.86, y: size * (0.36 - 0.24 * floatProgress)))
        context.opacity = 1
    }

    private func happyEyePath(centeredAt eyeCenter: CGPoint) -> Path {
        var eyePath = Path()
        let halfWidth = size * 0.07
        eyePath.move(to: CGPoint(x: eyeCenter.x - halfWidth, y: eyeCenter.y + size * 0.025))
        eyePath.addQuadCurve(to: CGPoint(x: eyeCenter.x + halfWidth, y: eyeCenter.y + size * 0.025),
                             control: CGPoint(x: eyeCenter.x, y: eyeCenter.y - size * 0.08))
        return eyePath
    }

    /// ">" for the left eye, "<" for the right — squeezed shut.
    private func chevronPath(centeredAt eyeCenter: CGPoint, pointingRight: Bool) -> Path {
        var chevron = Path()
        let halfWidth = size * 0.05
        let halfHeight = size * 0.055
        let tipX = pointingRight ? eyeCenter.x + halfWidth : eyeCenter.x - halfWidth
        let tailX = pointingRight ? eyeCenter.x - halfWidth : eyeCenter.x + halfWidth
        chevron.move(to: CGPoint(x: tailX, y: eyeCenter.y - halfHeight))
        chevron.addLine(to: CGPoint(x: tipX, y: eyeCenter.y))
        chevron.addLine(to: CGPoint(x: tailX, y: eyeCenter.y + halfHeight))
        return chevron
    }

    private func spiralPath(centeredAt eyeCenter: CGPoint, rotation: Angle) -> Path {
        var spiral = Path()
        let maximumRadius = size * 0.09
        let pointCount = 36
        for pointIndex in 0...pointCount {
            let progress = Double(pointIndex) / Double(pointCount)
            // Two and a half turns: enough to read as a spiral, open enough
            // not to fill in at notch size.
            let angle = progress * 5 * .pi + rotation.radians
            let radius = maximumRadius * CGFloat(progress)
            let spiralPoint = CGPoint(x: eyeCenter.x + radius * CGFloat(cos(angle)), y: eyeCenter.y + radius * CGFloat(sin(angle)))
            if pointIndex == 0 { spiral.move(to: spiralPoint) } else { spiral.addLine(to: spiralPoint) }
        }
        return spiral
    }
}

/// Four overlapping puffs as one path (filled with the non-zero rule, so
/// overlaps don't cancel out).
private struct CloudPuffsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let puffLayout: [(x: CGFloat, y: CGFloat, diameter: CGFloat)] = [
            (0.30, 0.56, 0.50),
            (0.50, 0.42, 0.60),
            (0.71, 0.55, 0.50),
            (0.50, 0.64, 0.56),
        ]
        var cloudPath = Path()
        for puff in puffLayout {
            let puffDiameter = rect.width * puff.diameter
            cloudPath.addEllipse(in: CGRect(
                x: rect.minX + rect.width * puff.x - puffDiameter / 2,
                y: rect.minY + rect.height * puff.y - puffDiameter / 2,
                width: puffDiameter,
                height: puffDiameter
            ))
        }
        return cloudPath
    }
}

// MARK: - Screen position

/// Reports its view's frame in screen coordinates, so the face knows where it
/// sits relative to the cursor. Re-reported when the view moves or resizes.
private struct ScreenFrameReader: NSViewRepresentable {
    let onScreenFrameChange: (CGRect) -> Void

    func makeNSView(context: Context) -> ScreenFrameReportingView {
        let reportingView = ScreenFrameReportingView()
        reportingView.onScreenFrameChange = onScreenFrameChange
        return reportingView
    }

    func updateNSView(_ nsView: ScreenFrameReportingView, context: Context) {
        nsView.onScreenFrameChange = onScreenFrameChange
        nsView.reportScreenFrame()
    }
}

private final class ScreenFrameReportingView: NSView {
    var onScreenFrameChange: ((CGRect) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportScreenFrame()
    }

    override func layout() {
        super.layout()
        reportScreenFrame()
    }

    func reportScreenFrame() {
        guard let window else { return }
        let screenFrame = window.convertToScreen(convert(bounds, to: nil))
        let onScreenFrameChange = self.onScreenFrameChange
        // Out of the layout pass, so setting SwiftUI state here is safe.
        DispatchQueue.main.async { onScreenFrameChange?(screenFrame) }
    }
}

// MARK: - The notch's companion

/// The companion as the notch shows it: the mood worked out from Wisp's live
/// state, clickable to poke. Shown in place of the Wisp mark while the
/// companion is on.
struct NotchCompanion: View {
    @ObservedObject var companionManager: CompanionManager
    var size: CGFloat
    var isPokeable: Bool
    var isAnimating: Bool
    @ObservedObject private var companionController = WispCompanionController.shared
    @ObservedObject private var codingAgentSessionStore = CodingAgentSessionStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared

    var body: some View {
        // Re-evaluated at least every 30s so dozing off happens without an event.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let face = WispCompanionFace(
                mood: mood(at: timeline.date),
                size: size,
                followsCursor: size >= 14,
                isAnimating: isAnimating
            )
            if isPokeable {
                face
                    .contentShape(Rectangle())
                    .onTapGesture { companionController.poke() }
                    .pointerCursor()
                    .nativeTooltip("Hi! (Don't poke too much.)")
            } else {
                face
            }
        }
    }

    private func mood(at now: Date) -> WispCompanionMood {
        let busyCodingSessionCount = codingAgentSessionStore.busySessions.count
        let runningBackgroundTaskCount = taskRegistry.records.filter { $0.kind == .background && !$0.status.isTerminal }.count
        let signals = WispCompanionSignals(
            activity: companionManager.islandState.companionActivity,
            hasPendingCodingAgentApproval: !codingAgentSessionStore.pendingApprovals.isEmpty,
            busyWorkCount: busyCodingSessionCount + runningBackgroundTaskCount,
            secondsSinceLastActivity: now.timeIntervalSince(companionController.lastActivityDate),
            activeReaction: companionController.activeReaction
        )
        return WispCompanionMoodResolver.mood(for: signals, at: now)
    }
}
