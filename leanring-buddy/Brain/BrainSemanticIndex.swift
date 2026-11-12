//
//  BrainSemanticIndex.swift
//  leanring-buddy
//
//  The meaning half of recall: every page's facts embedded with Apple's
//  on-device sentence embedding (NaturalLanguage's `NLEmbedding`). No model
//  download, no server, no resident LLM — the system model is small enough to
//  sit beside the local vision model (BrainSearch.swift explains why a full
//  embedding model doesn't).
//
//  Vectors are keyed by a hash of the fact's text and cached in
//  `.brain/fact-vectors.json`, so a change re-embeds only the facts it
//  touched. Embedding runs off the main actor at utility priority; until it
//  finishes, recall simply works on keywords and links. Measured on a 115-page
//  brain: ~1,000 facts in ~4.5 s the first time, a few ms per query after.
//

import Combine
import CryptoKit
import Foundation
import NaturalLanguage

@MainActor
final class BrainSemanticIndex: ObservableObject {
    static let shared = BrainSemanticIndex()

    /// Facts embedded / facts known, for the Brain's Health page and logs.
    @Published private(set) var embeddedFactCount = 0
    @Published private(set) var isEmbedding = false

    private struct IndexedFact {
        var text: String
        var key: String
    }

    private var factsBySlug: [String: [IndexedFact]] = [:]
    private var unitVectorsByFactKey: [String: [Float]] = [:]
    private var pagesSubscription: AnyCancellable?
    private var pendingRefresh = false
    private var saveTask: Task<Void, Never>?
    /// Made once on first use; `NLEmbedding` is cheap to keep.
    private lazy var queryEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    private var cacheFileURL: URL {
        BrainStore.shared.vaultURL
            .appendingPathComponent(".brain", isDirectory: true)
            .appendingPathComponent("fact-vectors.json")
    }

    private init() {}

    /// Loads the cache and keeps the index in step with the pages.
    func start() {
        guard pagesSubscription == nil else { return }
        loadCache()
        pagesSubscription = BrainStore.shared.$pages
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] pages in self?.refresh(pages: pages) }
        refresh(pages: BrainStore.shared.pages)
    }

    // MARK: - Querying

    /// Each page's best-matching fact for the query, or [] while nothing is
    /// embedded (or the language model isn't available).
    func meaningMatches(for query: String) -> [String: BrainSemanticMatch] {
        guard !unitVectorsByFactKey.isEmpty,
              let queryVector = queryEmbedding?.vector(for: query).map(Self.unitVector) else { return [:] }
        var matchesBySlug: [String: BrainSemanticMatch] = [:]
        for (slug, indexedFacts) in factsBySlug {
            var bestMatch: BrainSemanticMatch?
            for indexedFact in indexedFacts {
                guard let factVector = unitVectorsByFactKey[indexedFact.key], factVector.count == queryVector.count else { continue }
                var similarity: Float = 0
                for dimensionIndex in 0..<factVector.count { similarity += factVector[dimensionIndex] * queryVector[dimensionIndex] }
                if Double(similarity) > (bestMatch?.similarity ?? -2) {
                    bestMatch = BrainSemanticMatch(similarity: Double(similarity), closestFact: indexedFact.text)
                }
            }
            if let bestMatch { matchesBySlug[slug] = bestMatch }
        }
        return matchesBySlug
    }

    // MARK: - Keeping up with the pages

    private func refresh(pages: [BrainPage]) {
        guard BrainPreferences.shared.isBrainEnabled else { return }
        guard !isEmbedding else {
            pendingRefresh = true
            return
        }
        var newFactsBySlug: [String: [IndexedFact]] = [:]
        var missingFactTextsByKey: [String: String] = [:]
        for page in pages {
            newFactsBySlug[page.slug] = BrainSemanticFacts.factTexts(for: page).map { factText in
                let factKey = Self.key(for: factText)
                if unitVectorsByFactKey[factKey] == nil { missingFactTextsByKey[factKey] = factText }
                return IndexedFact(text: factText, key: factKey)
            }
        }
        factsBySlug = newFactsBySlug
        let usedFactKeys = Set(newFactsBySlug.values.flatMap { $0.map(\.key) })
        let unusedFactKeys = unitVectorsByFactKey.keys.filter { !usedFactKeys.contains($0) }
        for unusedFactKey in unusedFactKeys { unitVectorsByFactKey.removeValue(forKey: unusedFactKey) }
        embeddedFactCount = unitVectorsByFactKey.count

        guard !missingFactTextsByKey.isEmpty else {
            if !unusedFactKeys.isEmpty { scheduleSave() }
            return
        }
        isEmbedding = true
        let factTextsToEmbed = missingFactTextsByKey
        Task { [weak self] in
            let newVectorsByFactKey = await Task.detached(priority: .utility) {
                // Its own instance: NLEmbedding isn't documented as thread-safe.
                guard let backgroundEmbedding = NLEmbedding.sentenceEmbedding(for: .english) else { return [String: [Float]]() }
                var vectorsByFactKey: [String: [Float]] = [:]
                for (factKey, factText) in factTextsToEmbed {
                    if Task.isCancelled { break }
                    if let vector = backgroundEmbedding.vector(for: factText) {
                        vectorsByFactKey[factKey] = BrainSemanticIndex.unitVector(vector)
                    }
                }
                return vectorsByFactKey
            }.value
            guard let self else { return }
            self.unitVectorsByFactKey.merge(newVectorsByFactKey) { _, newVector in newVector }
            self.embeddedFactCount = self.unitVectorsByFactKey.count
            self.isEmbedding = false
            print("🧠 Brain meaning index: embedded \(newVectorsByFactKey.count) new facts (\(self.embeddedFactCount) in all)")
            self.scheduleSave()
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.refresh(pages: BrainStore.shared.pages)
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func unitVector(_ vector: [Double]) -> [Float] {
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return vector.map { Float($0) } }
        return vector.map { Float($0 / length) }
    }

    nonisolated static func key(for factText: String) -> String {
        SHA256.hash(data: Data(factText.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache file

    nonisolated private struct CacheFile: Codable {
        var version: Int
        /// Fact key → Float32 vector bytes (base64 in JSON).
        var vectors: [String: Data]
    }

    private func loadCache() {
        guard let cacheData = try? Data(contentsOf: cacheFileURL),
              let cacheFile = try? JSONDecoder().decode(CacheFile.self, from: cacheData),
              cacheFile.version == 1 else { return }
        for (factKey, vectorData) in cacheFile.vectors {
            unitVectorsByFactKey[factKey] = vectorData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        embeddedFactCount = unitVectorsByFactKey.count
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let vectorsSnapshot = unitVectorsByFactKey
        let cacheFileURL = cacheFileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            let cacheFile = CacheFile(version: 1, vectors: vectorsSnapshot.mapValues { vector in
                vector.withUnsafeBufferPointer { Data(buffer: $0) }
            })
            guard let cacheData = try? JSONEncoder().encode(cacheFile) else { return }
            try? FileManager.default.createDirectory(at: cacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? cacheData.write(to: cacheFileURL, options: .atomic)
        }
    }
}
