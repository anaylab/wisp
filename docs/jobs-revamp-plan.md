# Jobs revamp plan

Branch: `feature/jobs-revamp`. This is the contract for parallel work. Six packages (A, B, W, U, N, H) are built against the signatures in section 5. No package edits a file another package owns.

## 1. Goals

A Wisp **Job** is `Source -> Rule -> Output -> Cadence`. A job is quiet unless something changed.

1. **Job 1, Canvas calendar manager.**
   - The user pastes their Canvas calendar feed (`.ics`) URL once.
   - Wisp fetches it on launch and then hourly, parses it, and diffs it against the last snapshot.
   - It upserts events into a dedicated **"Wisp"** EventKit calendar, keyed by Canvas UID, so re-running changes nothing.
   - It proposes study blocks in free gaps. The user approves them all in one card. Study blocks are never auto-written.
2. **Job 2, Daily checklist.**
   - The Reminders list **"Wisp Today"** is rebuilt each morning from Canvas due dates plus calendar events.
   - Unfinished items roll over.
   - Completion is read back from Reminders.
   - The notch shows a tickable checklist that replaces the generic morning-suggestions banner.
3. Deterministic code does all sync and scheduling. There is no model call on the sync path. The local model is optional and narrow (assignment breakdown only), and is out of scope for the first cut.
4. Simplify the window from 8 sections to 4 (Today, Chat, Jobs, Settings). Advanced buddy and brain surfaces are hidden behind a persisted "Advanced" toggle. No code and no user data is deleted.

## 2. Non-goals

- No Canvas REST or planner-token path (documented as a future fallback only).
- No auto-writing of study blocks, and no writing to any calendar other than "Wisp".
- No deletion of Buddies, Brain, Routines or History code, or of any persisted user data.
- No removal of `WispSection` or `WispPage` enum cases. Tests reference them.
- No new analytics, and no model call for sync.
- No editing of `CalendarDataProvider` or `RemindersDataProvider`.
- No `xcodebuild`, and no launching of the app binary.

## 3. Privacy notes

- **Canvas feed URL is a secret.**
  - It is stored only in the Keychain (`CanvasFeedKeychainStore`, service `com.wisp.canvas-feed`).
  - It is never put in UserDefaults, `~/.wisp`, logs, History rows, error strings or notifications. Errors say "your Canvas feed", never the URL.
  - It is validated on save: https only (`webcal://` is rewritten to `https://`), host present, and no userinfo. The path is not parsed, because the exact Canvas path is unverified.
  - The Jobs UI shows only a masked form (host plus "...").
- **The fetch is a user-initiated, off-machine read of the school's own server.** Only a plain GET to that URL is made, with no cookies, no extra headers carrying user data, and no redirects off https. No Canvas content is sent anywhere else. There is no analytics and no model call.
- **Snapshot file** `~/Library/Application Support/Wisp/jobs-canvas-snapshot.json` is 0600. It holds course titles and due dates, but never the feed URL.
- **Local-first note for CLAUDE.md.** A user-pasted Canvas feed is a new opt-in network use. It is off until a URL is saved, with its own switch (not `GlanceCardDataPreference`).
- **Writes to the user's calendar and reminders are confined to the "Wisp" calendar and the "Wisp Today" list.** Study blocks need explicit approval through `ToolConfirmationCoordinator`. The tool name is on `ToolCallSafety.alwaysAskBareToolNames`, so session auto-approve cannot skip it.
- **Quiet mode** (`QuietModeMonitor.isQuiet`) suppresses notifications only. Sync still runs.
- **Notifications fire only when the diff is non-empty.**

## 4. File ownership

Rule: a file has exactly one owner. Anyone else needing a change in it sends the owner a requirement, not an edit. New `.swift` files under `leanring-buddy/` are auto-included and `Tests/AgentRuntimeIntegration` compiles them recursively, so everything must compile with FluidAudio and PostHog stubbed.

