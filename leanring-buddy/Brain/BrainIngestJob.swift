//
//  BrainIngestJob.swift
//  leanring-buddy
//
//  One thing waiting to become wiki pages — a file, a link or pasted text —
//  and the codec that keeps unfinished jobs across launches
//  (`.brain/ingest-queue.json`). Pure; `BrainIngestQueue` runs the jobs.
//

import Foundation

struct BrainIngestJob: Identifiable, Equatable, Sendable, Codable {
    enum Source: Equatable, Sendable, Codable {
        case file(URL)
        case webPage(URL)
        case text(title: String, body: String)
    }

    enum State: Equatable, Sendable, Codable {
        case queued
        case extractingText
        /// Reading with the model; fraction 0...1.
        case reading(progress: Double)
        case merging
        case finished(changeID: UUID?, changeDescriptions: [String], pageTitles: [String])
        case failed(String)
        case cancelled

        var isFinal: Bool {
            switch self {
            case .finished, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    var id: UUID
    var title: String
    var source: Source
    var provenanceOrigin: BrainEditProvenance.Origin
    var state: State
    var createdDate: Date
    /// Where the original was kept under `raw/` once the job started, so a
    /// resumed or retried job reads that copy (an inbox file has been moved
    /// by then) and doesn't store the original a second time.
    var storedRawSourceURL: URL? = nil
    /// For a `.text` job that is a web page's text (read in the user's tab by
    /// the Chrome extension): the page's address, kept as the source.
    var sourceWebPageURL: URL? = nil
}

/// Reads and writes the unfinished jobs. Only jobs that haven't ended are
/// kept, and a job that was mid-way when the app quit comes back queued — its
/// model work is redone from the start, since partial proposals were never
/// applied.
enum BrainIngestQueueCodec {
    static let currentFormatVersion = 1

    private struct PersistedQueue: Codable {
        var formatVersion: Int
        var jobs: [BrainIngestJob]
    }

    static func encode(_ jobs: [BrainIngestJob]) throws -> Data {
        let unfinishedJobs = jobs.filter { !$0.state.isFinal }.map { job -> BrainIngestJob in
            var persistedJob = job
            persistedJob.state = .queued
            return persistedJob
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PersistedQueue(formatVersion: currentFormatVersion, jobs: unfinishedJobs))
    }

    /// The saved jobs, all queued, oldest first. Unreadable data → no jobs
    /// (a corrupt queue file must never stop the brain from starting).
    static func decode(_ data: Data) -> [BrainIngestJob] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let persistedQueue = try? decoder.decode(PersistedQueue.self, from: data),
              persistedQueue.formatVersion <= currentFormatVersion else { return [] }
        return persistedQueue.jobs
            .filter { !$0.state.isFinal }
            .map { job in
                var resumedJob = job
                resumedJob.state = .queued
                return resumedJob
            }
            .sorted { $0.createdDate < $1.createdDate }
    }
}

/// The words of the one notification posted when the queue drains: a single
/// source is named, several are counted.
enum BrainIngestDrainNotification {
    /// Title / subtitle / body for the drain notification, or nil when there
    /// is nothing worth saying.
    static func text(for endedJobs: [BrainIngestJob]) -> (title: String, subtitle: String, body: String)? {
        var finishedJobs: [BrainIngestJob] = []
        var failedJobs: [(job: BrainIngestJob, reason: String)] = []
        var touchedPageTitles = Set<String>()
        var changeCount = 0
        for job in endedJobs {
            switch job.state {
            case .finished(_, let changeDescriptions, let pageTitles):
                finishedJobs.append(job)
                touchedPageTitles.formUnion(pageTitles)
                changeCount += changeDescriptions.count
            case .failed(let reason):
                failedJobs.append((job, reason))
            default:
                break
            }
        }
        guard !finishedJobs.isEmpty || !failedJobs.isEmpty else { return nil }

        if finishedJobs.count + failedJobs.count == 1 {
            if let finishedJob = finishedJobs.first {
                let body = touchedPageTitles.isEmpty
                    ? "Nothing new to add — your brain already knew it."
                    : "Updated " + touchedPageTitles.sorted().prefix(4).joined(separator: ", ")
                        + (touchedPageTitles.count > 4 ? " and \(touchedPageTitles.count - 4) more" : "")
                return ("Added to your brain", String(finishedJob.title.prefix(60)), body)
            }
            let failedJob = failedJobs[0]
            return ("Couldn't add to your brain", String(failedJob.job.title.prefix(60)), String(failedJob.reason.prefix(200)))
        }

        let sourceCount = finishedJobs.count
        let title = sourceCount > 0
            ? "Wisp read \(sourceCount) \(sourceCount == 1 ? "source" : "sources") into your brain"
            : "Wisp couldn't read \(failedJobs.count) sources"
        var bodyParts: [String] = []
        if sourceCount > 0 {
            bodyParts.append("\(changeCount) \(changeCount == 1 ? "change" : "changes") across \(touchedPageTitles.count) \(touchedPageTitles.count == 1 ? "page" : "pages").")
        }
        if !failedJobs.isEmpty && sourceCount > 0 {
            bodyParts.append("\(failedJobs.count) couldn't be read.")
        } else if sourceCount == 0, let firstFailure = failedJobs.first {
            bodyParts.append("\(firstFailure.job.title): \(firstFailure.reason)")
        }
        return (title, "", bodyParts.joined(separator: " "))
    }
}
