//
//  NoteCardView.swift
//  leanring-buddy
//
//  What a note card looks like (docs/note-cards-plan.md): dark glass like the notch
//  and overlay, since it sits over arbitrary content. `NoteCardTetherView` is the
//  other half — the click-through layer that draws the line from the card to what it
//  explains, and a numbered pin at each step's spot.
//

import SwiftUI

struct NoteCardView: View {
    @ObservedObject var manager: NoteCardManager
    let cardID: UUID

    private let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    private let maximumThreadHeight: CGFloat = 240
    /// The thread's natural height, measured, so it scrolls only once it passes the maximum.
    @State private var threadContentHeight: CGFloat = 0
    /// The card as it last was. A closing card is already gone from the manager while its window
    /// fades out, and the view keeps showing this instead of going blank.
    @State private var lastKnownCard: NoteCard?
    @State private var hasAppeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        if let card = manager.cards.first(where: { $0.id == cardID }) ?? lastKnownCard {
            VStack(alignment: .leading, spacing: 0) {
                header(for: card)
                if !card.isCollapsed {
                    Divider().overlay(WispColor.OnGlass.borderSubtle)
                    stepList(for: card)
                    if !card.thread.isEmpty { threadSection(for: card) }
                    if card.steps.count > 1 { stepper(for: card) }
                    actionsRow(for: card)
                    if !card.isDetached {
                        NoteCardComposer(manager: manager, cardID: cardID, isAnswering: card.isAnswering)
                    }
                }
            }
            .frame(width: NoteCardGeometry.cardWidth)
            // Near-black like the notch island: glass over a light page read as mid-grey,
            // which left the quieter steps hard to read.
            .background(cardShape.fill(WispColor.Island.surface.opacity(0.94)))
            .overlay(cardShape.stroke(
                colorSchemeContrast == .increased ? Color.white.opacity(0.7) : WispColor.OnGlass.borderStrong,
                lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
            ))
            .clipShape(cardShape)
            // The panel is borderless and never key, so it can't be dragged by its background:
            // the drag moves the window explicitly. Simultaneous, so buttons still get plain clicks.
            .simultaneousGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in manager.dragCard(cardID: cardID) }
                    .onEnded { _ in manager.endDrag(cardID: cardID) }
            )
            // Report the real height so the window can follow it; the window is a guess until then.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                manager.contentHeightChanged(forCardID: cardID, to: height)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // Springs in; with Reduce Motion it only fades.
            .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.94)
            .opacity(hasAppeared ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : WispMotion.settle) { hasAppeared = true }
            }
            .animation(reduceMotion ? nil : WispMotion.quick, value: card.activeStepIndex)
            .onReceive(manager.$cards) { cards in
                if let currentCard = cards.first(where: { $0.id == cardID }) { lastKnownCard = currentCard }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Wisp explanation")
        }
    }

    // MARK: Header

    private func header(for card: NoteCard) -> some View {
        HStack(spacing: 8) {
            WispMark(state: .idle, size: 14, animated: false)
                // The word beside it already says it.
                .accessibilityHidden(true)
            Text("Wisp")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(WispColor.OnGlass.textPrimary)
            if card.steps.count > 1 {
                Text("\(card.activeStepIndex + 1)/\(card.steps.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WispColor.OnGlass.textTertiary)
            }
            Spacer()
            headerButton(symbol: card.isPinned ? "pin.fill" : "pin", label: card.isPinned ? "Unpin" : "Pin") {
                manager.togglePin(cardID: cardID)
            }
            headerButton(symbol: card.isCollapsed ? "chevron.down" : "chevron.up", label: card.isCollapsed ? "Expand" : "Collapse") {
                manager.toggleCollapse(cardID: cardID)
            }
            headerButton(symbol: "xmark", label: "Close") {
                manager.close(cardID: cardID)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NoteCardGeometry.headerHeight)
        .contentShape(Rectangle())
    }

    private func headerButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WispColor.OnGlass.textSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(WispColor.OnGlass.chipFill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .pointerCursorOnHover()
    }

    // MARK: Steps

    private func stepList(for card: NoteCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(card.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, index: index, in: card)
            }
            if card.isDetached {
                Text("The screen has moved on, so I'm no longer pointing at anything.")
                    .font(.system(size: 11))
                    .foregroundColor(WispColor.OnGlass.textTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stepRow(_ step: NoteCardStep, index: Int, in card: NoteCard) -> some View {
        let isMultiStep = card.steps.count > 1
        let isActive = index == card.activeStepIndex
        let rowContent = HStack(alignment: .top, spacing: 8) {
            if isMultiStep {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isActive ? .black : WispColor.OnGlass.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(isActive ? Color.white : WispColor.OnGlass.chipFill))
            }
            Text(Self.formatted(step.text))
                .font(.system(size: 13))
                .foregroundColor(isActive || !isMultiStep ? WispColor.OnGlass.textPrimary : WispColor.OnGlass.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isMultiStep && isActive ? WispColor.OnGlass.chipFill : Color.clear)
        )
        .contentShape(Rectangle())

        if isMultiStep {
            HStack(alignment: .top, spacing: 2) {
                Button {
                    manager.setActiveStep(forCardID: cardID, to: index)
                } label: { rowContent }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Step \(index + 1): \(NoteCardFollowUp.spokenText(fromMarkdown: step.text))")
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                    .pointerCursorOnHover()
                // Pops this step out into a card of its own.
                Button {
                    manager.tearOffStep(forCardID: cardID, stepIndex: index)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(WispColor.OnGlass.textTertiary)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pop out step \(index + 1)")
                .pointerCursorOnHover()
            }
        } else {
            rowContent
        }
    }

    // MARK: Thread

    private func threadSection(for card: NoteCard) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(WispColor.OnGlass.borderSubtle)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(card.thread) { message in
                        messageBubble(message)
                    }
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { threadContentHeight = $0 }
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: min(max(threadContentHeight, 1), maximumThreadHeight))
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: NoteCardMessage) -> some View {
        let isUser = message.role == .user
        let waitingForFirstWords = message.isStreaming && message.text.isEmpty
        Text(waitingForFirstWords ? AttributedString("Thinking…") : Self.formatted(message.text))
            .font(.system(size: 13))
            .foregroundColor(
                isUser ? WispColor.OnGlass.textPrimary
                    : (message.isFailure || waitingForFirstWords ? WispColor.OnGlass.textTertiary : WispColor.OnGlass.textSecondary)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isUser ? WispColor.OnGlass.borderSubtle : WispColor.OnGlass.chipFill)
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .textSelection(.enabled)
            .accessibilityLabel(
                isUser ? "You asked: \(message.text)"
                    : (waitingForFirstWords ? "Wisp is thinking" : "Wisp: \(NoteCardFollowUp.spokenText(fromMarkdown: message.text))")
            )
    }

    // MARK: Actions

    /// One-tap follow-ups on the left, copy and save on the right.
    private func actionsRow(for card: NoteCard) -> some View {
        HStack(spacing: 6) {
            if !card.isDetached {
                ForEach(NoteCardFollowUp.Chip.allCases, id: \.self) { chip in
                    Button {
                        manager.submitFollowUp(cardID: cardID, question: chip.question)
                    } label: {
                        Text(chip.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(WispColor.OnGlass.textPrimary)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(WispColor.OnGlass.chipFill))
                            .overlay(Capsule().stroke(WispColor.OnGlass.borderSubtle, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(card.isAnswering)
                    .opacity(card.isAnswering ? 0.35 : 1)
                    .accessibilityLabel(chip.title)
                    .pointerCursorOnHover()
                }
            }
            Spacer(minLength: 0)
            NoteCardCopyButton(manager: manager, cardID: cardID)
            if manager.canSaveWorkedSolution(forCardID: cardID) {
                actionIconButton(symbol: "square.and.arrow.down", label: "Save worked solution") {
                    manager.saveWorkedSolution(forCardID: cardID)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func actionIconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WispColor.OnGlass.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(WispColor.OnGlass.chipFill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .pointerCursorOnHover()
    }

    // MARK: Stepper

    private func stepper(for card: NoteCard) -> some View {
        HStack(spacing: 8) {
            Spacer()
            stepButton(symbol: "chevron.left", label: "Previous step", isEnabled: card.activeStepIndex > 0) {
                manager.setActiveStep(forCardID: cardID, to: card.activeStepIndex - 1)
            }
            stepButton(symbol: "chevron.right", label: "Next step", isEnabled: card.activeStepIndex < card.steps.count - 1) {
                manager.setActiveStep(forCardID: cardID, to: card.activeStepIndex + 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func stepButton(symbol: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(WispColor.OnGlass.textPrimary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(WispColor.OnGlass.chipFill))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .pointerCursorOnHover()
    }

    /// Inline markdown (bold, code) when the text has it; the plain text otherwise.
    private static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Copy button

/// Copies the card's text and says so for a moment, since the clipboard gives no other sign.
private struct NoteCardCopyButton: View {
    @ObservedObject var manager: NoteCardManager
    let cardID: UUID

    @State private var didJustCopy = false

    var body: some View {
        Button {
            manager.copyText(forCardID: cardID)
            didJustCopy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                didJustCopy = false
            }
        } label: {
            Image(systemName: didJustCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(didJustCopy ? WispColor.OnGlass.textPrimary : WispColor.OnGlass.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(WispColor.OnGlass.chipFill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didJustCopy ? "Copied" : "Copy")
        .pointerCursorOnHover()
    }
}

// MARK: - Composer

/// The follow-up field at the foot of a card. It reads as text until clicked: the click is what
/// asks the panel for the keyboard, so dragging or clicking elsewhere on the card never does.
private struct NoteCardComposer: View {
    @ObservedObject var manager: NoteCardManager
    let cardID: UUID
    let isAnswering: Bool

    @State private var draftQuestion = ""
    @State private var isEditing = false
    @FocusState private var fieldHasFocus: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                TextField("Ask a follow-up…", text: $draftQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(WispColor.OnGlass.textPrimary)
                    .focused($fieldHasFocus)
                    .onSubmit(send)
            } else {
                Text(draftQuestion.isEmpty ? "Ask a follow-up…" : draftQuestion)
                    .font(.system(size: 13))
                    .foregroundColor(WispColor.OnGlass.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Reads as a field to VoiceOver, which can press it without the panel being key.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Ask a follow-up")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { startEditing() }
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(isAnswering || draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(isAnswering || draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
            .accessibilityLabel("Send")
            .pointerCursorOnHover()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(WispColor.OnGlass.chipFill)
        .contentShape(Rectangle())
        .onTapGesture { startEditing() }
        .onChange(of: fieldHasFocus) { _, hasFocus in
            if !hasFocus { isEditing = false }
        }
    }

    private func startEditing() {
        guard !isEditing else { return }
        isEditing = true
        manager.requestKeyboardFocus(forCardID: cardID)
        // The panel has to be key before the field can take focus.
        DispatchQueue.main.async { fieldHasFocus = true }
    }

    private func send() {
        guard !isAnswering else { return }
        manager.submitFollowUp(cardID: cardID, question: draftQuestion)
        draftQuestion = ""
    }
}

// MARK: - Tether and pins

struct NoteCardTetherView: View {
    @ObservedObject var manager: NoteCardManager
    let cardID: UUID
    let displayFrameInAppKitPoints: CGRect

    @ObservedObject private var cursorAppearance = CursorAppearanceStore.shared

    var body: some View {
        if let card = manager.cards.first(where: { $0.id == cardID }),
           !card.isDetached,
           let cardFrame = manager.cardFramesInAppKitPoints[cardID] {
            let accent = cursorAppearance.color
            let cardInOverlay = CGRect(
                x: cardFrame.minX - displayFrameInAppKitPoints.minX,
                y: displayFrameInAppKitPoints.maxY - cardFrame.maxY,
                width: cardFrame.width,
                height: cardFrame.height
            )
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    guard let activeStep = card.activeStep else { return }
                    let endPoint = NoteCardGeometry.tetherEndPoint(
                        anchorRect: activeStep.anchorRectInOverlayPoints,
                        nearestTo: CGPoint(x: cardInOverlay.midX, y: cardInOverlay.midY)
                    )
                    // The line leaves from whichever card edge midpoint is nearest its end.
                    let edgeMidpoints = [
                        CGPoint(x: cardInOverlay.minX, y: cardInOverlay.midY),
                        CGPoint(x: cardInOverlay.maxX, y: cardInOverlay.midY),
                        CGPoint(x: cardInOverlay.midX, y: cardInOverlay.minY),
                        CGPoint(x: cardInOverlay.midX, y: cardInOverlay.maxY)
                    ]
                    let startPoint = edgeMidpoints.min {
                        hypot($0.x - endPoint.x, $0.y - endPoint.y) < hypot($1.x - endPoint.x, $1.y - endPoint.y)
                    } ?? endPoint

                    var tether = Path()
                    tether.move(to: startPoint)
                    tether.addLine(to: endPoint)
                    context.stroke(tether, with: .color(accent.opacity(0.28)), lineWidth: 5)
                    context.stroke(tether, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    context.fill(
                        Path(ellipseIn: CGRect(x: endPoint.x - 3, y: endPoint.y - 3, width: 6, height: 6)),
                        with: .color(accent)
                    )
                }

                if card.steps.count > 1 {
                    ForEach(Array(card.steps.enumerated()), id: \.element.id) { index, step in
                        pin(number: index + 1, isActive: index == card.activeStepIndex, accent: accent)
                            .position(x: step.anchorRectInOverlayPoints.minX, y: step.anchorRectInOverlayPoints.minY)
                    }
                }
            }
            .allowsHitTesting(false)
            // Decoration: the card itself says everything the tether and pins show.
            .accessibilityHidden(true)
        }
    }

    private func pin(number: Int, isActive: Bool, accent: Color) -> some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(isActive ? .white : accent)
            .frame(width: isActive ? 22 : 18, height: isActive ? 22 : 18)
            .background(Circle().fill(isActive ? accent : Color.black.opacity(0.55)))
            .overlay(Circle().stroke(isActive ? Color.white.opacity(0.9) : accent, lineWidth: 1.5))
    }
}

private extension View {
    /// Pointing hand while over a control, as the rest of Wisp does for buttons.
    func pointerCursorOnHover() -> some View {
        onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