| Pkg | Owns (new unless marked EDIT) | Depends on |
|---|---|---|
| **A** Canvas core | `leanring-buddy/Jobs/CanvasModels.swift` (CanvasItem, CanvasDiff, CanvasSnapshot, StudyBlock types), `Jobs/CanvasFeedParser.swift`, `Jobs/CanvasSyncPlanner.swift`, `Jobs/StudyBlockPlanner.swift`, `Jobs/CanvasFeedStore.swift` (Keychain URL, validation, fetch, 0600 snapshot JSON), `Jobs/CanvasFeedKeychainStore.swift`, `Tests/CanvasSync/run.sh` + `main.swift` | nothing (pure Foundation) |
| **B** EventKit and checklist | `Jobs/WispCalendarWriter.swift` (actor), `Jobs/WispTodayReminders.swift` (actor), `Jobs/DayChecklistBuilder.swift` (pure), `Jobs/ChecklistModels.swift` (ChecklistItem), `Tests/DayChecklist/run.sh` + `main.swift` | A's models (section 5.1-5.3) |
| **W** Engine glue | `Jobs/JobsEngine.swift`; EDIT `NotchWindowController.swift` (one line: `JobsEngine.shared.start()` beside `MorningBriefingController.shared.start()`), `ToolConfirmationCardBuilder.swift` (study-block card branch), `ToolCallSafety.swift` (always-ask name), `Info.plist` (usage strings, wording only), `CompanionManager.swift` (only if a `flashIsland` or notification hook is needed, minimal), `CLAUDE.md` (Key Files and Local-first note, done last) | A, B |
| **U** Window | `WispWindow/JobsTab.swift` (Canvas setup flow plus cards), EDIT `WispWindow/WispNavigation.swift`, `WispWindow/WispWindowView.swift`, `HomeTab.swift` (checklist hero, remove Buddies/Brain tiles when Advanced is off), `SettingsHost` wiring for Connections, Routines and History as Settings pages | W's published API, H's flag |
| **N** Notch | `DynamicIsland/DailyChecklistView.swift`, `DynamicIsland/CanvasDiffCardView.swift`, `DynamicIsland/StudyBlockApprovalHint.swift` (if needed), EDIT `NotchHUDView.swift`, `DynamicIsland/MorningBriefing.swift` (defer to checklist when `JobsEngine.shared.hasChecklist`), `DynamicIsland/AnnouncementPreferences.swift` | W's published API |
| **H** Hide advanced | `WispWindow/WispAdvancedFeaturesPreference.swift`; EDIT `MenuBarMenuController.swift`, `leanring_buddyApp.swift` (gate Brain launch-time starters and the buddy timer on the flag), `DynamicIsland/NotchWorkspaceView.swift` (buddy sidebar), `WispWindow/BuddiesPage.swift` and `WispWindow/Brain/BrainSharedViews.swift` (redirect only if needed) | none (publishes the flag first) |

Conflict rules:
- `HomeTab.swift` belongs to U only. H supplies the flag and U reads it.
- `NotchHUDView.swift` belongs to N only.
- `CLAUDE.md` is edited by W last, after the other packages report their file lists.
- Never switch the brain off when hiding it. `MemoryStore` depends on the brain's `me.md`.
- Hiding means gating visibility and launch-time work. Persisted files and UserDefaults keys stay untouched.

Build order: A, H and N-view-stubs start immediately. B starts once A's `CanvasModels.swift` is merged, which is the first deliverable and should land within the first step. W starts against the contract with stub implementations. U and N use `JobsEngine` through the section 5.6 API.

## 5. Cross-package contract (exact signatures)

All types are `Sendable` value types in `leanring-buddy/Jobs/`, with no UI imports in A and B's pure files. Dates are absolute `Date`. All-day items carry `isAllDay == true` with `startDate` at the local start-of-day.

### 5.1 Canvas items and diff (package A)

