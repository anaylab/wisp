//
//  BuddyCreationView.swift
//  leanring-buddy
//
//  Summoning a buddy, in two steps. First pick what it's good at, from a quiet
//  grid of specialty cards. Then name it and give it a mission and a schedule,
//  with everything the specialty implies already filled in and every field
//  editable.
//

import SwiftUI

struct BuddyCreationView: View {
    /// True when there are no buddies yet (no Cancel, since there is nothing to go back to).
    let isFirstBuddy: Bool
    var onCreated: (UUID) -> Void
    var onCancel: () -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared

    private enum Step { case pickSpecialty, details }

    @State private var step: Step = .pickSpecialty
    @State private var specialty: BuddySpecialty = .general
    @State private var colorIndex = 0
    @State private var instructionText = ""
    @State private var nameText = ""
    @State private var hasEditedName = false
    @State private var schedule: BuddySchedule = .once
    @State private var hasChosenScheduleByHand = false
    @State private var modelChoice: BuddyModelChoice?
    @State private var toolAccess: BuddyToolAccess?
    @State private var isShowingTools = false
    @State private var hoveredSpecialty: BuddySpecialty?
    @FocusState private var isInstructionFocused: Bool

    private var trimmedInstruction: String { instructionText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            BuddyAmbientBackground(colorIndex: step == .pickSpecialty ? (hoveredSpecialty?.preferredColorIndex ?? 1) : colorIndex)
            ScrollView {
                Group {
                    switch step {
                    case .pickSpecialty: pickSpecialtyStep
                    case .details: detailsStep
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Step 1

    private var pickSpecialtyStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("New buddy")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(WispColor.textPrimary)
                Spacer()
                Button("Import from file…") {
                    if let importedBuddyID = WispShareImporter.importFromFile()?.importedBuddyIDs.first {
                        onCreated(importedBuddyID)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(WispColor.textSecondary).pointerCursor()
                if !isFirstBuddy {
                    Button("Cancel", action: onCancel).buttonStyle(.plain).foregroundStyle(WispColor.textSecondary).pointerCursor()
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(BuddySpecialty.allCases) { candidate in specialtyCard(candidate) }
            }
        }
    }

    private func specialtyCard(_ candidate: BuddySpecialty) -> some View {
        let isHovered = hoveredSpecialty == candidate
        return Button { choose(candidate) } label: {
            VStack(alignment: .leading, spacing: 12) {
                BuddyCharacter(
                    colorIndex: candidate.preferredColorIndex,
                    size: 52,
                    mood: .idle,
                    liveliness: isHovered ? .full : .still,
                    looksAtPointer: true
                )
                .frame(width: 60, height: 60, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WispColor.textPrimary)
                    Text(candidate.tagline)
                        .font(.system(size: 12))
                        .foregroundStyle(WispColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 164)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface2.opacity(isHovered ? 1 : 0.7)))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isHovered ? BuddyAppearance.deepColor(forColorIndex: candidate.preferredColorIndex).opacity(0.6) : WispColor.cardSeparator.opacity(0.5), lineWidth: isHovered ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .accessibilityLabel("\(candidate.title): \(candidate.tagline)")
        .onHover { isHoveringNow in
            withAnimation(WispMotion.quick) { hoveredSpecialty = isHoveringNow ? candidate : (hoveredSpecialty == candidate ? nil : hoveredSpecialty) }
        }
    }

    private func choose(_ chosenSpecialty: BuddySpecialty) {
        specialty = chosenSpecialty
        colorIndex = chosenSpecialty.preferredColorIndex
        instructionText = chosenSpecialty.starterJobs.first ?? ""
        toolAccess = chosenSpecialty.toolAccess
        hasChosenScheduleByHand = false
        schedule = BuddySchedule.inferred(fromInstruction: instructionText)
        hasEditedName = false
        nameText = suggestedName()
        withAnimation(WispMotion.island) { step = .details }
        isInstructionFocused = true
    }

    private func suggestedName() -> String {
        let existingNames = buddyStore.buddies.map(\.name)
        guard !trimmedInstruction.isEmpty else { return BuddyNameGenerator.uniqueName("\(specialty.nameStem) Buddy", avoiding: existingNames) }
        let generatedName = BuddyNameGenerator.name(forInstruction: trimmedInstruction, existingNames: existingNames)
        // A job that gave no subject comes back as "Helper Buddy"; the specialty names it better.
        return generatedName.hasPrefix("Helper") && specialty != .general
            ? BuddyNameGenerator.uniqueName("\(specialty.nameStem) Buddy", avoiding: existingNames)
            : generatedName
    }

    // MARK: - Step 2

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button {
                withAnimation(WispMotion.island) { step = .pickSpecialty }
            } label: {
                Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(WispColor.textSecondary).pointerCursor()

            HStack(alignment: .center, spacing: 18) {
                BuddyCharacter(colorIndex: colorIndex, size: 84, mood: .idle, liveliness: .full, looksAtPointer: true)
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $nameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(WispColor.textPrimary)
                        .onChange(of: nameText) { _, _ in
                            if nameText != suggestedName() { hasEditedName = true }
                        }
                    HStack(spacing: 9) {
                        ForEach(0..<BuddyAppearance.paletteCount, id: \.self) { index in
                            Button { withAnimation(WispMotion.quick) { colorIndex = index } } label: {
                                Circle()
                                    .fill(BuddyAppearance.lightColor(forColorIndex: index))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(WispColor.textPrimary.opacity(colorIndex == index ? 0.85 : 0), lineWidth: 1.5).padding(-3))
                            }
                            .buttonStyle(.plain).pointerCursor().accessibilityLabel("Colour \(index + 1)")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("What should it do? e.g. Every morning, summarize what's new on Hacker News", text: $instructionText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(3...6)
                    .focused($isInstructionFocused)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.surface2.opacity(0.9)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isInstructionFocused ? BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.7) : WispColor.cardSeparator.opacity(0.7), lineWidth: isInstructionFocused ? 1 : 0.5)
                    )
                    .onChange(of: instructionText) { _, newText in
                        if !hasChosenScheduleByHand { schedule = BuddySchedule.inferred(fromInstruction: newText) }
                        if !hasEditedName { nameText = suggestedName() }
                    }
                if specialty.starterJobs.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(specialty.starterJobs, id: \.self) { starterJob in
                                Button { instructionText = starterJob } label: {
                                    Text(starterJob)
                                        .font(.system(size: 12)).lineLimit(1)
                                        .foregroundStyle(WispColor.textSecondary)
                                        .padding(.horizontal, 11).padding(.vertical, 6)
                                        .overlay(Capsule().strokeBorder(WispColor.cardSeparator.opacity(0.8), lineWidth: 0.5))
                                }
                                .buttonStyle(PressableScaleButtonStyle()).pointerCursor()
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                BuddyScheduleEditor(schedule: Binding(
                    get: { schedule },
                    set: { hasChosenScheduleByHand = true; schedule = $0 }
                ))
                BuddyModelEditor(modelChoice: $modelChoice)
                DisclosureGroup(isExpanded: $isShowingTools) {
                    BuddyToolsView(
                        toolAccess: $toolAccess,
                        modelSendsDataOffThisMachine: BuddyModelChoice.sendsDataOffThisMachine(modelChoice),
                        colorIndex: colorIndex
                    )
                    .padding(.top, 10)
                } label: {
                    Text(toolAccess == nil ? "Tools · all" : "Tools · limited")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(WispColor.textSecondary)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.surface2.opacity(0.6)))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(BuddyPillButtonStyle(colorIndex: colorIndex, isProminent: false)).pointerCursor()
                Button {
                    let newBuddy = buddyStore.createBuddy(
                        instruction: trimmedInstruction,
                        schedule: schedule,
                        modelChoice: modelChoice,
                        toolAccess: toolAccess,
                        specialty: specialty,
                        name: nameText,
                        colorIndex: colorIndex,
                        runImmediately: !schedule.isRepeating
                    )
                    onCreated(newBuddy.id)
                } label: {
                    Text(schedule.isRepeating ? "Create" : "Create & run")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: colorIndex))
                .pointerCursor()
                .disabled(trimmedInstruction.isEmpty)
                .opacity(trimmedInstruction.isEmpty ? 0.5 : 1)
            }
        }
    }
}
