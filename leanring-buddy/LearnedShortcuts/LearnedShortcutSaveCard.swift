//
//  LearnedShortcutSaveCard.swift
//  leanring-buddy
//
//  The "Save as shortcut" card: the phrase (editable), which parts of it can change from run to
//  run, and the exact steps that will be replayed. Shown in a native alert for the same reason
//  `RoutineParameterPrompt` is: the offer comes from the notch, which can't host a sheet.
//
//  Saving is the user's consent to those steps. Replays still go through the tool registry, so
//  anything that needed a confirmation card then still needs one.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class LearnedShortcutSaveCardModel: ObservableObject {
    private let originalDraft: LearnedShortcutDraft

    @Published var phraseText: String {
        didSet { revalidate() }
    }
    @Published private(set) var blankSlotNames: Set<String>
    /// Why Save is off, in plain words. Nil when the card can be saved.
    @Published private(set) var problemText: String?

    init(draft: LearnedShortcutDraft) {
        originalDraft = draft
        phraseText = draft.phraseTemplate
        blankSlotNames = Set(draft.slots.map(\.name))
        revalidate()
    }

    var slots: [LearnedShortcutSlot] { originalDraft.slots }

    var stepDescriptions: [String] {
        currentDraft.steps.map { LearnedShortcutDraftEditing.plainDescription(of: $0) }
    }

    func exampleValue(forSlotNamed slotName: String) -> String {
        LearnedShortcutDraftEditing.exampleValue(forSlotNamed: slotName, in: originalDraft) ?? ""
    }

    /// Turning a blank off puts the words it had back into the phrase. This rewrites the phrase
    /// from the learned one, so a hand edit made before toggling is not carried over.
    func setSlot(named slotName: String, isBlank: Bool) {
        var updatedBlankSlotNames = blankSlotNames
        if isBlank { updatedBlankSlotNames.insert(slotName) } else { updatedBlankSlotNames.remove(slotName) }
        guard let updatedDraft = LearnedShortcutDraftEditing.keepingBlanks(updatedBlankSlotNames, in: originalDraft) else {
            return
        }
        blankSlotNames = updatedBlankSlotNames
        phraseText = updatedDraft.phraseTemplate
    }

    func makeShortcut() -> LearnedShortcut? {
        guard case .success(let shortcut) = LearnedShortcutDraftEditing.shortcut(
            from: currentDraft, editedPhrase: phraseText
        ) else { return nil }
        return shortcut
    }

    private var currentDraft: LearnedShortcutDraft {
        LearnedShortcutDraftEditing.keepingBlanks(blankSlotNames, in: originalDraft) ?? originalDraft
    }

    private func revalidate() {
        switch LearnedShortcutDraftEditing.shortcut(from: currentDraft, editedPhrase: phraseText) {
        case .success:
            problemText = nil
        case .failure(.phraseIsNotATemplate):
            problemText = "Needs at least one fixed word, with blanks kept apart."
        case .failure(.blanksDoNotMatchTheSteps(let expected, _)):
            problemText = expected.isEmpty
                ? "This phrase has no blanks."
                : "Keep each blank once: " + expected.map { "{\($0)}" }.joined(separator: " ")
        }
    }
}

private struct LearnedShortcutSaveCardView: View {
    @ObservedObject var model: LearnedShortcutSaveCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("When I say")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("", text: $model.phraseText)
                    .textFieldStyle(.roundedBorder)
            }

            ForEach(model.slots, id: \.name) { slot in
                Toggle(isOn: Binding(
                    get: { model.blankSlotNames.contains(slot.name) },
                    set: { model.setSlot(named: slot.name, isBlank: $0) }
                )) {
                    Text("{\(slot.name)} can change each time (now: \(model.exampleValue(forSlotNamed: slot.name)))")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .pointerCursor()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Then Wisp does")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                ForEach(Array(model.stepDescriptions.enumerated()), id: \.offset) { _, stepDescription in
                    Text(stepDescription)
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Always laid out, so the alert doesn't change height when a problem appears.
            Text(model.problemText ?? " ")
                .font(.system(size: 11))
                .foregroundColor(.red)
                .frame(height: 16, alignment: .leading)
        }
        .frame(width: 380, alignment: .leading)
    }
}

@MainActor
enum LearnedShortcutSaveCard {
    /// The shortcut the user chose to save, or nil if they cancelled.
    static func ask(for offer: LearnedShortcutOffer) -> LearnedShortcut? {
        let model = LearnedShortcutSaveCardModel(draft: offer.draft)

        let alert = NSAlert()
        alert.messageText = "Save as shortcut"
        alert.informativeText = "Next time, Wisp does this without asking the model. It still asks before anything that needs your OK."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let hostingView = NSHostingView(rootView: LearnedShortcutSaveCardView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        alert.accessoryView = hostingView

        let saveButton = alert.buttons.first
        saveButton?.isEnabled = model.problemText == nil
        let saveButtonSubscription = model.$problemText.sink { problemText in
            saveButton?.isEnabled = problemText == nil
        }
        defer { saveButtonSubscription.cancel() }

        // The alert needs the app active to take typing; Wisp is an accessory app.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return model.makeShortcut()
    }

    static func showNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