```swift
struct CanvasItem: Equatable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case assignment, quiz, calendarEvent, other }
    let uid: String                 // raw UID, e.g. "event-assignment-123"
    let title: String               // SUMMARY without the trailing " [CODE]"
    let courseCode: String?         // content of the trailing [..], nil if absent
    let kind: Kind                  // inferred from UID prefix
    let startDate: Date             // DTSTART (assignment due_at)
    let endDate: Date?              // DTEND, nil if absent or equal to start
    let isAllDay: Bool              // DTSTART;VALUE=DATE
    let location: String?
    let descriptionText: String?    // plain DESCRIPTION, unescaped
    let linkURLString: String?      // ICS URL (calendar page, not secret)
    let contentFingerprint: String  // deterministic FNV-1a 64 hex of title|start|end|allDay|location|description
}

struct CanvasItemChange: Equatable, Codable, Sendable {
    enum Field: String, Codable, Sendable { case title, start, end, location, description, allDay }
    let before: CanvasItem
    let after: CanvasItem
    let changedFields: [Field]      // sorted by Field.rawValue
}

struct CanvasDiff: Equatable, Codable, Sendable {
    let added: [CanvasItem]
    let changed: [CanvasItemChange]
    let removed: [CanvasItem]
    let unchangedCount: Int
    let isFirstSync: Bool
    var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }
    var summaryLine: String { get } // "2 new, 1 changed, 1 removed" or "No changes"
}

struct CanvasSnapshot: Equatable, Codable, Sendable {
    let fetchedAt: Date
    let items: [CanvasItem]         // sorted by startDate then uid
}

enum CanvasFeedParser {
    static func parse(icsText: String, now: Date, calendar: Calendar) -> [CanvasItem]
    // Never throws: a malformed VEVENT is skipped. Also exposes:
    static func parseReportingSkips(icsText: String, now: Date, calendar: Calendar) -> (items: [CanvasItem], skippedEventCount: Int)
}

enum CanvasSyncPlanner {
    // previous == nil means first sync: everything is "added", isFirstSync == true.
    static func diff(previous: [CanvasItem]?, current: [CanvasItem]) -> CanvasDiff
}
```

### 5.2 Study blocks (package A)

```swift
struct BusyInterval: Equatable, Codable, Sendable {
    let start: Date
    let end: Date
}

struct StudyBlockSettings: Equatable, Codable, Sendable {
    var isEnabled: Bool
    var blockMinutes: Int           // default 90, clamped 30...180
    var minimumGapMinutes: Int      // default 100, a gap shorter than this is skipped
    var bufferMinutes: Int          // default 15 either side of busy time
    var workdayStartMinuteOfDay: Int // default 9 * 60
    var workdayEndMinuteOfDay: Int   // default 21 * 60
    var lookaheadDays: Int          // default 7
    var maximumBlocksPerDay: Int    // default 2
    static let `default`: StudyBlockSettings
}

struct StudyBlockProposal: Identifiable, Equatable, Codable, Sendable {
    let id: String                  // stable: "study-<itemUID>-<yyyyMMdd>-<index>"
    let forItemUID: String          // the Canvas item this block prepares for
    let title: String               // "Study: <item title>"
    let courseCode: String?
    let start: Date
    let end: Date
}

enum StudyBlockPlanner {
    // Pure. Assignments and quizzes due inside the lookahead window drive demand.
    // Busy time = every calendar's events, passed in by the caller.
    static func propose(items: [CanvasItem],
                        busyIntervals: [BusyInterval],
                        alreadyProposedOrCreatedIDs: Set<String>,
                        settings: StudyBlockSettings,
                        now: Date,
                        calendar: Calendar) -> [StudyBlockProposal]
}
```

### 5.3 Checklist (package B)

