// Adapted from Sentient OS's Proofread controller (AGPL-3.0).
//
// Owns one proofreading run: capture the selection in the frontmost app, ask the local model for
// a correction, then paste it over the selection only if nothing changed meanwhile. When the text
// can't be replaced safely, the correction is shown in a small panel to copy instead.

import AppKit
import Observation

@MainActor @Observable final class Proofread {
    static let shared = Proofread()

    private(set) var isRunning = false

    @ObservationIgnored private var currentRunID = UUID()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private let resultPanel = ProofreadResultPanel()

    /// A paste that has been posted cannot be recalled, so past this point a timeout asks the
    /// user to check their text rather than pretending nothing happened.
    @ObservationIgnored private var isApplyingCorrection = false

    private static let maximumRunDuration: Duration = .seconds(45)

    /// Starts proofreading whatever is selected in the frontmost app. Ignored while a run is active.
    func run() {
        guard !isRunning else { return }
        isRunning = true
        isApplyingCorrection = false
        currentRunID = UUID()
        let thisRunID = currentRunID
        let activityAtStart = ProofreadInputActivity.current
        // Read the frontmost app now, before anything of ours can take focus.
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        resultPanel.close()

        runTask = Task { [weak self] in
            guard let self else { return }

            guard AXIsProcessTrusted() else {
                present(nil, ProofreadSelection.Failure.permission.localizedDescription, runID: thisRunID)
                return
            }
            guard let frontmostProcessID else {
                present(nil, ProofreadSelection.Failure.noSelection.localizedDescription, runID: thisRunID)
                return
            }

            let snapshot: ProofreadSelection.Snapshot
            do {
                snapshot = try await Task.detached(priority: .userInitiated) {
                    try ProofreadSelection.capture(pid: frontmostProcessID)
                }.value
            } catch {
                let failure = (error as? ProofreadSelection.Failure) ?? .unsupported
                present(nil, failure.localizedDescription, runID: thisRunID)
                return
            }
            guard currentRunID == thisRunID, !Task.isCancelled else { return }

            do {
                let correctedText = try await ProofreadInference.correct(snapshot.text)
                guard currentRunID == thisRunID, !Task.isCancelled else { return }

                if correctedText == snapshot.text {
                    present(nil, "Looks good — nothing to fix.", runID: thisRunID)
                    return
                }

                isApplyingCorrection = true
                let outcome = await ProofreadSelection.apply(correctedText, to: snapshot, activity: activityAtStart)
                guard currentRunID == thisRunID, !Task.isCancelled else { return }

                switch outcome {
                case .applied:
                    finishRun(runID: thisRunID)
                case .changed:
                    present(correctedText, "Your selection or editing context changed. The correction is ready to copy.", runID: thisRunID)
                case .unsupported:
                    present(correctedText, "This selection can’t be replaced safely in its editor. The correction is ready to copy.", runID: thisRunID)
                case .clipboardUnavailable:
                    present(correctedText, ProofreadSelection.Failure.clipboard.localizedDescription, runID: thisRunID)
                case .uncertain:
                    present(correctedText, "Wisp couldn’t verify the replacement. Check your original text before using this correction.", runID: thisRunID)
                }
            } catch {
                guard currentRunID == thisRunID, !Task.isCancelled else { return }
                let message = (error as? ProofreadInference.Failure)?.localizedDescription
                    ?? "Couldn’t proofread. Your text hasn’t been changed."
                present(nil, message, runID: thisRunID)
            }
        }

        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.maximumRunDuration) } catch { return }
            guard let self, self.currentRunID == thisRunID, self.isRunning else { return }
            let message = self.isApplyingCorrection
                ? "Stopped. Check the original text."
                : "Proofreading took too long. Try again."
            self.cancel()
            self.resultPanel.show(text: nil, explanation: message)
        }
    }

    func cancel() {
        currentRunID = UUID()
        runTask?.cancel()
        runTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        isApplyingCorrection = false
        isRunning = false
    }

    private func present(_ correctedText: String?, _ explanation: String, runID: UUID) {
        guard currentRunID == runID else { return }
        resultPanel.show(text: correctedText, explanation: explanation)
        finishRun(runID: runID)
    }

    private func finishRun(runID: UUID) {
        guard currentRunID == runID else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        runTask = nil
        isApplyingCorrection = false
        isRunning = false
    }
}
