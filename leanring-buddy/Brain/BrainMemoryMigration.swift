//
//  BrainMemoryMigration.swift
//  leanring-buddy
//
//  Moves the facts in the old memory file (`~/.wisp/memory.md`) into the
//  brain's me page (`wiki/me.md`, `## Facts`), once.
//
//  Once, because it is recorded by a UserDefaults marker; and harmless if it
//  runs again anyway, because the planner skips bullets already on the page.
//  memory.md is left where it is — it may hold notes the user wrote by hand —
//  with one note line at the top saying the facts now live in the brain, so a
//  user who opens it isn't left wondering why edits there stopped mattering.
//
//  The planning is pure (`plan(forMemoryFileMarkdown:)`), so it is tested
//  without touching either file.
//

import Foundation

enum BrainMemoryMigration {
    /// UserDefaults key set once the move has been done.
    static let completedMarkerDefaultsKey = "brain.memoryMigration.completed"

    /// The note line added to memory.md. Also how a second run recognises a
    /// file that was already annotated, so the note is never added twice.
    static let movedFactsNoteLine =
        "> Wisp now keeps these facts in your brain (~/.wisp/brain/wiki/me.md, under Facts). Edit them there; this file is only read while the brain is turned off."

    /// Most characters of bullets packed into one proposal — under the
    /// planner's per-proposal content cap, which would otherwise cut a long
    /// fact list off mid-line.
    static let maximumCharactersPerProposal = BrainEditPlanner.maximumContentCharacters - 200

    /// Where the migrated facts are recorded as coming from. The user wrote
    /// (or approved) every fact in memory.md, so they keep full trust.
    static let migrationProvenance = BrainEditProvenance(origin: .user, label: "memory.md", trust: .userAuthored)

    // MARK: Planning (pure)

    /// Append proposals that put every memory.md fact under the me page's
    /// Facts section, in file order, split so no one proposal is cut off by
    /// the planner's content cap. Empty when there is nothing to move.
    static func proposalBatches(forMemoryFileMarkdown memoryFileMarkdown: String) -> [[BrainEditProposal]] {
        let facts = MemoryFileFormat.parseFacts(from: memoryFileMarkdown)
            .compactMap(MemoryFileFormat.normalizedFact)
        guard !facts.isEmpty else { return [] }

        var proposals: [BrainEditProposal] = []
        var bulletLinesInCurrentProposal: [String] = []
        var charactersInCurrentProposal = 0

        func flushCurrentProposal() {
            guard !bulletLinesInCurrentProposal.isEmpty else { return }
            proposals.append(BrainEditProposal(
                operation: .append,
                pageTitle: "Me",
                pageKind: .me,
                section: BrainAboutMe.factsSectionHeading,
                content: bulletLinesInCurrentProposal.joined(separator: "\n")
            ))
            bulletLinesInCurrentProposal = []
            charactersInCurrentProposal = 0
        }

        for fact in facts {
            let bulletLine = "- \(fact)"
            // +1 for the newline that joins it to the previous bullet.
            if charactersInCurrentProposal + bulletLine.count + 1 > maximumCharactersPerProposal {
                flushCurrentProposal()
            }
            bulletLinesInCurrentProposal.append(bulletLine)
            charactersInCurrentProposal += bulletLine.count + 1
        }
        flushCurrentProposal()

        // One proposal per batch. Within a batch the planner finds a page it
        // already touched by title, and a me page the user renamed ("Anay")
        // wouldn't be found that way — the second proposal would start again
        // from the file on disk and drop the first one's bullets. A long
        // memory file is rare, so the extra undo entries cost little.
        return proposals.map { [$0] }
    }

    /// memory.md with the moved-facts note added after its first heading (or
    /// at the top), or unchanged if the note is already there.
    static func memoryFileMarkdownAddingMovedNote(_ memoryFileMarkdown: String) -> String {
        guard !memoryFileMarkdown.contains(movedFactsNoteLine) else { return memoryFileMarkdown }
        var lines = memoryFileMarkdown.components(separatedBy: "\n")
        if let firstHeadingIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines.insert(contentsOf: ["", movedFactsNoteLine], at: firstHeadingIndex + 1)
        } else {
            lines.insert(contentsOf: [movedFactsNoteLine, ""], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Running

    /// Moves memory.md's facts into the me page if that hasn't been done yet.
    /// Call at launch, after the brain store exists and only while the brain
    /// is enabled.
    @MainActor
    static func migrateIfNeeded(
        brainStore suppliedBrainStore: BrainStore? = nil,
        memoryFileURL suppliedMemoryFileURL: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        // Resolved here rather than as default argument values, which are
        // evaluated outside the main actor these singletons belong to.
        let brainStore = suppliedBrainStore ?? .shared
        let memoryFileURL = suppliedMemoryFileURL ?? MemoryStore.legacyMemoryFileURL
        guard !userDefaults.bool(forKey: completedMarkerDefaultsKey) else { return }

        guard let memoryFileMarkdown = try? String(contentsOf: memoryFileURL, encoding: .utf8) else {
            // No memory file: nothing to move, now or later.
            userDefaults.set(true, forKey: completedMarkerDefaultsKey)
            return
        }

        var everyBatchLanded = true
        var movedFactDescriptions: [String] = []
        for proposalBatch in proposalBatches(forMemoryFileMarkdown: memoryFileMarkdown) {
            let applyResult = brainStore.apply(proposals: proposalBatch, provenance: migrationProvenance)
            movedFactDescriptions += applyResult.changeDescriptions
            // A batch that changed nothing *and* was refused (a locked me page,
            // a full page) didn't land; one that changed nothing because every
            // fact was already there did.
            if !applyResult.didChangeAnything && !applyResult.refusals.isEmpty {
                everyBatchLanded = false
                print("⚠️ Brain: memory.md facts not moved — \(applyResult.refusals.joined(separator: "; "))")
            }
        }

        guard everyBatchLanded else { return } // Try again next launch.

        let annotatedMarkdown = memoryFileMarkdownAddingMovedNote(memoryFileMarkdown)
        if annotatedMarkdown != memoryFileMarkdown {
            try? annotatedMarkdown.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        }
        userDefaults.set(true, forKey: completedMarkerDefaultsKey)
        print("🧠 Brain: moved memory.md into the me page — \(movedFactDescriptions.joined(separator: "; "))")
    }
}