```swift
struct ChecklistItem: Identifiable, Equatable, Codable, Sendable {
    enum Origin: String, Codable, Sendable { case canvasDue, calendarEvent, studyBlock, rolledOver }
    let id: String                  // stable job-item key: "<origin>:<sourceUID>:<yyyyMMdd>"
    let title: String
    let subtitle: String?           // "ENGL101 · due 11:59 PM"
    let dueDate: Date?
    let origin: Origin
    let rolloverCount: Int          // 0 for new items
    var isCompleted: Bool
    var completionDate: Date?
}

enum DayChecklistBuilder {
    // Pure. previous = yesterday's checklist, completion already read back.
    static func build(day: Date,
                      canvasItems: [CanvasItem],
                      calendarEvents: [ChecklistCalendarEvent],
                      approvedStudyBlocks: [StudyBlockProposal],
                      previousChecklist: [ChecklistItem],
                      maximumItems: Int,        // default 12
                      now: Date,
                      calendar: Calendar) -> [ChecklistItem]
    static func dayKey(for date: Date, calendar: Calendar) -> String   // "yyyy-MM-dd"
}

struct ChecklistCalendarEvent: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

enum WispEventKitError: Error, Equatable, Sendable {
    case accessDenied
    case noWritableSource
    case calendarMissing
    case itemMissing
}

// Dedicated "Wisp" calendar. Owns its own EKEventStore.
actor WispCalendarWriter {
    static let shared: WispCalendarWriter
    static let calendarTitle = "Wisp"
    func requestAccessIfNeeded() async throws
    func ensureWispCalendarExists() async throws
    // Idempotent: keyed by Canvas UID via a persisted uid -> eventIdentifier map
    // (jobs-event-map.json, 0600) with UID also stamped in EKEvent notes as a fallback.
    // Returns counts actually written.
    func apply(diff: CanvasDiff) async throws -> (created: Int, updated: Int, deleted: Int)
    func writeStudyBlocks(_ proposals: [StudyBlockProposal]) async throws -> Int
    func busyIntervals(from: Date, to: Date) async throws -> [BusyInterval] // all calendars, excludes Wisp's own
    func calendarEvents(onDay day: Date, calendar: Calendar) async throws -> [ChecklistCalendarEvent]
    func authorizationState() -> JobsAccessState
}

enum JobsAccessState: String, Sendable { case notDetermined, granted, denied }

// "Wisp Today" Reminders list. Owns its own EKEventStore.
actor WispTodayReminders {
    static let shared: WispTodayReminders
    static let listTitle = "Wisp Today"
    func requestAccessIfNeeded() async throws
    // Replaces the list contents for `items`, idempotently keyed by ChecklistItem.id
    // (jobs-reminder-map.json, 0600). Items no longer present are removed from the list.
    func rebuild(with items: [ChecklistItem]) async throws
    // Reads isCompleted and completionDate for every mapped item.
    func readBackCompletion() async throws -> [String: (isCompleted: Bool, completionDate: Date?)]
    func setCompleted(itemID: String, isCompleted: Bool) async throws
    func authorizationState() -> JobsAccessState
}
```

### 5.4 Feed store (package A)

```swift
enum CanvasFeedURLValidationError: Error, Equatable, Sendable {
    case empty, notAURL, notHTTPS, missingHost, containsCredentials
}

enum CanvasFeedURLValidator {
    // Trims; maps webcal:// to https://; returns the normalized URL.
    static func validate(_ rawText: String) -> Result<URL, CanvasFeedURLValidationError>
    // "yourschool.instructure.com/…" for display. Never includes the path or query.
    static func maskedDisplay(for url: URL) -> String
}

enum CanvasFeedKeychainStore {
    static func save(_ url: URL) throws
    static func feedURL() -> URL?
    static func hasFeedURL() -> Bool
    static func delete()
}

enum CanvasFeedFetchError: Error, Equatable, Sendable {
    case noFeedConfigured, offline, httpStatus(Int), notICS, tooLarge, timedOut
    // `localizedDescription` never contains the URL.
}

actor CanvasFeedStore {
    static let shared: CanvasFeedStore
    func fetchCurrentItems(now: Date, calendar: Calendar) async throws -> [CanvasItem] // https GET, 20s timeout, 5 MB cap, no cookies
    func loadSnapshot() -> CanvasSnapshot?
    func saveSnapshot(_ snapshot: CanvasSnapshot) throws       // 0600, atomic
    func clearSnapshot()
}
```

