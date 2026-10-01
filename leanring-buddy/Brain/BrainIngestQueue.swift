//
//  BrainIngestQueue.swift
//  leanring-buddy
//
//  Runs ingest jobs — files, links, pasted text, imported notes — one at a
//  time: keep the original under `raw/`, extract its text, read it with the
//  model (`BrainKnowledgeExtractor`), and apply the proposed edits as one
//  undoable change (`BrainStore.apply`).
//
//  Serial on purpose: every job queues behind the one local model anyway
//  (`ModelAccessGate`, background priority), so running two would only make
//  both slower while evicting each other's prompt cache.
//
//  Unfinished jobs are saved to `.brain/ingest-queue.json` and resumed by
//  `start()`, so quitting halfway through a 200-note import loses nothing.
//  Each job shows in History as a background task (an import of many notes
//  shares one row), and one notification summarises the work when the queue
//  drains — not one per note — and none at all on a call (quiet mode).
//

import Combine
import Foundation
import UserNotifications

@MainActor
final class BrainIngestQueue: ObservableObject {
    static let shared = BrainIngestQueue()

    /// Every job this session, newest first (finished ones kept for the UI).
    @Published private(set) var jobs: [BrainIngestJob] = []
    /// True while jobs are waiting only because the brain is switched off.
    @Published private(set) var isPausedBecauseBrainIsOff = false

    var activeJob: BrainIngestJob? { jobs.first { !$0.state.isFinal && $0.state != .queued } }
    var pendingJobCount: Int { jobs.filter { !$0.state.isFinal }.count }

    /// File types ingest can read (for open panels and drop validation).
    static let supportedFileExtensions: Set<String> = ["md", "markdown", "txt", "pdf", "html", "htm", "rtf", "docx", "json", "csv"]

    /// Most finished jobs kept in `jobs` for the UI; older ones drop off.
    static let maximumRetainedFinishedJobs = 300
    /// Longest pasted text kept in a job (the extractor's cap applies too).
    static let maximumTextJobCharacters = BrainTextExtractor.maximumExtractedCharacters
    static let notesImportHistoryTitle = "Brain · Notes import"
    static let historyTitlePrefix = "Brain · "

    private var hasStarted = false
    private var workerTask: Task<Void, Never>?
    private var workerJobID: UUID?
    private var brainEnabledObserver: AnyCancellable?
    private var pendingSaveTask: Task<Void, Never>?
    /// History rows, by job id (a notes-import job maps to the shared row).
    private var historyTaskIDByJobID: [UUID: UUID] = [:]
    /// The one History row every notes-import job of this drain reports to.
    private var notesImportHistoryTaskID: UUID?
    /// Jobs that ended since the queue last drained, for the one summary notification.
    private var endedJobIDsSinceLastDrain: [UUID] = []

    private var queueFileURL: URL {
        BrainStore.shared.vaultURL
            .appendingPathComponent(".brain", isDirectory: true)
            .appendingPathComponent("ingest-queue.json")
    }

    private init() {}

    // MARK: Starting

