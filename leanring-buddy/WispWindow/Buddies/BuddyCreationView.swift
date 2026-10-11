//
//  BuddyCreationView.swift
//  leanring-buddy
//
//  Summoning a buddy, in two steps. First pick what it is good at — a grid of
//  specialty cards, each with its own coloured character that wiggles when you
//  look at it. Then name it, give it a mission and a schedule, and watch it come
//  to life. Picking a specialty fills in everything sensible (colour, tools,
//  starter mission, schedule); every field stays editable.
//

import SwiftUI

struct BuddyCreationView: View {
    /// True when there are no buddies yet, for a warmer heading.
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
            BuddyAmbientBackground(colorIndex: step == .pickSpecialty ? (hoveredSpecialty?.preferredColorIndex ?? 7) : colorIndex)
            ScrollView {
                Group {
                    switch step {
                    case .pickSpecialty: pickSpecialtyStep
                    case .details: detailsStep
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Step 1

    private var pickSpecialtyStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isFirstBuddy ? "Meet your buddies" : "Summon a buddy")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(WispColor.textPrimary)
                    Text("A buddy takes one job and keeps at it — now, or on a schedule. Pick what it's good at.")
                        .font(.system(size: 14))
                        .foregroundStyle(WispColor.textSecondary)
                }
                Spacer()
                if !isFirstBuddy {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered).pointerCursor()
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                ForEach(BuddySpecialty.allCases) { candidate in
                    specialtyCard(candidate)
                }
            }
        }
    }

    private func specialtyCard(_ candidate: BuddySpecialty) -> some View {
        let isHovered = hoveredSpecialty == candidate
        return Button {
            choose(candidate)
        } label: {
            VStack(spacing: 10) {
                BuddyCharacter(
                    colorIndex: candidate.preferredColorIndex,
                    size: 76,
                    mood: isHovered ? .happy : .idle,
                    liveliness: .full,
                    looksAtPointer: true
                )
                .frame(height: 84)
                VStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: candidate.symbolName).font(.system(size: 11, weight: .bold))
                        Text(candidate.title).font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: candidate.preferredColorIndex))
                    Text(candidate.tagline)
                        .font(.system(size: 11.5))
                        .foregroundStyle(WispColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .frame(height: 212)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(WispColor.surface2.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        isHovered
                            ? AnyShapeStyle(BuddyAppearance.accentGradient(forColorIndex: candidate.preferredColorIndex))
                            : AnyShapeStyle(WispColor.cardSeparator.opacity(0.5)),
                        lineWidth: isHovered ? 2 : 0.8
                    )
            )
            .shadow(color: BuddyAppearance.deepColor(forColorIndex: candidate.preferredColorIndex).opacity(isHovered ? 0.3 : 0), radius: 16, y: 6)
            .scaleEffect(isHovered ? 1.025 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(WispColor.textSecondary).pointerCursor()

            HStack(alignment: .center, spacing: 22) {
                BuddyCharacter(colorIndex: colorIndex, size: 120, mood: .happy, liveliness: .full, looksAtPointer: true)
                    .frame(width: 130, height: 130)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        BuddyChip(symbolName: specialty.symbolName, text: specialty.title, colorIndex: colorIndex)
                    }
                    TextField("Name", text: $nameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(WispColor.textPrimary)
                        .onChange(of: nameText) { _, _ in
                            if nameText != suggestedNameIfUnedited { hasEditedName = true }
                        }
                    HStack(spacing: 8) {
                        ForEach(0..<BuddyAppearance.paletteCount, id: \.self) { index in
                            Button { withAnimation(WispMotion.quick) { colorIndex = index } } label: {
                                Circle()
                                    .fill(BuddyAppearance.gradient(forColorIndex: index))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: colorIndex == index ? 2.5 : 0))
                                    .scaleEffect(colorIndex == index ? 1.15 : 1)
                            }
                            .buttonStyle(.plain).pointerCursor()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("MISSION")
                    .font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1.2)
                    .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: colorIndex))
                TextField("What should it do? e.g. Every morning, summarize what's new on Hacker News", text: $instructionText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(3...6)
                    .focused($isInstructionFocused)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface2.opacity(0.9)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isInstructionFocused
                                ? AnyShapeStyle(BuddyAppearance.accentGradient(forColorIndex: colorIndex))
                                : AnyShapeStyle(WispColor.cardSeparator.opacity(0.5)), lineWidth: isInstructionFocused ? 1.6 : 0.8)
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
                                        .font(.system(size: 11.5)).lineLimit(1)
                                        .foregroundStyle(WispColor.textSecondary)
                                        .padding(.horizontal, 11).padding(.vertical, 6)
                                        .background(Capsule().fill(WispColor.surface2))
                                }
                                .buttonStyle(PressableScaleButtonStyle()).pointerCursor()
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                BuddyScheduleEditor(schedule: Binding(
                    get: { schedule },
                    set: { hasChosenScheduleByHand = true; schedule = $0 }
                ))
                BuddyModelEditor(modelChoice: $modelChoice)
                DisclosureGroup(isExpanded: $isShowingTools) {
                    BuddyToolAccessEditor(
                        toolAccess: $toolAccess,
                        modelSendsDataOffThisMachine: BuddyModelChoice.sendsDataOffThisMachine(modelChoice)
                    )
                    .padding(.top, 6)
                } label: {
                    Text("Tools · \(toolAccess == nil ? "everything" : "limited to what fits the job")")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(WispColor.textSecondary)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface2.opacity(0.7)))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.bordered).controlSize(.large).pointerCursor()
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
                    Label(schedule.isRepeating ? "Create" : "Create & run", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: colorIndex))
                .controlSize(.large)
                .pointerCursor()
                .disabled(trimmedInstruction.isEmpty)
                .opacity(trimmedInstruction.isEmpty ? 0.5 : 1)
            }
        }
    }

    /// The name the generator would currently propose, so typing over it can be
    /// told apart from the instruction changing underneath it.
    private var suggestedNameIfUnedited: String { suggestedName() }
}