### 5.5 Study-block tool name (package W)

```swift
enum JobsToolNames {
    static let applyStudyBlocks = "wisp_jobs_apply_study_blocks"
}
// ToolCallSafety.alwaysAskBareToolNames must contain it.
// ToolConfirmationCardBuilder builds: header "N study blocks", one list row per block ("Study: X", "Tue 4:00-5:30 PM").
```

### 5.6 JobsEngine published API (package W, consumed by U and N)

```swift
@MainActor
final class JobsEngine: ObservableObject {
    static let shared: JobsEngine

    enum SyncState: Equatable {
        case notConfigured, idle
        case syncing
        case failed(message: String)        // never contains the URL
    }

    // Published state
    @Published private(set) var syncState: SyncState
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var latestDiff: CanvasDiff?          // last NON-empty diff, nil once dismissed
    @Published private(set) var pendingStudyBlocks: [StudyBlockProposal]
    @Published private(set) var todayChecklist: [ChecklistItem]
    @Published private(set) var calendarAccess: JobsAccessState
    @Published private(set) var remindersAccess: JobsAccessState
    @Published private(set) var itemCountInFeed: Int
    @Published var isCanvasJobEnabled: Bool                      // persisted (UserDefaults)
    @Published var isDailyChecklistEnabled: Bool                 // persisted
    @Published var studyBlockSettings: StudyBlockSettings        // persisted

    var hasChecklist: Bool { !todayChecklist.isEmpty && isDailyChecklistEnabled }
    var hasCanvasFeed: Bool { get }

    // Lifecycle
    func start()                         // launch sync now, then a 60s clock check: sync at most hourly, rebuild checklist once per morning
    func syncNow() async                 // user-initiated or scheduled; no-op if already syncing

    // Canvas setup
    func saveCanvasFeed(urlText: String) -> Result<Void, CanvasFeedURLValidationError>
    func removeCanvasFeed()              // deletes Keychain URL and snapshot; leaves the "Wisp" calendar events alone
    func requestCalendarAndRemindersAccess() async

    // Diff card and study blocks
    func dismissLatestDiff()
    func approvePendingStudyBlocks() async   // one ToolConfirmationCoordinator card, then WispCalendarWriter.writeStudyBlocks
    func dismissPendingStudyBlocks()         // remembers the proposal ids so they are not re-proposed

    // Checklist
    func setChecklistItem(id: String, isCompleted: Bool) async   // optimistic UI, writes Reminders, reverts on failure
    func refreshChecklistCompletion() async                       // reads Reminders back (on notch open, EKEventStoreChanged, after sync)
    func rebuildChecklistNow() async                              // "Rebuild today" button
}
```

### 5.7 Advanced flag (package H, consumed by U and N)

```swift
@MainActor
final class WispAdvancedFeaturesPreference: ObservableObject {
    static let shared: WispAdvancedFeaturesPreference
    @Published var isEnabled: Bool           // UserDefaults "wisp.advancedFeatures.enabled", default false
    nonisolated static var isEnabledNow: Bool { get }   // synchronous read for non-UI code
}
```

### 5.8 Navigation (package U, consumed by H and N)

```swift
extension WispSection {
    // Window bar contents. Enum cases for buddies, brain, routines, history, connections stay.
    static func visibleSections(advancedEnabled: Bool) -> [WispSection]
    // advancedEnabled == false: [.home, .chat, .jobs, .settings]
}
// New enum cases: WispSection.jobs, WispPage.jobs (the single page of .jobs).
// Hidden destinations are redirected by U:
extension WispWindowRouter {
    func resolvedPage(_ requested: WispPage, advancedEnabled: Bool) -> WispPage
    // .buddies/.brain*  -> .general (Settings) when Advanced is off
    // .timeline, .routines, .marketplace, .tools, .sources -> Settings pages, not hidden
}
```

