// Adapted from Sentient OS's Summarize controller (AGPL-3.0).
//
// Owns one ephemeral summary: read the frontmost window, stream a summary from the local model,
// and show it in a floating panel. Every asynchronous callback is fenced by `requestID`, so a
// late reply from a cancelled or retried request can never overwrite newer state.

import AppKit
import Observation

@MainActor @Observable
final class Summarize {
    static let shared = Summarize()

    enum Phase: Equatable { case idle, reading, streaming, complete, failed }

    private(set) var phase: Phase = .idle
    private(set) var summaryText = ""
    private(set) var errorMessage: String?
    private(set) var sourceTitle = ""
    var isBusy: Bool { phase == .reading || phase == .streaming }

    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var readSource: SummarySource?
    @ObservationIgnored private var panelController: SummaryPanelController?

    /// Summarizes the document in the frontmost app's active window.
    func start() {
        if isBusy { showPanel(); return }
        // Read the frontmost app now, before the panel can take focus.
        let target = SummaryAccessibility.target()
        readSource = nil
        begin(target: target)
    }

    /// Runs again on the text already read, so a failed request doesn't re-read the document.
    func retry() {
        guard !isBusy, readSource != nil else { return }
        begin(target: nil)
    }

    func dismiss() {
        requestID = UUID()
        runTask?.cancel(); runTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        readSource = nil
        summaryText = ""; errorMessage = nil; sourceTitle = ""
        phase = .idle
        panelController?.hide()
    }

    private func begin(target: SummaryAccessibility.Target?) {
        runTask?.cancel(); deadlineTask?.cancel()
        requestID = UUID()
        let thisRequestID = requestID
        summaryText = ""; errorMessage = nil
        phase = .reading
        showPanel()

        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: SummarizeInference.deadline) } catch { return }
            guard let self, self.requestID == thisRequestID, self.isBusy else { return }
            // Invalidate before cancelling so a late reply cannot replace this error.
            self.requestID = UUID()
            self.runTask?.cancel(); self.runTask = nil
            self.errorMessage = SummarizeInference.Failure.timedOut.localizedDescription
            self.phase = .failed
        }

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source: SummarySource
                if let existingSource = readSource {
                    source = existingSource
                } else {
                    guard AXIsProcessTrusted() else { throw SummaryAccessibility.Failure.permission }
                    guard let target else { throw SummaryAccessibility.Failure.unavailable }
                    let reader = Task.detached(priority: .userInitiated) { try SummaryAccessibility.read(target) }
                    source = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
                    guard requestID == thisRequestID, !Task.isCancelled else { return }
                    readSource = source
                }
                sourceTitle = source.title.isEmpty ? source.application : "\(source.application) — \(source.title)"

                let result = try await SummarizeInference.stream(source: source, preference: "") { [weak self] partialText in
                    guard let self, self.requestID == thisRequestID, self.isBusy else { return }
                    self.summaryText = partialText
                    self.phase = .streaming
                }
                guard requestID == thisRequestID, !Task.isCancelled else { return }
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SummarizeInference.Failure.empty }
                summaryText = result
                phase = .complete
            } catch {
                guard requestID == thisRequestID, !Task.isCancelled else { return }
                phase = .failed
                if let failure = error as? SummaryAccessibility.Failure {
                    errorMessage = failure.localizedDescription
                } else if let failure = error as? SummarizeInference.Failure {
                    // A reply cut off mid-stream still keeps the text read so far.
                    errorMessage = failure.localizedDescription
                } else {
                    errorMessage = summaryText.isEmpty
                        ? SummarizeInference.Failure.unavailable.localizedDescription
                        : SummarizeInference.Failure.incomplete.localizedDescription
                }
            }
            guard requestID == thisRequestID else { return }
            deadlineTask?.cancel(); deadlineTask = nil; runTask = nil
        }
    }

    private func showPanel() {
        if panelController == nil { panelController = SummaryPanelController(summary: self) }
        panelController?.show()
    }
}