    /// Resumes jobs left unfinished by the last launch, starts watching
    /// `raw/inbox/` (if enabled), and follows the brain's master switch.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let resumedJobs = loadPersistedJobs().filter { resumedJob in
            !jobs.contains { $0.id == resumedJob.id }
        }
        if !resumedJobs.isEmpty {
            jobs = (jobs + resumedJobs).sorted { $0.createdDate > $1.createdDate }
            print("🧠 Brain ingest: resuming \(resumedJobs.count) unfinished \(resumedJobs.count == 1 ? "job" : "jobs")")
        }

        brainEnabledObserver = BrainPreferences.shared.$isBrainEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // The published value changes before the property is read
                // back, so hop a turn before deciding.
                Task { @MainActor in self?.processNextJobIfPossible() }
            }

        BrainInboxWatcher.shared.start()
        processNextJobIfPossible()
    }

    // MARK: Enqueueing

    @discardableResult
    func enqueue(fileURL: URL, origin: BrainEditProvenance.Origin = .ingest) -> UUID {
        let standardizedFileURL = fileURL.standardizedFileURL
        if let existingJob = unfinishedJob(matchingFileURL: standardizedFileURL) {
            return existingJob.id
        }
        var job = BrainIngestJob(
            id: UUID(),
            title: standardizedFileURL.lastPathComponent,
            source: .file(standardizedFileURL),
            provenanceOrigin: origin,
            state: .queued,
            createdDate: Date()
        )
        let fileExtension = standardizedFileURL.pathExtension.lowercased()
        if !BrainIngestFileRules.isSupported(fileExtension: fileExtension) {
            job.state = .failed(BrainTextExtractionError.unsupportedFileType(fileExtension: fileExtension).localizedDescription)
        }
        return add(job)
    }

    @discardableResult
    func enqueue(webPageURL: URL) -> UUID {
        if let existingJob = jobs.first(where: { !$0.state.isFinal && $0.source == .webPage(webPageURL) }) {
            return existingJob.id
        }
        var job = BrainIngestJob(
            id: UUID(),
            title: Self.provisionalTitle(forWebPageURL: webPageURL),
            source: .webPage(webPageURL),
            provenanceOrigin: .ingest,
            state: .queued,
            createdDate: Date()
        )
        let scheme = webPageURL.scheme?.lowercased()
        if scheme != "http" && scheme != "https" {
            job.state = .failed(BrainTextExtractionError.notAWebAddress.localizedDescription)
        }
        return add(job)
    }

    @discardableResult
    func enqueue(text: String, title: String, origin: BrainEditProvenance.Origin = .ingest) -> UUID {
        let cleanTitle = BrainEditPlanner.cleanedTitle(title)
        let (cappedText, _) = BrainTextExtractor.capped(text, maximumCharacters: Self.maximumTextJobCharacters)
        var job = BrainIngestJob(
            id: UUID(),
            title: cleanTitle.isEmpty ? "Pasted text" : cleanTitle,
            source: .text(title: cleanTitle.isEmpty ? "Pasted text" : cleanTitle, body: cappedText),
            provenanceOrigin: origin,
            state: .queued,
            createdDate: Date()
        )
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            job.state = .failed("there was no text to read")
        }
        return add(job)
    }

    private func add(_ job: BrainIngestJob) -> UUID {
        jobs.insert(job, at: 0)
        trimFinishedJobs()
        scheduleSave()
        processNextJobIfPossible()
        return job.id
    }

    // MARK: Controls

    func cancel(jobID: UUID) {
        guard let job = job(withID: jobID), !job.state.isFinal else { return }
        updateState(of: jobID, to: .cancelled)
        if workerJobID == jobID {
            workerTask?.cancel()
        }
        if let historyTaskID = historyTaskIDByJobID[jobID], historyTaskID != notesImportHistoryTaskID {
            AgentTaskRegistry.shared.cancelTask(historyTaskID)
        }
        scheduleSave()
    }

    func retry(jobID: UUID) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[jobIndex].state {
        case .failed, .cancelled: break
        default: return
        }
        var retriedJob = jobs.remove(at: jobIndex)
        retriedJob.state = .queued
        // To the back of the queue: it was already tried once.
        retriedJob.createdDate = Date()
        jobs.insert(retriedJob, at: 0)
        scheduleSave()
        processNextJobIfPossible()
    }

    func clearFinishedJobs() {
        jobs.removeAll { $0.state.isFinal }
    }

    // MARK: Worker

    private func processNextJobIfPossible() {
        guard workerTask == nil else { return }
        let hasWaitingJobs = jobs.contains { $0.state == .queued }
        guard BrainPreferences.shared.isBrainEnabled else {
            isPausedBecauseBrainIsOff = hasWaitingJobs
            return
        }
        isPausedBecauseBrainIsOff = false

        // Oldest queued first.
        guard let nextJob = jobs.filter({ $0.state == .queued }).min(by: { $0.createdDate < $1.createdDate }) else {
            queueDidDrain()
            return
        }
        let jobID = nextJob.id
        workerJobID = jobID
        let work = Task { @MainActor [weak self] in
            await self?.run(jobID: jobID)
            guard let self else { return }
            self.workerTask = nil
            self.workerJobID = nil
            self.processNextJobIfPossible()
        }
        // Set before the task body runs (it starts on a later main-actor
        // turn), so `run` can attach it to its History row.
        workerTask = work
    }

    private func run(jobID: UUID) async {
        guard let job = job(withID: jobID) else { return }
        let historyTaskID = beginHistoryTask(for: job)
        let jobStartDate = Date()
        updateState(of: jobID, to: .extractingText)

        do {
            let material = try await prepareMaterial(forJobID: jobID)
            try Task.checkCancellation()
            updateState(of: jobID, to: .reading(progress: 0))

            let modelProvider = ModelProviderFactory.make()
            let proposals = try await BrainKnowledgeExtractor.proposeEdits(
                for: material,
                modelProvider: modelProvider,
                onProgress: { [weak self] progress in
                    self?.updateState(of: jobID, to: .reading(progress: progress))
                }
            )
            try Task.checkCancellation()

            // The brain was switched off mid-read: write nothing, and pick
            // the job up again when it comes back on.
            guard BrainPreferences.shared.isBrainEnabled else {
                forceState(of: jobID, to: .queued)
                finishHistoryTask(historyTaskID, forJobID: jobID, status: .cancelled, finalText: "paused — the brain was switched off")
                return
            }

            updateState(of: jobID, to: .merging)
            guard let currentJob = self.job(withID: jobID), !currentJob.state.isFinal else { return }
            let applyResult = BrainStore.shared.apply(proposals: proposals, provenance: provenance(for: currentJob))
            let touchedPageTitles = applyResult.touchedSlugs.compactMap { BrainStore.shared.page(withSlug: $0)?.title }
            updateState(of: jobID, to: .finished(
                changeID: applyResult.changeID,
                changeDescriptions: applyResult.changeDescriptions,
                pageTitles: touchedPageTitles
            ))
            let resultText = applyResult.didChangeAnything
                ? "Added \(currentJob.title) to your brain: " + applyResult.changeDescriptions.prefix(8).joined(separator: "; ")
                : "Read \(currentJob.title) — nothing new to add to your brain."
            appendHistoryStep(
                to: historyTaskID,
                summary: applyResult.didChangeAnything ? "Filed \(currentJob.title) into \(touchedPageTitles.count) pages" : "Read \(currentJob.title) — nothing new",
                detail: applyResult.changeDescriptions.joined(separator: "\n"),
                startDate: jobStartDate,
                isError: false
            )
            finishHistoryTask(historyTaskID, forJobID: jobID, status: .succeeded, finalText: resultText)
        } catch is CancellationError {
            updateState(of: jobID, to: .cancelled)
            finishHistoryTask(historyTaskID, forJobID: jobID, status: .cancelled, finalText: nil)
        } catch {
            let failureDescription = error.localizedDescription
            let wasCancelled = self.job(withID: jobID)?.state == .cancelled
            if wasCancelled {
                finishHistoryTask(historyTaskID, forJobID: jobID, status: .cancelled, finalText: nil)
            } else {
                updateState(of: jobID, to: .failed(failureDescription))
                appendHistoryStep(
                    to: historyTaskID,
                    summary: "Couldn't read \(job.title)",
                    detail: failureDescription,
                    startDate: jobStartDate,
                    isError: true
                )
                finishHistoryTask(historyTaskID, forJobID: jobID, status: .failed(failureDescription), finalText: nil)
                print("⚠️ Brain ingest: \(job.title) failed — \(failureDescription)")
            }
        }
        if let endedJob = self.job(withID: jobID), endedJob.state.isFinal, endedJob.state != .cancelled {
            endedJobIDsSinceLastDrain.append(jobID)
        }
        scheduleSave()
    }

    // MARK: Material

    /// Keeps the original under `raw/` (moving it out of the inbox), then
    /// reads its text. Updates the job's title and stored-copy location.
    private func prepareMaterial(forJobID jobID: UUID) async throws -> BrainKnowledgeExtractor.SourceMaterial {
        guard let job = job(withID: jobID) else { throw CancellationError() }
        let rawSubfolder = job.provenanceOrigin == .notesImport ? "notes" : "ingested"

        switch job.source {
        case .file(let originalFileURL):
            let readableFileURL = try storedCopyOfFile(originalFileURL, job: job, rawSubfolder: rawSubfolder)
            let extractedText = try await BrainTextExtractor.extractTextInBackground(fromFileAt: readableFileURL)
            // A document's own title ("Atlas project kickoff — notes") names
            // its source page better than the file name; provenance keeps the
            // file name either way.
            let documentTitle = BrainEditPlanner.cleanedTitle(extractedText.title)
            if !documentTitle.isEmpty && extractedText.title != readableFileURL.lastPathComponent && documentTitle != job.title {
                mutateJob(jobID) { $0.title = documentTitle }
            }
            let updatedJob = self.job(withID: jobID) ?? job
            return material(for: updatedJob, text: extractedText.text, materialDescription: extractedText.materialDescription)

        case .webPage(let webPageURL):
            if let storedRawSourceURL = job.storedRawSourceURL,
               FileManager.default.fileExists(atPath: storedRawSourceURL.path) {
                // Resumed after a relaunch: the page was already saved.
                let extractedText = try await BrainTextExtractor.extractTextInBackground(fromFileAt: storedRawSourceURL)
                return material(for: job, text: extractedText.text, materialDescription: "a web page (\(webPageURL.absoluteString))")
            }
            let fetchedPage = try await BrainTextExtractor.fetchWebPage(webPageURL)
            try Task.checkCancellation()
            let savedMarkdown = "# \(fetchedPage.title)\n\nsource: \(webPageURL.absoluteString)\nsaved: \(BrainDateFormat.dayString(from: Date()))\n\n\(fetchedPage.text)\n"
            let storedFileURL = try BrainStore.shared.storeRawText(
                savedMarkdown,
                fileName: Self.rawFileName(forTitle: fetchedPage.title, jobID: jobID),
                subfolder: rawSubfolder
            )
            mutateJob(jobID) { mutableJob in
                mutableJob.title = BrainEditPlanner.cleanedTitle(fetchedPage.title).isEmpty
                    ? mutableJob.title
                    : BrainEditPlanner.cleanedTitle(fetchedPage.title)
                mutableJob.storedRawSourceURL = storedFileURL
            }
            let updatedJob = self.job(withID: jobID) ?? job
            return material(for: updatedJob, text: fetchedPage.text, materialDescription: "\(fetchedPage.materialDescription) (\(webPageURL.absoluteString))")

        case .text(let title, let body):
            if job.storedRawSourceURL == nil {
                let storedFileURL = try? BrainStore.shared.storeRawText(
                    "# \(title)\n\n\(body)\n",
                    fileName: Self.rawFileName(forTitle: title, jobID: jobID),
                    subfolder: rawSubfolder
                )
                mutateJob(jobID) { $0.storedRawSourceURL = storedFileURL }
            }
            let materialDescription = job.provenanceOrigin == .notesImport ? "one of the user's own notes" : "text the user gave Wisp to read"
            return material(for: job, text: body, materialDescription: materialDescription)
        }
    }

    /// The copy of a file to read: the one already stored for this job, the
    /// file itself when it already lives under `raw/` (a notes import copies
    /// there first), or a fresh copy in `raw/<subfolder>/` (moved, for an inbox file).
    private func storedCopyOfFile(_ originalFileURL: URL, job: BrainIngestJob, rawSubfolder: String) throws -> URL {
        if let storedRawSourceURL = job.storedRawSourceURL,
           FileManager.default.fileExists(atPath: storedRawSourceURL.path) {
            return storedRawSourceURL
        }
        guard FileManager.default.fileExists(atPath: originalFileURL.path) else {
            throw BrainTextExtractionError.unreadableFile(fileName: originalFileURL.lastPathComponent + " (it was moved or deleted)")
        }
        let rawFolderPath = BrainStore.shared.rawURL.standardizedFileURL.path + "/"
        let inboxFolderPath = BrainStore.shared.inboxURL.standardizedFileURL.path + "/"
        let originalPath = originalFileURL.standardizedFileURL.path
        let storedFileURL: URL
        if originalPath.hasPrefix(rawFolderPath) && !originalPath.hasPrefix(inboxFolderPath) {
            storedFileURL = originalFileURL
        } else {
            storedFileURL = try BrainStore.shared.storeRawSource(fileURL: originalFileURL, subfolder: rawSubfolder)
        }
        mutateJob(job.id) { $0.storedRawSourceURL = storedFileURL }
        scheduleSave()
        return storedFileURL
    }

    private func material(for job: BrainIngestJob, text: String, materialDescription: String) -> BrainKnowledgeExtractor.SourceMaterial {
        BrainKnowledgeExtractor.SourceMaterial(
            title: job.title,
            text: text,
            materialDescription: materialDescription,
            extraInstructions: Self.extraInstructions(for: job.provenanceOrigin)
        )
    }

    static func extraInstructions(for origin: BrainEditProvenance.Origin) -> String {
        switch origin {
        case .notesImport:
            return "this is one of the user's own notes: facts about the user themselves go on the page \"Me\" (kind me); everything else on its own page."
        case .user:
            return "the user wrote this themselves: facts about the user go on the page \"Me\" (kind me)."
        case .ingest, .activity, .agent, .conversation:
            return "this is outside material the user asked you to read. it is not about the user — never write to the page \"Me\"."
        }
    }

    private func provenance(for job: BrainIngestJob) -> BrainEditProvenance {
        let trust: BrainEditProvenance.Trust
        switch job.provenanceOrigin {
        case .user: trust = .userAuthored
        case .notesImport, .conversation: trust = .derivedFromUser
        case .ingest, .activity, .agent: trust = .external
        }
        return BrainEditProvenance(origin: job.provenanceOrigin, label: job.title, trust: trust)
    }

    static func provisionalTitle(forWebPageURL webPageURL: URL) -> String {
        guard let host = webPageURL.host else { return webPageURL.absoluteString }
        let hostWithoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = webPageURL.path
        return path.count > 1 ? hostWithoutWWW + path : hostWithoutWWW
    }

    /// "atlas-launch-notes-2026-09-29-3f2a1c.md" — unique per job, so two
    /// sources with the same title on the same day never overwrite each other.
    static func rawFileName(forTitle title: String, jobID: UUID) -> String {
        let shortJobIdentifier = String(jobID.uuidString.lowercased().prefix(6))
        return "\(BrainSlug.fileName(fromTitle: title))-\(BrainDateFormat.dayString(from: Date()))-\(shortJobIdentifier).md"
    }

    // MARK: History

    private func beginHistoryTask(for job: BrainIngestJob) -> UUID {
        if job.provenanceOrigin == .notesImport {
            // One History row for the whole import, not one per note (which
            // would also push everything else out of History's 100 rows).
            if let existingTaskID = notesImportHistoryTaskID,
               let existingRecord = AgentTaskRegistry.shared.records.first(where: { $0.id == existingTaskID }) {
                if existingRecord.status == .cancelled {
                    // Stopped from History: stop the rest of the import too.
                    cancelQueuedNotesImportJobs(excludingJobID: job.id)
                    notesImportHistoryTaskID = nil
                } else if !existingRecord.status.isTerminal {
                    historyTaskIDByJobID[job.id] = existingTaskID
                    attachWorkerTask(toHistoryTaskID: existingTaskID)
                    return existingTaskID
                }
            }
            let newTaskID = AgentTaskRegistry.shared.beginTask(title: Self.notesImportHistoryTitle, kind: .background)
            notesImportHistoryTaskID = newTaskID
            historyTaskIDByJobID[job.id] = newTaskID
            attachWorkerTask(toHistoryTaskID: newTaskID)
            return newTaskID
        }
        let newTaskID = AgentTaskRegistry.shared.beginTask(title: Self.historyTitlePrefix + job.title, kind: .background)
        historyTaskIDByJobID[job.id] = newTaskID
        attachWorkerTask(toHistoryTaskID: newTaskID)
        return newTaskID
    }

    /// So Stop in History cancels the running job, not just the row.
    private func attachWorkerTask(toHistoryTaskID historyTaskID: UUID) {
        if let workerTask {
            AgentTaskRegistry.shared.attachRunningTask(workerTask, to: historyTaskID)
        }
    }

    private func appendHistoryStep(to historyTaskID: UUID, summary: String, detail: String?, startDate: Date, isError: Bool) {
        AgentTaskRegistry.shared.appendStep(
            AgentStepRecord(
                kind: .tool(name: "brain_ingest"),
                summary: summary,
                detail: detail?.isEmpty == true ? nil : detail,
                startedAt: startDate,
                durationSeconds: Date().timeIntervalSince(startDate),
                isError: isError
            ),
            to: historyTaskID
        )
    }

    private func finishHistoryTask(_ historyTaskID: UUID, forJobID jobID: UUID, status: AgentTaskRecord.Status, finalText: String?) {
        historyTaskIDByJobID[jobID] = nil
        // The shared notes-import row stays open until the import is done.
        guard historyTaskID != notesImportHistoryTaskID else { return }
        AgentTaskRegistry.shared.finishTask(historyTaskID, status: status, finalText: finalText)
        if status != .cancelled {
            FinishedWorkInbox.shared.recordFinishedTask(historyTaskID)
        }
    }

    private func finishNotesImportHistoryTaskIfIdle() {
        guard let notesImportTaskID = notesImportHistoryTaskID else { return }
        let hasMoreNotesQueued = jobs.contains { $0.provenanceOrigin == .notesImport && !$0.state.isFinal }
        guard !hasMoreNotesQueued else { return }
        notesImportHistoryTaskID = nil
        let endedNotesJobs = jobs.filter { $0.provenanceOrigin == .notesImport && endedJobIDsSinceLastDrain.contains($0.id) }
        let failedNoteCount = endedNotesJobs.filter { if case .failed = $0.state { return true } else { return false } }.count
        let filedNoteCount = endedNotesJobs.count - failedNoteCount
        let summaryText = "Read \(filedNoteCount) \(filedNoteCount == 1 ? "note" : "notes") into your brain"
            + (failedNoteCount > 0 ? "; \(failedNoteCount) couldn't be read" : "") + "."
        let currentStatus = AgentTaskRegistry.shared.records.first { $0.id == notesImportTaskID }?.status
        if currentStatus?.isTerminal != true {
            AgentTaskRegistry.shared.finishTask(notesImportTaskID, status: .succeeded, finalText: summaryText)
            FinishedWorkInbox.shared.recordFinishedTask(notesImportTaskID)
        }
    }

    private func cancelQueuedNotesImportJobs(excludingJobID: UUID) {
        for job in jobs where job.provenanceOrigin == .notesImport && job.state == .queued && job.id != excludingJobID {
            updateState(of: job.id, to: .cancelled)
        }
    }

    // MARK: Draining + notification

    private func queueDidDrain() {
        finishNotesImportHistoryTaskIfIdle()
        let endedJobs = endedJobIDsSinceLastDrain.compactMap(job(withID:))
        endedJobIDsSinceLastDrain = []
        guard !endedJobs.isEmpty else { return }
        postDrainNotification(for: endedJobs)
    }

    /// One notification for everything read since the queue last went idle.
    /// On a call (`QuietModeMonitor`) none is posted; History has the results.
    private func postDrainNotification(for endedJobs: [BrainIngestJob]) {
        guard !QuietModeMonitor.shared.isQuiet else {
            print("🧠 Brain ingest: finished during a call — no notification")
            return
        }
        guard let notificationContent = BrainIngestDrainNotification.text(for: endedJobs) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { isGranted, _ in
            guard isGranted else { return }
            let content = UNMutableNotificationContent()
            content.title = notificationContent.title
            content.subtitle = notificationContent.subtitle
            content.body = notificationContent.body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Job state

    private func job(withID jobID: UUID) -> BrainIngestJob? {
        jobs.first { $0.id == jobID }
    }

    private func unfinishedJob(matchingFileURL fileURL: URL) -> BrainIngestJob? {
        let path = fileURL.standardizedFileURL.path
        return jobs.first { job in
            guard !job.state.isFinal else { return false }
            if case .file(let jobFileURL) = job.source, jobFileURL.standardizedFileURL.path == path { return true }
            return job.storedRawSourceURL?.standardizedFileURL.path == path
        }
    }

    /// Moves a job to a new state unless it already ended (a cancelled job
    /// stays cancelled whatever its worker reports afterwards).
    private func updateState(of jobID: UUID, to newState: BrainIngestJob.State) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
              !jobs[jobIndex].state.isFinal,
              jobs[jobIndex].state != newState else { return }
        jobs[jobIndex].state = newState
    }

    private func forceState(of jobID: UUID, to newState: BrainIngestJob.State) {
        mutateJob(jobID) { $0.state = newState }
    }

    private func mutateJob(_ jobID: UUID, _ mutate: (inout BrainIngestJob) -> Void) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        mutate(&jobs[jobIndex])
    }

    private func trimFinishedJobs() {
        let finishedJobCount = jobs.filter { $0.state.isFinal }.count
        guard finishedJobCount > Self.maximumRetainedFinishedJobs else { return }
        var finishedJobsToRemove = finishedJobCount - Self.maximumRetainedFinishedJobs
        // Oldest finished first (the list is newest first).
        for jobIndex in jobs.indices.reversed() where finishedJobsToRemove > 0 && jobs[jobIndex].state.isFinal {
            jobs.remove(at: jobIndex)
            finishedJobsToRemove -= 1
        }
    }

    // MARK: Persistence

    private func loadPersistedJobs() -> [BrainIngestJob] {
        guard let data = try? Data(contentsOf: queueFileURL) else { return [] }
        return BrainIngestQueueCodec.decode(data)
    }

    /// Coalesces the many small changes of a busy queue into one write.
    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveQueueNow()
        }
    }

    /// Writes the unfinished jobs now (also for app quit).
    func saveQueueNow() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        do {
            let data = try BrainIngestQueueCodec.encode(jobs)
            try FileManager.default.createDirectory(at: queueFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            print("⚠️ Brain ingest: couldn't save the queue: \(error.localizedDescription)")
        }
    }
}