## 6. Behaviour rules (shared by all packages)

- **Cadence.** Sync on launch and at most once an hour while Wisp runs. Never faster than 15 minutes, even on the Sync now button. The clock check is a 60s `Timer` with `tolerance = 10` on `.common`, following `BuddyStore.start`. It must not use `BackgroundTaskLauncher` or `BuddyStore`, because those are model runs.
- **Quiet.** An empty diff produces no card, no notification and no sound. A non-empty diff produces one dismissible notch card, plus a `UNUserNotification` unless quiet mode is on, plus `flashIsland(.success)`.
- **First sync** writes everything but presents one summary ("Added 34 Canvas items to Wisp"), not 34 changes.
- **Idempotency.** Running the same diff twice makes zero EventKit writes the second time. The UID map is repaired from event notes if the map file is lost.
- **Study blocks** are proposed only after a successful sync, up to 7 days ahead, from Canvas assignments and quizzes only. Proposals are held in memory and as ids. Approval writes only to "Wisp".
- **Checklist** rebuilds once per morning (UserDefaults day key `wisp.jobs.checklist.lastBuiltDay`, window 5am-5pm like `MorningBriefingSchedule`, or on demand). It is capped at 12 items. Unfinished items from yesterday come first with `rolloverCount + 1`. Items rolled over 3 times show "overdue Nd". Completed items from yesterday are dropped.
- **Completion read-back** uses Reminders as the source of truth. A tick in the notch calls `setChecklistItem`.
- **Permissions.** Calendar and Reminders access are requested only from an explicit Jobs setup button, never at launch. Denied access shows a System Settings deep link and degrades per feature. The checklist falls back to an in-memory list that does not write Reminders.
- **Style.** Per CLAUDE.md: long clear names, comments explain why, `WispColor` tokens and no hex, `.pointerCursor()` on buttons, `@MainActor` for UI state, the lit-edge pill button style in window pages, and island styles in the notch.

## 7. Test plan (pure components, swiftc suites)

Each suite is `Tests/<Name>/run.sh` modelled on `Tests/WorkedSolutionExport/run.sh`. It compiles only its listed pure files with `swiftc` and prints PASS/FAIL per case. Exit code is non-zero on any failure.

### Tests/CanvasSync (package A): `CanvasFeedParser`, `CanvasSyncPlanner`, `StudyBlockPlanner`, `CanvasFeedURLValidator`

Parser:
1. Line unfolding (CRLF + leading space and tab continuation) rebuilds one logical line.
2. UTC `DTSTART:20261020T235900Z` becomes the correct absolute `Date`.
3. `DTSTART;TZID=America/New_York:...` is honoured. `DTSTART;VALUE=DATE:20261021` is an all-day item at local midnight, with `isAllDay == true` and no end.
4. Trailing `[ENGL101]` is split into `courseCode`, and the title keeps its inner brackets (`"Essay [draft] 2 [ENGL101]"`). A title with no trailing bracket gets a nil course code.
5. Kind inference from the UID: `event-assignment-1` is `.assignment`, `event-calendar-event-2` is `.calendarEvent`, quiz is `.quiz`, unknown is `.other`.
6. Escapes (`\n`, `\,`, `\;`, `\\`) are decoded in SUMMARY, DESCRIPTION and LOCATION. `X-ALT-DESC` is ignored.
7. A VEVENT without UID or DTSTART is skipped, counted in `skippedEventCount`, and the other events survive.
8. DTEND equal to DTSTART gives `endDate == nil`. Empty input and non-ICS input (`<html>`) give `[]`.
9. Fingerprint is stable across runs, and changes when title, time, location or description changes.
10. Two events sharing a UID (override case) keep the last, with the count reported by the helper.

