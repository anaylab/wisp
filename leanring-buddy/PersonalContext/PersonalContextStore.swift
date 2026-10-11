//
//  PersonalContextStore.swift
//  leanring-buddy
//
//  Runs personal context: the user's switches (persisted), each source's
//  availability, and the search itself — for a turn (`contextForTurn`) and
//  for the `search_personal_context` tool (`search`).
//
//  A search runs every allowed source at once and waits only until a
//  deadline: 0.8s when only the fast sources (Calendar, Reminders, Contacts,
//  files) are involved, 2.5s when the request names a slow one ("the email
//  from…"). Whatever has arrived by then is ranked and used; a source still
//  answering is simply left out of this turn. Sources run as separate tasks
//  rather than a task group, because a group waits for every child before it
//  returns, and an AppleScript reply can't be cancelled.
//
//  Privacy: everything is read on this Mac. The results go to the model on
//  the user's message, so with a cloud model selected they would leave the
//  Mac — personal context is therefore off for cloud models unless the user
//  turns on `allowsCloudModels`, and cloud buddies never get the tool.
//

import Combine
import Foundation

@MainActor
final class PersonalContextStore: ObservableObject {
    static let shared = PersonalContextStore()

    /// The master switch.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.isEnabledDefaultsKey) }
    }
    /// Sources the user has switched on. Messages starts off: it needs Full
    /// Disk Access and holds the most private writing.
    @Published private(set) var enabledSourceKinds: Set<PersonalContextSourceKind>
    /// Whether results may go to a cloud model with the request. Off by default.
    @Published var allowsCloudModels: Bool {
        didSet { UserDefaults.standard.set(allowsCloudModels, forKey: Self.allowsCloudModelsDefaultsKey) }
    }
    /// Refreshed when Settings is open (`refreshAvailability`).
    @Published private(set) var availabilityBySourceKind: [PersonalContextSourceKind: PersonalContextSourceAvailability] = [:]

    static let fastSourcesTimeLimitSeconds: Double = 0.8
    static let slowSourcesTimeLimitSeconds: Double = 2.5
    static let maximumHitsPerTurn = 5

    private static let isEnabledDefaultsKey = "personalContext.isEnabled"
    private static let enabledSourceKindsDefaultsKey = "personalContext.enabledSourceKinds"
    private static let allowsCloudModelsDefaultsKey = "personalContext.allowsCloudModels"

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.isEnabledDefaultsKey) as? Bool ?? true
        allowsCloudModels = defaults.bool(forKey: Self.allowsCloudModelsDefaultsKey)
        if let storedSourceKindNames = defaults.stringArray(forKey: Self.enabledSourceKindsDefaultsKey) {
            enabledSourceKinds = Set(storedSourceKindNames.compactMap(PersonalContextSourceKind.init(rawValue:)))
        } else {
            enabledSourceKinds = Set(PersonalContextSourceKind.allCases).subtracting([.messages])
        }
    }

    func setSource(_ sourceKind: PersonalContextSourceKind, isEnabled shouldEnable: Bool) {
        if shouldEnable { enabledSourceKinds.insert(sourceKind) } else { enabledSourceKinds.remove(sourceKind) }
        UserDefaults.standard.set(enabledSourceKinds.map(\.rawValue).sorted(), forKey: Self.enabledSourceKindsDefaultsKey)
    }

    func refreshAvailability() {
        var refreshedAvailability: [PersonalContextSourceKind: PersonalContextSourceAvailability] = [:]
        for sourceKind in PersonalContextSourceKind.allCases {
            refreshedAvailability[sourceKind] = PersonalContextSystemPermissions.availability(for: sourceKind)
        }
        availabilityBySourceKind = refreshedAvailability
    }

    /// Shows the system prompt for a source — only from Settings, when the
    /// user pressed "Allow". Messages can't be asked for: Full Disk Access is
    /// granted in System Settings, which Settings opens instead.
    func requestAccess(for sourceKind: PersonalContextSourceKind) async {
        switch sourceKind {
        case .calendar:
            _ = await CalendarDataProvider.shared.requestAccessForPersonalContext()
        case .reminders:
            _ = await RemindersDataProvider.shared.requestAccessForPersonalContext()
        case .contacts:
            try? await ContactsDirectory.shared.ensureAccess()
        case .mail:
            _ = await ScriptedAppPermission.requestAutomationPermission(bundleIdentifier: MailSearchBridge.mailBundleIdentifier)
        case .notes:
            _ = await ScriptedAppPermission.requestAutomationPermission(bundleIdentifier: NotesSearchBridge.notesBundleIdentifier)
        case .files:
            await SpotlightFileSearch.requestFolderAccess()
        case .messages:
            break
        }
        refreshAvailability()
    }

    // MARK: - Searching

    /// What a turn found: the block for the model ("" when nothing) and the
    /// hits, so the turn can record in History which sources were read.
    struct TurnContext {
        let promptText: String
        let hits: [PersonalContextHit]

        static let empty = TurnContext(promptText: "", hits: [])

        /// "Searched your data on this Mac — 2 matches: Calendar, Mail".
        var historySummary: String? {
            guard !hits.isEmpty else { return nil }
            var sourceNamesInOrder: [String] = []
            for hit in hits where !sourceNamesInOrder.contains(hit.sourceKind.displayName) {
                sourceNamesInOrder.append(hit.sourceKind.displayName)
            }
            let matchWord = hits.count == 1 ? "match" : "matches"
            return "Searched your data on this Mac — \(hits.count) \(matchWord): \(sourceNamesInOrder.joined(separator: ", "))"
        }
    }

    /// The per-turn context for `request` — empty when the request isn't about
    /// the user's own things, nothing matched, personal context is off, or
    /// the model would send it off this Mac without the user's say-so.
    func contextForTurn(request: String, modelSendsDataOffThisMachine: Bool) async -> TurnContext {
        guard isEnabled, !modelSendsDataOffThisMachine || allowsCloudModels,
              let query = PersonalContextQueryBuilder.query(forRequest: request) else { return .empty }
        let sourceKindsToSearch = enabledSourceKinds.filter { sourceKind in
            !sourceKind.isSlowToSearch || query.namedSourceKinds.contains(sourceKind)
        }
        let hits = await searchSources(for: query, sourceKinds: sourceKindsToSearch, maximumHitCount: Self.maximumHitsPerTurn)
        if !hits.isEmpty {
            print("🔎 Personal context: \(hits.count) hit(s) for \(query.searchTerms) from \(Set(hits.map(\.sourceKind.rawValue)).sorted())")
        }
        return TurnContext(promptText: PersonalContextPromptBlock.promptText(for: hits), hits: hits)
    }

    /// The tool's search: every enabled source (or just `onlySourceKinds`),
    /// slow ones included, with a longer wait. Nil when personal context is
    /// off or `queryText` has nothing to search for.
    func search(
        queryText: String,
        onlySourceKinds: Set<PersonalContextSourceKind>?,
        maximumHitCount: Int
    ) async -> [PersonalContextHit]? {
        guard isEnabled else { return nil }
        // The tool's query is the model's words, not a spoken request, so it
        // counts as personal by definition; "my" makes the builder agree.
        guard let query = PersonalContextQueryBuilder.query(forRequest: "my \(queryText)") else { return nil }
        let sourceKindsToSearch = enabledSourceKinds.intersection(onlySourceKinds ?? Set(PersonalContextSourceKind.allCases))
        let queryNamingTheRequestedSources = PersonalContextQuery(
            searchTerms: query.searchTerms,
            namedSourceKinds: query.namedSourceKinds.union(onlySourceKinds ?? []),
            relationWords: query.relationWords
        )
        return await searchSources(
            for: queryNamingTheRequestedSources,
            sourceKinds: sourceKindsToSearch,
            maximumHitCount: maximumHitCount,
            timeLimitSeconds: Self.slowSourcesTimeLimitSeconds + 1.5
        )
    }

    private func searchSources(
        for query: PersonalContextQuery,
        sourceKinds: Set<PersonalContextSourceKind>,
        maximumHitCount: Int,
        timeLimitSeconds: Double? = nil
    ) async -> [PersonalContextHit] {
        let searchableSourceKinds = sourceKinds.filter { PersonalContextSystemPermissions.availability(for: $0).isSearchable }
        guard !searchableSourceKinds.isEmpty else { return [] }

        // "mom" → the name on the Me card, so "mom's flight" also finds mail
        // from her. Only with Contacts access; never prompts.
        var resolvedQuery = query
        for relationWord in query.relationWords.prefix(2) {
            if let relatedPersonName = await ContactsDirectory.shared.resolvedNameWithoutPrompting(forRelationWord: relationWord) {
                resolvedQuery = resolvedQuery.addingSearchTerms(relatedPersonName.split(separator: " ").map(String.init))
            }
        }

        let effectiveTimeLimitSeconds = timeLimitSeconds
            ?? (searchableSourceKinds.contains(where: \.isSlowToSearch) ? Self.slowSourcesTimeLimitSeconds : Self.fastSourcesTimeLimitSeconds)
        let searchRound = PersonalContextSearchRound(sourceCount: searchableSourceKinds.count)
        let searchTerms = resolvedQuery.searchTerms
        for sourceKind in searchableSourceKinds {
            Task { @MainActor in
                let sourceHits = await Self.hits(from: sourceKind, matchingAnyOf: searchTerms, maximumHitCount: maximumHitCount)
                searchRound.finishSource(with: sourceHits)
            }
        }
        let collectedHits = await searchRound.waitForAllSources(orAtMost: effectiveTimeLimitSeconds)
        return PersonalContextRanking.rankedHits(collectedHits, for: resolvedQuery, maximumHitCount: maximumHitCount)
    }

    private static func hits(
        from sourceKind: PersonalContextSourceKind,
        matchingAnyOf searchTerms: [String],
        maximumHitCount: Int
    ) async -> [PersonalContextHit] {
        switch sourceKind {
        case .calendar:
            return await CalendarDataProvider.shared.personalContextHits(matchingAnyOf: searchTerms, maximumHitCount: maximumHitCount)
        case .reminders:
            return await RemindersDataProvider.shared.personalContextHits(matchingAnyOf: searchTerms, maximumHitCount: maximumHitCount)
        case .contacts:
            return await ContactsDirectory.shared.personalContextHits(matchingAnyOf: searchTerms, maximumHitCount: maximumHitCount)
        case .files:
            return await SpotlightFileSearch.personalContextHits(
                matchingAnyOf: searchTerms,
                maximumHitCount: maximumHitCount,
                timeLimitSeconds: fastSourcesTimeLimitSeconds
            )
        case .mail:
            return await MailSearchBridge.personalContextHits(matchingAnyOf: searchTerms, maximumHitCount: maximumHitCount)
        case .notes:
            return await NotesSearchBridge.personalContextHits(matchingAnyOf: searchTerms, maximumHitCount: maximumHitCount)
        case .messages:
            let displayNamesByNormalizedHandle = await ContactsDirectory.shared.displayNamesByNormalizedHandle()
            return await Task.detached(priority: .userInitiated) {
                MessagesHistoryReader.personalContextHits(
                    matchingAnyOf: searchTerms,
                    displayNamesByNormalizedHandle: displayNamesByNormalizedHandle,
                    maximumHitCount: maximumHitCount
                )
            }.value
        }
    }
}

/// One search across several sources: collects hits as each source finishes
/// and wakes the waiter when all have, or when the deadline passes. A source
/// that finishes after the deadline adds to a round nobody is reading.
@MainActor
private final class PersonalContextSearchRound {
    private var collectedHits: [PersonalContextHit] = []
    private var remainingSourceCount: Int
    private var waitingContinuation: CheckedContinuation<Void, Never>?

    init(sourceCount: Int) {
        remainingSourceCount = sourceCount
    }

    func finishSource(with sourceHits: [PersonalContextHit]) {
        collectedHits.append(contentsOf: sourceHits)
        remainingSourceCount -= 1
        if remainingSourceCount <= 0 { wakeWaiter() }
    }

    func waitForAllSources(orAtMost timeLimitSeconds: Double) async -> [PersonalContextHit] {
        if remainingSourceCount > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waitingContinuation = continuation
                DispatchQueue.main.asyncAfter(deadline: .now() + timeLimitSeconds) { [weak self] in
                    MainActor.assumeIsolated { self?.wakeWaiter() }
                }
            }
        }
        return collectedHits
    }

    private func wakeWaiter() {
        waitingContinuation?.resume()
        waitingContinuation = nil
    }
}
