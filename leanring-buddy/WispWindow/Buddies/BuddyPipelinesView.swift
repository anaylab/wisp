//
//  BuddyPipelinesView.swift
//  leanring-buddy
//
//  Pipelines on the Buddies page: chains of buddies where each step is handed
//  the previous answer ("Inbox → Planner → Writer"). Shown in place of a buddy's
//  chat when the rail's pipeline button is chosen. Each pipeline reads as its
//  steps in order with what it is doing or how it last went, and creating one
//  is a short form: pick buddies in order, optionally a schedule. Passing an
//  answer between two different models is approved here, when the pipeline is
//  made, not at run time (see `BuddyPipeline.swift`).
//

import SwiftUI

struct BuddyPipelinesView: View {
    @ObservedObject private var pipelineStore = BuddyPipelineStore.shared
    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared

    @State private var isCreating = false
    @State private var pipelineIDPendingDeletion: UUID?
    @State private var refusalMessagesByPipelineID: [UUID: String] = [:]
    @State private var expandedPipelineIDs: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Pipelines").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    if !isCreating && buddyStore.buddies.count >= BuddyPipelinePolicy.minimumSteps {
                        Button { withAnimation(WispMotion.smooth) { isCreating = true } } label: {
                            Label("New pipeline", systemImage: "plus")
                        }
                        .buttonStyle(WispPillButtonStyle(isProminent: true)).pointerCursor()
                    }
                }

                if buddyStore.buddies.count < BuddyPipelinePolicy.minimumSteps {
                    Text("A pipeline chains two or more buddies. Summon another buddy first.")
                        .font(.system(size: 13)).foregroundStyle(WispColor.textSecondary)
                } else if pipelineStore.pipelines.isEmpty && !isCreating {
                    Text("Chain buddies so each one works from the last one's answer — a digest that feeds a planner that feeds a writer. It runs the same way every time and can run on a schedule.")
                        .font(.system(size: 13)).foregroundStyle(WispColor.textSecondary)
                }

                if isCreating {
                    BuddyPipelineCreationForm(onDone: { withAnimation(WispMotion.smooth) { isCreating = false } })
                }

                ForEach(pipelineStore.pipelines) { pipeline in
                    pipelineCard(pipeline)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "Delete this pipeline?",
            isPresented: Binding(get: { pipelineIDPendingDeletion != nil }, set: { if !$0 { pipelineIDPendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let pipelineIDPendingDeletion { pipelineStore.delete(pipelineWithID: pipelineIDPendingDeletion) }
            }
        } message: {
            Text("The buddies stay; only the chain is removed.")
        }
    }

    // MARK: - A pipeline

    private func pipelineCard(_ pipeline: BuddyPipeline) -> some View {
        let isRunning = pipelineStore.isRunning(pipeline)
        let liveRun = pipelineStore.liveRunsByPipelineID[pipeline.id]
        let stepBuddies = pipeline.stepBuddyIDs.map { buddyID in buddyStore.buddy(withID: buddyID) }
        let blockingProblem = pipelineStore.problemPreventingRun(of: pipeline)
        let crossings = pipelineStore.boundaryCrossings(for: pipeline.stepBuddyIDs)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(pipeline.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer()
                if isRunning {
                    Button { pipelineStore.stop(pipelineWithID: pipeline.id) } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(WispPillButtonStyle(isProminent: false)).pointerCursor()
                } else {
                    Button {
                        if case .refused(let reason) = pipelineStore.startRun(ofPipelineWithID: pipeline.id) {
                            refusalMessagesByPipelineID[pipeline.id] = reason
                        } else {
                            refusalMessagesByPipelineID[pipeline.id] = nil
                        }
                    } label: { Label("Run", systemImage: "play.fill") }
                        .buttonStyle(WispPillButtonStyle(isProminent: true)).pointerCursor()
                        .disabled(blockingProblem != nil)
                }
                Menu {
                    Button("Delete…", role: .destructive) { pipelineIDPendingDeletion = pipeline.id }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().pointerCursor()
            }

            // The steps, in order.
            HStack(spacing: 6) {
                ForEach(Array(stepBuddies.enumerated()), id: \.offset) { stepIndex, stepBuddy in
                    if stepIndex > 0 {
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(WispColor.textTertiary)
                    }
                    stepChip(stepBuddy, liveOutcome: liveRun?.steps.indices.contains(stepIndex) == true ? liveRun?.steps[stepIndex].outcome : nil,
                             isCurrent: isRunning && stepIndex == (liveRun?.steps.firstIndex { $0.outcome == .pending } ?? -1))
                }
            }

            Text(statusLine(for: pipeline, isRunning: isRunning, liveRun: liveRun))
                .font(.system(size: 12.5)).foregroundStyle(WispColor.textSecondary)

            if let blockingProblem {
                VStack(alignment: .leading, spacing: 8) {
                    Text(blockingProblem).font(.system(size: 12.5)).foregroundStyle(DS.Colors.warningText)
                    if !crossings.isEmpty && !BuddyPipelinePolicy.isApproved(pipeline, currentSignature: pipelineStore.currentBoundarySignature(for: pipeline.stepBuddyIDs)) {
                        Text(BuddyPipelinePolicy.approvalText(for: crossings))
                            .font(.system(size: 12)).foregroundStyle(WispColor.textSecondary)
                        Button("Approve") { pipelineStore.approveModelHandoffs(ofPipelineWithID: pipeline.id) }
                            .buttonStyle(WispPillButtonStyle(isProminent: true)).pointerCursor()
                    }
                }
            }
            if let reason = refusalMessagesByPipelineID[pipeline.id] {
                Text(reason).font(.system(size: 12.5)).foregroundStyle(DS.Colors.warningText)
            }
            if pipeline.isPaused {
                HStack {
                    Text(pipeline.pausedReason ?? "").font(.system(size: 12.5)).foregroundStyle(DS.Colors.warningText)
                    Button("Resume") { pipelineStore.resume(pipelineWithID: pipeline.id) }
                        .buttonStyle(WispPillButtonStyle(isProminent: false)).pointerCursor()
                }
            }

            BuddyScheduleEditor(schedule: Binding(
                get: { pipeline.schedule },
                set: { pipelineStore.updateSchedule(ofPipelineWithID: pipeline.id, to: $0) }
            ))

            if let recentRuns = pipeline.recentRuns, !recentRuns.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedPipelineIDs.contains(pipeline.id) },
                    set: { isExpanded in
                        if isExpanded { expandedPipelineIDs.insert(pipeline.id) } else { expandedPipelineIDs.remove(pipeline.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recentRuns.reversed().prefix(5)) { run in
                            HStack(spacing: 8) {
                                Circle().fill(run.succeeded ? DS.Colors.success : DS.Colors.destructive).frame(width: 6, height: 6)
                                Text(run.succeeded ? "Done" : (run.stoppedReason ?? "Stopped")).font(.system(size: 12.5)).lineLimit(1)
                                Spacer()
                                Text("\(run.reason.title) · \(BuddyFormatting.timeText(run.startedAt))")
                                    .font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary)
                            }
                            if run.succeeded, let preview = run.finalAnswerPreview {
                                Text(preview).font(.system(size: 12)).foregroundStyle(WispColor.textSecondary).lineLimit(3)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Recent runs").font(.system(size: 12, weight: .semibold)).foregroundStyle(WispColor.textSecondary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.groupedCardBackground))
    }

    private func stepChip(_ buddy: WispBuddy?, liveOutcome: BuddyPipelineStepRun.Outcome?, isCurrent: Bool) -> some View {
        HStack(spacing: 5) {
            if let buddy {
                BuddyAvatar(colorIndex: buddy.colorIndex, size: 22, isWorking: isCurrent)
                Text(buddy.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            } else {
                Image(systemName: "questionmark.circle").foregroundStyle(WispColor.textTertiary)
                Text("Missing buddy").font(.system(size: 12.5)).foregroundStyle(DS.Colors.warningText)
            }
            if liveOutcome == .succeeded {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.success)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(WispColor.surface3.opacity(isCurrent ? 1 : 0.6)))
    }

    private func statusLine(for pipeline: BuddyPipeline, isRunning: Bool, liveRun: BuddyPipelineRun?) -> String {
        if isRunning, let liveRun {
            let stepNumber = (liveRun.steps.firstIndex { $0.outcome == .pending } ?? liveRun.steps.count - 1) + 1
            return "Running — step \(stepNumber) of \(liveRun.steps.count)"
        }
        let nextRunText = pipeline.schedule.isRepeating && pipeline.nextScheduledRunAt != nil
            ? " · \(pipeline.schedule.summary())" : ""
        if let lastRun = pipeline.recentRuns?.last {
            let result = lastRun.succeeded ? "Last run finished" : "Last run stopped: \(lastRun.stoppedReason ?? "stopped")"
            return result + " · " + BuddyFormatting.timeText(lastRun.startedAt) + nextRunText
        }
        return (pipeline.schedule.isRepeating ? pipeline.schedule.summary() : "Runs when you ask")
    }
}

// MARK: - Creating one

private struct BuddyPipelineCreationForm: View {
    var onDone: () -> Void

    @ObservedObject private var pipelineStore = BuddyPipelineStore.shared
    @ObservedObject private var buddyStore = BuddyStore.shared

    @State private var name = ""
    @State private var stepBuddyIDs: [UUID] = []
    @State private var schedule: BuddySchedule = .once

    var body: some View {
        let problem = BuddyPipelinePolicy.validationProblem(stepBuddyIDs: stepBuddyIDs, buddies: buddyStore.buddies)
        let crossings = pipelineStore.boundaryCrossings(for: stepBuddyIDs)
        let availableBuddies = buddyStore.orderedBuddies().filter { !stepBuddyIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: 12) {
            TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(stepBuddyIDs.enumerated()), id: \.element) { stepIndex, buddyID in
                    HStack(spacing: 8) {
                        Text("\(stepIndex + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(WispColor.textTertiary).frame(width: 16)
                        if let buddy = buddyStore.buddy(withID: buddyID) {
                            BuddyAvatar(colorIndex: buddy.colorIndex, size: 22)
                            Text(buddy.name).font(.system(size: 13, weight: .medium))
                        }
                        Spacer()
                        Button { move(stepIndex, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.plain).disabled(stepIndex == 0).pointerCursor().accessibilityLabel("Move up")
                        Button { move(stepIndex, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.plain).disabled(stepIndex == stepBuddyIDs.count - 1).pointerCursor().accessibilityLabel("Move down")
                        Button { stepBuddyIDs.remove(at: stepIndex) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).pointerCursor().accessibilityLabel("Remove step")
                    }
                }
                if stepBuddyIDs.count < BuddyPipelinePolicy.maximumSteps && !availableBuddies.isEmpty {
                    Menu {
                        ForEach(availableBuddies) { buddy in
                            Button(buddy.name) { stepBuddyIDs.append(buddy.id) }
                        }
                    } label: {
                        Label(stepBuddyIDs.isEmpty ? "Add the first buddy" : "Then…", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton).fixedSize().pointerCursor()
                }
            }

            BuddyScheduleEditor(schedule: $schedule)

            if !crossings.isEmpty {
                Text(BuddyPipelinePolicy.approvalText(for: crossings))
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.warningText)
            }
            if let problem, stepBuddyIDs.count >= 2 {
                Text(problem.message).font(.system(size: 12)).foregroundStyle(DS.Colors.warningText)
            }

            HStack {
                Button("Cancel", action: onDone).buttonStyle(WispPillButtonStyle(isProminent: false)).pointerCursor()
                Button(crossings.isEmpty ? "Create" : "Approve and create") { create() }
                    .buttonStyle(WispPillButtonStyle(isProminent: true)).pointerCursor()
                    .disabled(problem != nil)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.groupedCardBackground))
    }

    private func move(_ stepIndex: Int, by offset: Int) {
        let destination = stepIndex + offset
        guard stepBuddyIDs.indices.contains(destination) else { return }
        stepBuddyIDs.swapAt(stepIndex, destination)
    }

    private func create() {
        if case .created(let pipelineID) = pipelineStore.createPipeline(name: name, stepBuddyIDs: stepBuddyIDs, schedule: schedule) {
            // Pressing "Approve and create" is the approval for any hand-offs shown.
            pipelineStore.approveModelHandoffs(ofPipelineWithID: pipelineID)
            onDone()
        }
    }
}