Planner (`diff`):
11. nil previous gives all added with `isFirstSync == true`. Identical lists give an empty diff.
12. A title change gives `changed` with `[.title]`. A time change gives `[.start]`, or `[.start, .end]` as appropriate. Multiple fields are sorted.
13. A UID missing from the current list is `removed`. A new UID is `added`. A reordered list gives an empty diff.
14. `unchangedCount` is correct, and a mixed diff has correct counts and `summaryLine`.

StudyBlockPlanner:
15. An empty calendar plus one assignment due in 3 days gives a block of the configured length inside working hours, before the due date.
16. Blocks never overlap busy intervals, and keep `bufferMinutes` clear of them.
17. A gap shorter than `minimumGapMinutes` is skipped. `maximumBlocksPerDay` is honoured.
18. Output is deterministic (same inputs give the same ids and times), and ids in `alreadyProposedOrCreatedIDs` are excluded.
19. Disabled settings, no assignments, and past or beyond-lookahead due dates give `[]`. Blocks never start in the past (`now` rounds up to the next 15 minutes).
20. DST-change day boundaries use the `Calendar` passed in.

Validator:
21. https passes. `webcal://` is rewritten to https. http, `file:`, `javascript:`, empty, spaces only, a bare host without scheme, and `https://user:pw@host/...` are rejected with the right case.
22. `maskedDisplay` contains the host and never the path or the token. Round-trip: the error descriptions never contain the input.

### Tests/DayChecklist (package B): `DayChecklistBuilder` and the `ChecklistItem` codec

1. A Canvas item due today becomes a `.canvasDue` row with course code and time in the subtitle. Items due tomorrow or later are excluded.
2. Today's calendar events (excluding all-day Canvas duplicates by title) become `.calendarEvent` rows, ordered by time.
3. Unfinished yesterday items come first with `rolloverCount + 1`. Completed ones are dropped.
4. Items at rollover 3 keep their original due date and are marked overdue. A rolled item that is also in the new day's Canvas list is not duplicated, and the stable id merges them.
5. The cap `maximumItems` keeps rollovers and soonest due first, and drops lowest-priority events last.
6. Approved study blocks for today appear as `.studyBlock` rows.
7. Ids are stable across two builds for the same input, so the reminder map is idempotent.
8. `dayKey` is `yyyy-MM-dd` in the given calendar's timezone, including near midnight and DST.
9. Empty input gives `[]`. Codable round-trip keeps completion and rollover.

EventKit actors (`WispCalendarWriter`, `WispTodayReminders`) are untestable headless. B keeps their decision logic (map repair, which items to create, update or delete) in pure helpers inside `DayChecklistBuilder.swift` or a `JobsEventKitPlanning` enum, with extra cases in `Tests/DayChecklist`: "diff to write operations", "rebuild plan: keep, add, remove", "map repair from notes UID".

### Package W / U / N / H verification (no xcodebuild)

- W: `Tests/AgentRuntimeIntegration/run.sh` must still compile. A small `JobsEngine` test with injected fakes for feed, writer and reminders (protocols declared in `JobsEngine.swift`) covers: empty diff gives no card, a first sync gives one summary, a second sync gives zero writes, and a failure keeps the previous snapshot.
- U / N / H: compile via `AgentRuntimeIntegration`, plus `Tests/BrainCore` and `Tests/BuddyThread` for enum and symbol references. H also checks that persisted files are untouched.

## 8. Definition of done

1. All new suites and `AgentRuntimeIntegration`, `BrainCore`, `BuddyThread`, `WindowManagement` and `EditableConfirmation` pass.
2. The window bar shows Today, Chat, Jobs, Settings, with ⌥⌘1-4.
3. With the Advanced toggle on, the old sections return unchanged. With it off, no data is lost.
4. Pasting a feed URL and pressing Sync produces the "Wisp" calendar, a diff card, and (on approval) study blocks. A second sync writes nothing.
5. The morning checklist shows in the notch and replaces the generic banner. Ticking it completes the Reminders item, and ticking in Reminders shows up in the notch.
6. `CLAUDE.md` has the new Key Files rows and the Canvas network-use note. Nothing is committed without the user asking.
