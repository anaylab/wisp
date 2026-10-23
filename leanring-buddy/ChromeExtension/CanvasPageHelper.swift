//
//  CanvasPageHelper.swift
//  leanring-buddy
//
//  The Canvas assignment page helper (phase 10). With an assignment open in
//  Chrome, Wisp can say whether it's on today's checklist or the "Wisp" calendar,
//  add it to today, or plan study blocks for just it, behind the same approval
//  card as the batch. When an assignment opens that isn't on today's list, the
//  notch may offer "Add to today?" once (Settings switch, default on).
//
//  The rules are pure, in CanvasPageMatching.swift. The checklist, the planner
//  and the approval card are JobsEngine's own: nothing here writes Reminders or
//  the calendar itself.
//
//  The Canvas feed URL is a Keychain-only secret. The one thing taken from it is
//  its host (to trust a school's own Canvas domain), held in memory only.
//

import Combine
import Foundation

@MainActor
final class CanvasPageHelper: ObservableObject {
    static let shared = CanvasPageHelper()

    /// One pending "Add to today?" offer in the notch.
    struct AddToTodayOffer: Equatable {
        let tabID: Int
        let offerKey: String
        let canvasItem: CanvasItem
    }

    @Published private(set) var addToTodayOffer: AddToTodayOffer?
    /// The line the chip shows after Add ("added …"), until it clears.
    @Published private(set) var offerResultText: String?
    /// Bumped when a new offer should drop the notch's compact card.
    @Published private(set) var offerPresentationSequenceNumber = 0

    @Published var offersAddToToday: Bool {
        didSet { UserDefaults.standard.set(offersAddToToday, forKey: Self.offersAddToTodayKey) }
    }

    var hasNotchContent: Bool { addToTodayOffer != nil || offerResultText != nil }

    private static let offersAddToTodayKey = "wisp.chrome.siteHelpers.offersAddToToday"
    private static let offeredKeysKey = "wisp.chrome.siteHelpers.offeredAssignmentKeys"
    private static var cachedCanvasFeedHost: String?
    private static var hasCachedCanvasFeedHost = false

    private var feedSubscription: AnyCancellable?
    private var offerResultClearTask: Task<Void, Never>?

    private init() {
        offersAddToToday = UserDefaults.standard.object(forKey: Self.offersAddToTodayKey) as? Bool ?? true
    }

    func start() {
        // Saving or removing the feed changes the sync state; the cached host is
        // re-read from the Keychain then.
        feedSubscription = JobsEngine.shared.$syncState
            .sink { _ in
                MainActor.assumeIsolated {
                    Self.hasCachedCanvasFeedHost = false
                }
            }
    }

    /// The saved Canvas feed's host, or nil. Only the host is kept, in memory.
    static func savedCanvasFeedHost() -> String? {
        if !hasCachedCanvasFeedHost {
            cachedCanvasFeedHost = CanvasFeedKeychainStore.feedURL()?.host?.lowercased()
            hasCachedCanvasFeedHost = true
        }
        return cachedCanvasFeedHost
    }

    // MARK: - Status against the feed, checklist and calendar

    private func status(for reference: CanvasAssignmentPageReference, title: String, dueDate: Date?) async -> CanvasAssignmentStatus {
        let jobsEngine = JobsEngine.shared
        let feedItems = await CanvasFeedStore.shared.loadSnapshot()?.items ?? []
        return CanvasAssignmentChecklistMatcher.status(
            pageReference: reference,
            pageTitle: title,
            pageDueDate: dueDate,
            feedItems: feedItems,
            todayChecklist: jobsEngine.todayChecklist,
            approvedStudyBlocks: jobsEngine.approvedStudyBlocks,
            isCanvasCalendarMirrored: jobsEngine.isCanvasJobEnabled && jobsEngine.hasCanvasFeed && jobsEngine.calendarAccess == .granted
        )
    }

    private struct DetailsParameters: Encodable {
        let tabId: Int?
    }

    /// The assignment in a tab (nil = the one showing), only on a trusted host.
    func readAssignment(tabID: Int?) async throws -> (details: CanvasAssignmentDetails, reference: CanvasAssignmentPageReference, status: CanvasAssignmentStatus) {
        let details = try await ChromeSiteHelpers.sendRequest(
            method: "getCanvasAssignmentDetails",
            parameters: DetailsParameters(tabId: tabID),
            resultType: CanvasAssignmentDetails.self
        )
        guard let reference = CanvasAssignmentPageMatcher.reference(
            forPageURLString: details.url,
            savedCanvasFeedHost: Self.savedCanvasFeedHost()
        ) else {
            throw ChromeSiteHelpers.SiteHelperError(message: CanvasAssignmentReplyText.notCanvasPageReply())
        }
        let assignmentStatus = await status(for: reference, title: details.title, dueDate: details.dueDate)
        return (details, reference, assignmentStatus)
    }

    // MARK: - The three spoken actions

