//
//  BrainReview.swift
//  leanring-buddy
//
//  Brain → Review: what the agents filed that the user hasn't looked at yet.
//  Every page a model-written change created or touched (conversation
//  digests, inbox and notes/chat imports, screen activity, the agent's own
//  tools) shows up once, with its newest change, until the user says it looks
//  right, fixes it (tags, kind) or undoes the change.
//
//  "Reviewed" is a date per page: the page is reviewed through that moment,
//  so a later model change brings it back while older ones stay settled. The
//  user's own edits never need review. Kept in `.brain/review-state.json`.
//
//  The policy is pure (`BrainReviewPlanner`, Foundation only, tested by
//  `Tests/BrainCore`); `BrainReviewStore` holds and saves the state.
//

import Combine
import Foundation

nonisolated struct BrainReviewState: Codable, Equatable, Sendable {
    /// Page slug → the user has reviewed every change up to this date.
    var reviewedThroughDateBySlug: [String: Date] = [:]
}

nonisolated struct BrainReviewItem: Identifiable, Equatable, Sendable {
    var slug: String
    /// The newest change to review on this page.
    var latestChangeID: UUID
    var latestChangeDate: Date
    var latestOrigin: BrainEditProvenance.Origin
    var latestTrust: BrainEditProvenance.Trust
    /// What the source was ("conversation 2026-11-10", a file name).
    var latestSourceLabel: String
    var latestChangeDescriptions: [String]
    /// True when the newest unreviewed change is the one that made the page.
    var wasCreatedByAgent: Bool
    /// Unreviewed model changes to this page in the window.
    var unreviewedChangeCount: Int

    var id: String { slug }
}

nonisolated enum BrainReviewPlanner {
    /// Older changes than this are left alone — a review list that reaches
    /// back months is a chore nobody does.
    static let reviewWindowDays = 30

    static func items(
        changeRecords: [BrainChangeRecord],
        existingSlugs: Set<String>,
        state: BrainReviewState,
        now: Date,
        reviewWindowDays: Int = reviewWindowDays
    ) -> [BrainReviewItem] {
        let windowStartDate = now.addingTimeInterval(-Double(reviewWindowDays) * 86_400)
        var itemsBySlug: [String: BrainReviewItem] = [:]
        // Oldest first, so each later change replaces "latest" on its page.
        for record in changeRecords.sorted(by: { $0.date < $1.date }) {
            guard !record.isUndone,
                  record.provenance.origin != .user,
                  record.date >= windowStartDate else { continue }
            for slug in record.createdSlugs + record.modifiedSlugs {
                guard existingSlugs.contains(slug) else { continue }
                if let reviewedThroughDate = state.reviewedThroughDateBySlug[slug], record.date <= reviewedThroughDate {
                    continue
                }
                let previousCount = itemsBySlug[slug]?.unreviewedChangeCount ?? 0
                itemsBySlug[slug] = BrainReviewItem(
                    slug: slug,
                    latestChangeID: record.id,
                    latestChangeDate: record.date,
                    latestOrigin: record.provenance.origin,
                    latestTrust: record.provenance.trust,
                    latestSourceLabel: record.provenance.label,
                    latestChangeDescriptions: record.changeDescriptions,
                    wasCreatedByAgent: record.createdSlugs.contains(slug),
                    unreviewedChangeCount: previousCount + 1
                )
            }
        }
        return itemsBySlug.values.sorted { lhs, rhs in
            if lhs.latestChangeDate != rhs.latestChangeDate { return lhs.latestChangeDate > rhs.latestChangeDate }
            return lhs.slug < rhs.slug
        }
    }

    static func markingReviewed(_ state: BrainReviewState, slug: String, through reviewedDate: Date) -> BrainReviewState {
        var updatedState = state
        let previousDate = updatedState.reviewedThroughDateBySlug[slug] ?? .distantPast
        updatedState.reviewedThroughDateBySlug[slug] = max(previousDate, reviewedDate)
        return updatedState
    }

    /// Forgets pages that no longer exist, so the file doesn't grow forever.
    static func pruned(_ state: BrainReviewState, existingSlugs: Set<String>) -> BrainReviewState {
        var prunedState = state
        prunedState.reviewedThroughDateBySlug = state.reviewedThroughDateBySlug.filter { existingSlugs.contains($0.key) }
        return prunedState
    }

    /// Tags typed as "running, health,  #sleep" → ["running", "health", "sleep"].
    static func parsedTags(from typedText: String) -> [String] {
        var seenTags = Set<String>()
        var tags: [String] = []
        for rawTag in typedText.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            var tag = rawTag.trimmingCharacters(in: .whitespaces)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, !seenTags.contains(tag.lowercased()) else { continue }
            seenTags.insert(tag.lowercased())
            tags.append(tag)
        }
        return tags
    }
}

@MainActor
final class BrainReviewStore: ObservableObject {
    static let shared = BrainReviewStore()

    @Published private(set) var state = BrainReviewState()

    private var stateFileURL: URL {
        BrainStore.shared.vaultURL
            .appendingPathComponent(".brain", isDirectory: true)
            .appendingPathComponent("review-state.json")
    }

    private init() {
        if let stateData = try? Data(contentsOf: stateFileURL),
           let savedState = try? JSONDecoder().decode(BrainReviewState.self, from: stateData) {
            state = savedState
        }
    }

    /// The pages waiting for review right now.
    func currentItems() -> [BrainReviewItem] {
        let brainStore = BrainStore.shared
        return BrainReviewPlanner.items(
            changeRecords: brainStore.changeRecords,
            existingSlugs: Set(brainStore.pages.map(\.slug)),
            state: state,
            now: Date()
        )
    }

    func markReviewed(slug: String, through reviewedDate: Date = Date()) {
        state = BrainReviewPlanner.markingReviewed(state, slug: slug, through: reviewedDate)
        save()
    }

    func markAllReviewed(_ items: [BrainReviewItem]) {
        var updatedState = state
        for item in items {
            updatedState = BrainReviewPlanner.markingReviewed(updatedState, slug: item.slug, through: item.latestChangeDate)
        }
        state = BrainReviewPlanner.pruned(updatedState, existingSlugs: Set(BrainStore.shared.pages.map(\.slug)))
        save()
    }

    private func save() {
        guard let stateData = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? stateData.write(to: stateFileURL, options: .atomic)
    }
}