    func statusOfShowingAssignment() async -> (replyText: String, didSucceed: Bool) {
        do {
            let (details, _, assignmentStatus) = try await readAssignment(tabID: nil)
            return (CanvasAssignmentReplyText.statusReply(title: details.title, dueDate: details.dueDate,
                                                          status: assignmentStatus, calendar: .current), true)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    func addShowingAssignmentToToday() async -> (replyText: String, didSucceed: Bool) {
        do {
            let (details, reference, assignmentStatus) = try await readAssignment(tabID: nil)
            guard let canvasItem = CanvasAssignmentChecklistMatcher.canvasItem(
                pageReference: reference, pageTitle: details.title, pageDueDate: details.dueDate,
                pageURLString: details.url, status: assignmentStatus
            ) else {
                return (CanvasAssignmentReplyText.addToTodayReply(title: details.title, outcome: .noDueDate), false)
            }
            dropOffer(forOfferKey: reference.offerKey)
            let outcome = await addToToday(canvasItem)
            return (CanvasAssignmentReplyText.addToTodayReply(title: details.title, outcome: outcome), outcome == .added || outcome == .alreadyOnChecklist)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    func planShowingAssignment() async -> (replyText: String, didSucceed: Bool) {
        do {
            let (details, reference, assignmentStatus) = try await readAssignment(tabID: nil)
            let calendar = Calendar.current
            guard let canvasItem = CanvasAssignmentChecklistMatcher.canvasItem(
                pageReference: reference, pageTitle: details.title, pageDueDate: details.dueDate,
                pageURLString: details.url, status: assignmentStatus
            ) else {
                return (CanvasAssignmentReplyText.planReply(title: details.title, outcome: .noDueDate, calendar: calendar), false)
            }
            let outcome: CanvasAssignmentReplyText.PlanReplyOutcome
            let lookaheadDays = JobsEngine.shared.studyBlockSettings.lookaheadDays
            if canvasItem.startDate <= Date() {
                outcome = .pastDue
            } else if !assignmentStatus.approvedStudyBlocks.isEmpty {
                outcome = .alreadyPlanned(assignmentStatus.approvedStudyBlocks)
            } else if canvasItem.startDate > Date().addingTimeInterval(TimeInterval(lookaheadDays) * 86400) {
                outcome = .tooFarAhead(lookaheadDays: lookaheadDays)
            } else {
                let proposals = await JobsEngine.shared.proposeStudyBlocks(forCanvasItem: canvasItem)
                if proposals.isEmpty {
                    outcome = .noFreeTime
                } else {
                    // The approval card: always asked, even under session auto-approve.
                    outcome = await JobsEngine.shared.approveStudyBlocks(proposals) ? .written(proposals) : .declined
                }
            }
            let didSucceed: Bool
            switch outcome {
            case .written, .alreadyPlanned, .declined: didSucceed = true
            default: didSucceed = false
            }
            return (CanvasAssignmentReplyText.planReply(title: details.title, outcome: outcome, calendar: calendar), didSucceed)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    private func addToToday(_ canvasItem: CanvasItem) async -> CanvasAssignmentReplyText.AddToTodayReplyOutcome {
        switch await JobsEngine.shared.addCanvasItemToTodayChecklist(canvasItem) {
        case .added: return .added
        case .alreadyOnChecklist: return .alreadyOnChecklist
        case .checklistTurnedOff: return .checklistTurnedOff
        case .checklistFull: return .checklistFull
        }
    }

    // MARK: - The "Add to today?" chip

    /// `site.canvasAssignmentOpened`: maybe offer it, once.
    func assignmentOpened(_ openedPayload: CanvasAssignmentOpenedPayload) {
        guard offersAddToToday,
              let reference = CanvasAssignmentPageMatcher.reference(
                forPageURLString: openedPayload.url,
                savedCanvasFeedHost: Self.savedCanvasFeedHost()
              ) else { return }
        Task { [weak self] in
            guard let self else { return }
            let assignmentStatus = await self.status(for: reference, title: openedPayload.title, dueDate: openedPayload.dueDate)
            let rememberedKeys = UserDefaults.standard.stringArray(forKey: Self.offeredKeysKey) ?? []
            guard CanvasAddToTodayChipPolicy.shouldOffer(
                status: assignmentStatus,
                dueDate: openedPayload.dueDate,
                offerKey: reference.offerKey,
                alreadyOfferedKeys: Set(rememberedKeys),
                isOfferSwitchOn: self.offersAddToToday,
                isDailyChecklistEnabled: JobsEngine.shared.isDailyChecklistEnabled,
                now: Date()
            ), let canvasItem = CanvasAssignmentChecklistMatcher.canvasItem(
                pageReference: reference, pageTitle: openedPayload.title, pageDueDate: openedPayload.dueDate,
                pageURLString: openedPayload.url, status: assignmentStatus
            ) else { return }

            UserDefaults.standard.set(
                CanvasAddToTodayChipPolicy.remembering(reference.offerKey, in: rememberedKeys),
                forKey: Self.offeredKeysKey
            )
            self.offerResultText = nil
            self.addToTodayOffer = AddToTodayOffer(tabID: openedPayload.tabId, offerKey: reference.offerKey, canvasItem: canvasItem)
            // Never pops up during a call; the offer still waits in the panel.
            if QuietModeMonitor.shared.activeQuietReason == nil {
                self.offerPresentationSequenceNumber += 1
            }
        }
    }

    func acceptOffer() {
        guard let offer = addToTodayOffer else { return }
        addToTodayOffer = nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.addToToday(offer.canvasItem)
            self.showOfferResult(CanvasAssignmentReplyText.addToTodayReply(title: offer.canvasItem.title, outcome: outcome))
        }
    }

    func dismissOffer() {
        addToTodayOffer = nil
        offerResultText = nil
    }

    func tabWasClosed(tabID: Int) {
        if addToTodayOffer?.tabID == tabID { addToTodayOffer = nil }
    }

    private func dropOffer(forOfferKey offerKey: String) {
        if addToTodayOffer?.offerKey == offerKey { addToTodayOffer = nil }
    }

    private func showOfferResult(_ resultText: String) {
        offerResultText = resultText
        offerResultClearTask?.cancel()
        offerResultClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.offerResultText = nil
        }
    }
}
