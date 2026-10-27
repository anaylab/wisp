# Fun glass, buddies, automations: cross-package contracts

Written first by the plan step of the workflow. Source of truth for every type that crosses a package
boundary. Plan: `docs/fun-glass-buddies-automations-plan.md`. If a package finds a signature here
unworkable, it keeps the name and shape, adds what it needs, and says so in its hand-off. It does not
rename.

Locked decisions (from the user, not negotiable by any package):

1. The notch island is solid black by default. A switch "Tint the island with my theme" (off by default)
   is the only way the theme reaches the notch surface.
2. Playful celebrations (a small bounce and a soft burst when a checklist is finished, a streak count)
   sit behind a "Playful" switch that defaults ON and honours Reduce Motion.
3. Buddies are first-class again. Advanced hides only delegation (`ask_buddy`), per-buddy models and
   sharing.
4. The cursor companion never comes back.
5. A scheduled (unattended) run never auto-approves anything outward-facing.

Conventions that apply to all code below: long clear names, no single-letter variables, comments explain
why, no hardcoded hex outside theme definitions, `.pointerCursor()` on every button, UI state on
`@MainActor`. The app target defaults to MainActor isolation, so every pure value type and enum that is
used off the main actor, or compiled into a `Tests/<Name>/run.sh` suite, is marked `nonisolated`.
NEVER run `xcodebuild` or launch the app binary. Do not commit.

Stub-first rule: a package whose view or type is referenced by another package creates that file with the
exact signature below as its first action (body may be minimal), so consumers compile against it. Final
integration is the `Tests/AgentRuntimeIntegration` compile after all packages land.

---

## 0. Packages and file ownership

| Pkg | Name | Owns (paths relative to `leanring-buddy/` unless noted) |
|---|---|---|
| T | Theme + glass | `DesignSystem/WispColors.swift`, `DesignSystem/WispGradients.swift`, new `DesignSystem/WispTheme.swift`, `DesignSystem/WispThemeStore.swift`, `DesignSystem/WispThemeContrast.swift`, `Components/WispThemeBackdrop.swift`, `Components/WispThemePicker.swift`, `Components/WispGlassComponents.swift`, `Components/WispBento.swift`, `Components/WispPill.swift`, `Components/WispSegmented.swift`, `Components/WispLiquidRim.swift`, `DynamicIsland/NotchIslandStyle.swift`, `DesignSystem.swift` (facade only if a token moves), the Appearance card inside `WispWindow/GeneralSettingsPage.swift` (only the Appearance block; one new file `WispWindow/AppearanceSettingsCard.swift` holds it), `Tests/WispTheme/*` |
| B | Buddies | `Buddies/*` (including `BuddyStore.swift`, `BuddyAvatar.swift`, `BuddyCharacter.swift`, `BuddyMood.swift`, `BuddySpecialty.swift`, `BuddyThread.swift`, `BuddyViews.swift`), new `Buddies/BuddyPersonality.swift`, `Buddies/StarterBuddies.swift`, `Buddies/BuddyPersonalityPicker.swift`, `Buddies/PlayfulCelebration.swift`, `Buddies/ChecklistStreak.swift`, `WispWindow/Buddies/*`, `WispWindow/BuddiesPage.swift`, the buddy flank and NEW-list faces inside `NotchHUDView.swift` (edit with `Edit`, never overwrite: the file holds the user's uncommitted notch trim, keep it), `DynamicIsland/NotchWorkspaceView.swift` (buddy rows only), `DynamicIsland/DailyChecklistView.swift` (celebration only), `Tests/BuddyThread/*` additions, new `Tests/BuddyPersonality/*` |
| A | Automations core | new `Automations/*` (every file listed in section 4), `Tests/AutomationDraft/*`, `Tests/AutomationSchedule/*`, `Tests/AutomationMigration/*`, `Tests/AutomationEngine/*`. Bounded edits in unowned shared files: `CompanionManager.swift` (one contiguous block `startAutomationRun` placed directly after `startBuddyRun`, plus one launch line calling `AutomationEngine.configureLive`), `AgentToolRegistry.swift` (read-only: needs nothing, uses `requiresConfirmation(forToolNamed:)` as it is). A never edits `JobsEngine.swift`, `RoutineStore.swift`, `BuddyStore.swift` |
| U | Automations UI | new `WispWindow/Automations/*` (section 6 lists the files), `Tests` none (views) |
| N | Navigation + hub | `WispWindow/WispNavigation.swift`, `WispWindow/WispWindowView.swift`, `HomeTab.swift` (Today: next-runs tile mount, Needs-you additions, day buddy greeting mount), `WispWindow/JobsTab.swift` (kept as the Canvas settings page, renamed in navigation only), `WispWindow/WispAdvancedFeaturesPreference.swift`, `WispWindow/ChatPage.swift` only if navigation needs it |
| Q | Quick add, first run, menu | new `QuickAdd/AutomationQuickAddRouter.swift`, new `FirstRun/FirstRunSetupFlow.swift`, `FirstRun/WispFirstRunState.swift`, `MenuBarMenuController.swift`, `TextComposerWindowController.swift` (placeholder text and routing only), `FastCommandRouter.swift` (the hook only), the transcript hook inside `CompanionManager.swift` `sendTranscriptToClaudeWithScreenshot` (a single early-return block, after A's edits have landed), `Tests/AutomationQuickAdd/*` |

Phases: contracts, then T, B, A, N in parallel (disjoint files), then U (needs A's types), then Q (needs A
and U), then review lenses and the `CLAUDE.md` update. Where two packages must touch the same file, the
earlier phase edits first and the later one rebases on the file as it is on disk (always `Read` before
`Edit`).

Nobody touches: `JobsEngine.swift`, `Jobs/*`, `RoutineStore.swift`, `RoutineParameters.swift`,
`BackgroundTaskLauncher.swift`, `AgentTurnRunner.swift`, `ToolConfirmationCoordinator.swift`,
`MorningBriefing.swift`. They are read-only dependencies of the new code.

---

## 1. Package T: theme

All in `nonisolated` value types so `NSColor` dynamic providers (which run off the main actor) can read
them, and so `Tests/WispTheme/run.sh` can compile `WispTheme.swift` + `WispThemeContrast.swift` alone
(Foundation only: hex strings, no SwiftUI in those two files).

```swift
// DesignSystem/WispTheme.swift  (Foundation only)

nonisolated enum WispThemeID: String, Codable, CaseIterable, Identifiable, Sendable {
    case sage        // current default, values identical to today's WispColor.Brand
    case candy
    case sunset
    case mint
    case berryNight
    case mono
    var id: String { rawValue }
}

/// One colour that resolves differently in light and dark. Hex strings ("#RRGGBB") live ONLY in theme
/// definitions; nothing else in the app writes a hex literal.
nonisolated struct WispThemeColorPair: Equatable, Sendable {
    let lightHex: String
    let darkHex: String
}

nonisolated struct WispTheme: Identifiable, Equatable, Sendable {
    let id: WispThemeID
    let name: String                                  // "Sage", "Candy", "Sunset", "Mint", "Berry Night", "Mono"
    /// Fills: selected tab, prominent pill, switch. Must carry `textOnAccentHex` at >= 4.5:1.
    let accent: WispThemeColorPair
    let accentHover: WispThemeColorPair
    /// The accent used as text or a thin icon on surfaces. >= 4.5:1 on `background` in light and dark.
    let accentText: WispThemeColorPair
    /// Text colour on top of `accent` fills ("#FFFFFF" or a near-black).
    let textOnAccentHex: String
    /// A second hue for secondary highlights and the end of the signature gradient.
    let secondaryAccent: WispThemeColorPair
    /// The AI-activity accent (today's lavender): thinking, listening glow, live rim.
    let aiActivityAccent: WispThemeColorPair
    /// Exactly 3 stops: top-left, middle, bottom-right of the window backdrop and the signature gradient.
    let backdropStops: [WispThemeColorPair]
    /// Exactly `WispTheme.buddyPaletteCount` (8) entries: `light` = the character's light tone,
    /// `deep` = its deep tone, in the same index order as today's `BuddyAppearance` palette.
    let buddyPalette: [WispThemeBuddyColor]
    /// A dark tone (always dark, both appearances) used for the island ONLY while "Tint the island with
    /// my theme" is on. Never used when the switch is off.
    let islandTintHex: String
    /// 0...1. How strongly cards and bars take the backdrop's colour (alpha of the glass tint).
    let glassTintStrength: Double

    static let buddyPaletteCount = 8
    static let all: [WispTheme]                      // the six, in picker order
    static let defaultTheme: WispTheme               // .sage
    static func theme(withID themeID: WispThemeID) -> WispTheme
}

nonisolated struct WispThemeBuddyColor: Equatable, Sendable {
    let lightHex: String
    let deepHex: String
}
```

```swift
// DesignSystem/WispThemeContrast.swift  (Foundation only, used by Tests/WispTheme)

nonisolated enum WispThemeContrast {
    /// WCAG relative-luminance contrast ratio of two "#RRGGBB" colours, 1...21.
    static func ratio(foregroundHex: String, backgroundHex: String) -> Double
    /// Hex of `foreground` composited at `alpha` over `background`.
    static func blendedHex(foregroundHex: String, alpha: Double, overBackgroundHex: String) -> String
    /// Every contrast failure for a theme, as readable strings; empty = pass.
    /// Checks, in light and dark: accentText vs the window background >= 4.5, textOnAccent vs accent >= 4.5,
    /// aiActivityAccent vs background >= 3.0, each backdrop stop blended at `glassTintStrength` under the
    /// primary text colour >= 4.5.
    static func failures(for theme: WispTheme) -> [String]
}
```

```swift
// DesignSystem/WispThemeStore.swift

@MainActor
final class WispThemeStore: ObservableObject {
    static let shared = WispThemeStore()

    @Published var currentThemeID: WispThemeID          // persisted, key "wisp.theme.id", default .sage
    /// "Tint the island with my theme". Key "wisp.theme.tintsIsland", default false.
    @Published var tintsIsland: Bool
    /// "Playful". Key "wisp.theme.playful", default true.
    @Published var isPlayful: Bool

    var currentTheme: WispTheme { get }

    /// Playful AND the system's Reduce Motion is off. Every celebration, bounce, burst and drifting
    /// backdrop checks this, never `isPlayful` alone.
    var allowsPlayfulMotion: Bool { get }

    // Synchronous reads for code that is not on the main actor: dynamic NSColor providers, Canvas,
    // tests. They read the same UserDefaults keys.
    nonisolated static var currentThemeNow: WispTheme { get }
    nonisolated static var tintsIslandNow: Bool { get }
    nonisolated static var isPlayfulNow: Bool { get }
    nonisolated static var allowsPlayfulMotionNow: Bool { get }   // isPlayfulNow && !reduce-motion
}

extension Notification.Name {
    /// Posted after `currentThemeID` changes. Dynamic NSColors do not observe anything, so the window
    /// root re-evaluates by keying its content on `currentThemeID` (`.id(...)`); AppKit-drawn surfaces
    /// listen for this.
    static let wispThemeDidChange = Notification.Name("wispThemeDidChange")
}
```

Token behaviour (no call-site edits needed): `WispColor.accent`, `.accentHover`, `.accentText`,
`.accentSubtle`, `.intelligence`, `.glassTint`, `.glassCardTint` and `WispGradient.signatureStops`
change from `static let` of fixed values to values built from `WispThemeStore.currentThemeNow` inside the
dynamic `NSColor` provider (`WispColor.adaptive(light:dark:)` re-resolves on every draw, so a theme change
repaints once the root is re-keyed). Their names and types do not change. `WispColor.Brand.*` stays as the
Sage theme's raw values and stays used by the mark and app icon. Neutrals (`background`, `surface1...4`,
text colours, borders) stay theme-independent so contrast is predictable; only the backdrop and glass tints
take theme colour.

Island contract (T implements, B and Q only read):

```swift
extension WispColor.Island {
    /// Black unless the tint switch is on. When on: `theme.islandTintHex` (already dark).
    static var surface: Color { get }                  // was `static let surface = Color.black`
    /// Convenience for non-view code.
    static func surfaceColor(tinted: Bool, theme: WispTheme) -> Color
}
```

`wispNotchIslandSurface(in:style:)` keeps its signature. With the switch OFF, output is pixel-identical to
today (pure black, same rim). With it ON, the black style fills with `Island.surface`, the rim uses the
theme `aiActivityAccent`, and the Liquid Glass style adds the theme tint to its glass.

Glass and backdrop (T):

```swift
// Components/WispThemeBackdrop.swift
struct WispThemeBackdrop: View {
    /// Blurred gradient blobs from `theme.backdropStops`, slow drift. Drift stops when the window is not
    /// key, when `isActive` is false, or when Reduce Motion is on (static blobs then).
    init(isActive: Bool = true)
}
extension View {
    /// Card/bar/pill glass: `.glassEffect` inside the caller's `GlassEffectContainer`, tinted by
    /// `glassTintStrength`. Falls back to the existing `wispBentoSurface` look if called outside a container.
    func wispWindowGlass(in shape: some Shape, interactive: Bool = false) -> some View
}
// Components/WispThemePicker.swift
struct WispThemePicker: View { init() }              // six swatch cards, live preview, binds WispThemeStore.shared
```

The Appearance card (`WispWindow/AppearanceSettingsCard.swift`, `struct AppearanceSettingsCard: View`)
holds, in this order: System/Light/Dark (existing `WispAppearancePreference`), `WispThemePicker`, the
"Tint the island with my theme" switch (off by default), the "Playful" switch (on by default). Copy: switch
labels only, no explanatory paragraph.

`Tests/WispTheme/run.sh`: for every theme assert `WispThemeContrast.failures(for:)` is empty, `backdropStops.count == 3`,
`buddyPalette.count == 8`, hex strings parse, ids are unique, `.sage` equals today's Brand values.

---

## 2. Package B: buddies

```swift
// Buddies/BuddyPersonality.swift  (Foundation only, nonisolated, testable)

nonisolated enum BuddyPersonality: String, Codable, CaseIterable, Identifiable, Sendable {
    case coach, chill, hype, deadpan, teacher
    var id: String { rawValue }

    var title: String { get }                          // "Coach", "Chill", "Hype", "Deadpan", "Teacher"
    var tagline: String { get }                        // one short line for the picker
    var symbolName: String { get }                     // SF Symbol
    /// Added to the buddy's system prompt after the specialty line. Work style only: no romance or roleplay.
    var personaLine: String { get }
    var replyStyle: BuddyReplyStyle { get }
    var voice: BuddyVoiceProfile { get }
    var reaction: BuddyReactionProfile { get }
}

nonisolated struct BuddyReplyStyle: Equatable, Sendable {
    let maximumSentences: Int                          // soft cap stated in the prompt
    let tone: String                                   // e.g. "warm and direct", used inside personaLine
    let usesEmoji: Bool
}

nonisolated struct BuddyVoiceProfile: Equatable, Sendable {
    /// A Kokoro voice id (FluidAudio). `KokoroSynthesisEngine.voiceIdentifier` ("af_heart") is today's
    /// only voice and stays the fallback. If the engine cannot take a per-call voice, the field is stored
    /// and ignored (the picker does not promise a voice change); B decides after reading
    /// `FluidAudioSpeechModels.swift` and must not change that file's public behaviour.
    let kokoroVoiceIdentifier: String
    let speakingRate: Double                           // 1.0 = normal; clamped 0.8...1.25
}

nonisolated struct BuddyReactionProfile: Equatable, Sendable {
    /// How big the finish celebration is when Playful is on. 0 = none, 1 = bounce, 2 = bounce + burst.
    let celebrationLevel: Int
    /// Mood word shown on the rail for each `BuddyMood` (e.g. hype: .happy -> "pumped").
    func moodWord(for mood: BuddyMood) -> String
}

extension WispBuddy {
    /// New optional fields (Codable, optional so an older buddies.json still loads):
    var personality: BuddyPersonality? { get set }     // nil = neutral, today's behaviour
    var starterKind: StarterBuddyKind? { get set }     // nil for user-made buddies
}
```

`BuddyThreadPolicy.systemPromptAddendum(buddyName:job:specialtyLine:)` gains
`personalityLine: String? = nil` (default keeps every existing call site valid). `BuddyStore` gains
`updatePersonality(ofBuddyWithID:to:)` and `createBuddy(... personality:)` with a defaulted parameter.

```swift
// Buddies/StarterBuddies.swift

nonisolated enum StarterBuddyKind: String, Codable, CaseIterable, Sendable {
    case planner       // Canvas + checklist
    case briefer       // morning brief
    case focus         // study blocks
}

nonisolated struct StarterBuddyDefinition: Identifiable, Equatable, Sendable {
    /// Fixed so Automation migration and templates can name a starter buddy before it is created.
    let id: UUID
    let kind: StarterBuddyKind
    let name: String                                   // "Planner", "Briefer", "Focus"
    let specialty: BuddySpecialty
    let defaultPersonality: BuddyPersonality
    let colorIndex: Int
    let jobInstruction: String
    /// Templates that start switched OFF on this buddy, ready to enable (first-run step 4 flips them on).
    let readyAutomationTemplateIDs: [AutomationTemplateID]

    static let all: [StarterBuddyDefinition]
    static func definition(for kind: StarterBuddyKind) -> StarterBuddyDefinition
    static let plannerBuddyID = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A1")!
    static let brieferBuddyID = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A2")!
    static let focusBuddyID   = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A3")!
}
```

`BuddyStore` additions (B):

```swift
extension BuddyStore {
    /// Adds the three starters once (UserDefaults key "wisp.buddies.startersSeeded"). Deleting one sticks.
    /// Inserts WITHOUT starting a run: `createBuddy` runs a one-off buddy immediately, a starter must not.
    func ensureStarterBuddies()
    func insertBuddyWithoutRunning(_ buddy: WispBuddy)

    /// Legacy scheduling switch. `runDueBuddies` skips any buddy whose id is in this set, because an
    /// Automation now owns that job's schedule. Set by A's migration at launch; never persisted by
    /// BuddyStore. Default empty (old behaviour).
    var buddyIDsWhoseSchedulesAreOwnedByAutomations: Set<UUID> { get set }
}
```

Buddy visual theme and notch (B):

- `BuddyAppearance.palette` reads `WispThemeStore.currentThemeNow.buddyPalette` instead of its literal
  colours (index order and `paletteCount == 8` unchanged). The literal Sage values move into T's `.sage`
  definition.
- Notch flank: the working buddy's character (`BuddyAvatar`) sits in the left flank while an automation or
  buddy run is active, and bounces when it finishes if `WispThemeStore.shared.allowsPlayfulMotion`. Inputs
  (all read-only, from A): `AutomationEngine.shared.activeBuddyIDs`, `.lastFinishedBuddyID`,
  `.finishedBounceTrigger`. The hover panel's NEW list shows the buddy face beside each result, found with
  `AutomationRunHistoryStore.shared.buddyID(forTaskID:)`, falling back to `BuddyStore` run ids.
- The notch surface stays black; the buddy colour is an accent once per surface, as before.

```swift
// Buddies/PlayfulCelebration.swift
struct PlayfulBurst: View { init(trigger: Int, accentColor: Color) }   // soft particles, ~0.9s, no-op unless allowsPlayfulMotion
extension View {
    func playfulBounce(trigger: Int) -> some View                        // small spring squish, no-op unless allowsPlayfulMotion
}

// Buddies/ChecklistStreak.swift  (pure part nonisolated)
nonisolated enum ChecklistStreakPolicy {
    /// Consecutive local days (ending today or yesterday) on which the whole checklist was finished.
    static func currentStreak(completedDayKeys: Set<String>, today: Date, calendar: Calendar) -> Int
    static func dayKey(for date: Date, calendar: Calendar) -> String      // "yyyy-MM-dd", same as MorningBriefingSchedule.dayKey
}
@MainActor final class ChecklistStreakStore: ObservableObject {
    static let shared = ChecklistStreakStore()
    @Published private(set) var currentStreakDays: Int
    @Published private(set) var celebrationTrigger: Int                  // increments each time a checklist is finished
    /// Called by DailyChecklistView when every item of today's checklist is complete. Idempotent per day.
    func recordChecklistFinished(today: Date)
}
// Buddies/BuddyPersonalityPicker.swift
struct BuddyPersonalityPicker: View { init(selection: Binding<BuddyPersonality>) }
```

Greeting by the day's buddy (B): `BuddyStore.dayBuddy(on: Date) -> WispBuddy?` (stable choice per local day
among unpaused buddies, preferring the Briefer) and `static func greetingLine(for buddy: WispBuddy, hour: Int) -> String` (uses personality). N mounts them on Today.

Advanced (B/N): the Advanced switch no longer hides buddies, characters, specialties or the Buddies page.
It hides only: `ask_buddy` delegation UI and tool, `BuddyModelEditor` / per-buddy model, and Share this
buddy / Import. `BuddyViews`/`BuddyInspectorView` read `WispAdvancedFeaturesPreference` for those three only.

---

## 3. Package N: navigation

```swift
enum WispSection: String, CaseIterable, Identifiable {
    case home, chat, buddies, brain, routines, history, connections, settings   // .jobs REMOVED
    static func visibleSections(advancedEnabled: Bool) -> [WispSection]
    // advanced off: [.home, .chat, .buddies, .settings]
    // advanced on:  allCases (Today, Chat, Buddies, Brain, Routines, History, Connections, Settings)
}

enum WispPage: String, CaseIterable, Identifiable {
    case home, chat
    case buddies                 // the messenger
    case automations             // NEW: Automations page, inside the Buddies section (owner U)
    case canvas                  // NEW: the old Jobs settings (Canvas feed link, checklist, study blocks), JobsTab content
    case routines
    case brainPages, brainGraph, brainInbox, brainHealth, brainLog, brainSettings
    case timeline, marketplace, tools, sources
    case general, shortcuts, dictation, agent, model
    // `.jobs` is removed. Anything that opened `.jobs` now opens `.automations`.
}
// WispSection.buddies.pages == [.buddies, .automations, .canvas]
// pagesFoldedIntoSettingsWhenAdvancedIsOff stays [.routines, .timeline, .marketplace, .tools, .sources]
// WispPage.isHiddenWhenAdvancedIsOff: only the brain pages (buddies are NOT hidden any more)
```

`WispWindowRouter` additions (all `@Published` on the shared `@MainActor` router):

```swift
@Published var automationIDToOpen: UUID?               // set by Today tile / notch / Q; the Automations page takes and clears it
@Published var isNewAutomationRequested: Bool          // the "New automation" entry (menu bar, Buddies "+")
@Published var pendingAutomationDraft: AutomationDraft?// Q puts a parsed draft here; U shows the draft card pre-filled, takes and clears it
@Published var isFirstRunSetupRequested: Bool          // N shows FirstRunSetupFlow as a sheet when true

func presentAutomationDraft(_ draft: AutomationDraft)  // sets pendingAutomationDraft, select(.automations)
func presentNewAutomation()                            // sets isNewAutomationRequested, select(.automations)
```

Today (N, `HomeTab.swift`): mounts `AutomationNextRunsTile()` (owner U) as a bento tile, and feeds
`AutomationEngine.shared.needsYou` into the existing "Needs you" alerts (failures with a reason, runs that
were declined for approval). N does not interpret automations; it only mounts U's view and renders A's
`AutomationAttentionItem`.

N mounts `FirstRunSetupFlow(onFinished:)` (owner Q) from `WispWindowView` as a sheet over Today while
`WispFirstRunState.shared.isCompleted == false` and `isFirstRunSetupRequested` is not suppressed.

---

## 4. Package A: automations core

New folder `Automations/`. Foundation-only files are marked (pure); they are `nonisolated`, compile into
the three pure test suites, and must not import SwiftUI, EventKit or AppKit.

| File | Contents |
|---|---|
| `Automations/Automation.swift` (pure) | `Automation`, `AutomationTrigger`, `AutomationEvent`, `AutomationSource`, `AutomationAction`, `AutomationOutput`, `AutomationNotifyPolicy`, `AutomationLegacyOrigin` |
| `Automations/AutomationSchedule.swift` (pure) | `AutomationSchedule` |
| `Automations/AutomationDraft.swift` (pure) | `AutomationDraft`, `AutomationDraftField`, `AutomationBuddyReference` |
| `Automations/AutomationDraftParser.swift` (pure) | `AutomationDraftParser` |
| `Automations/AutomationTemplates.swift` (pure) | `AutomationTemplateID`, `AutomationTemplate`, `AutomationTemplates` |
| `Automations/AutomationRunRecord.swift` (pure) | `AutomationRunRecord`, `AutomationRunOutcome`, `AutomationRunReason`, `AutomationAttentionItem` |
| `Automations/AutomationMigration.swift` (pure planning) | `AutomationMigrationPlanner`, legacy snapshot structs |
| `Automations/AutomationStore.swift` | `AutomationStore`, `AutomationRunHistoryStore` |
| `Automations/AutomationEngine.swift` | `AutomationEngine`, `AutomationEngineDependencies`, `AutomationToolPolicy` |
| `Automations/AutomationLiveWiring.swift` | live adapters: `AutomationEngine.configureLive(companionManager:)`, notch presenter, Reminders/Calendar adapters over `JobsEngine`/`WispTodayReminders`/`WispCalendarWriter` |
| `Automations/AutomationMigrationRunner.swift` | reads the old stores read-only, applies the plan to `AutomationStore` |

### 4.1 Model

```swift
nonisolated struct Automation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// The owning buddy. Nil only transiently (a draft before a buddy is chosen); the store assigns the
    /// day's Planner/Briefer when saving without one.
    var buddyID: UUID?
    var trigger: AutomationTrigger
    var source: AutomationSource
    var action: AutomationAction
    var outputs: [AutomationOutput]                    // at least one; [.notchCard] is the default
    var notify: AutomationNotifyPolicy
    var isEnabled: Bool                                // false = paused
    var symbolName: String                             // SF Symbol, from RoutineStore.availableSymbolNames or template
    /// Manual triggers only: the Talk-chord digit (1...9). Informational for a migrated routine, whose
    /// digit keeps firing through RoutineStore (no double fire); live for a new automation.
    var shortcutDigit: Int?
    /// Blank values ({topic|default}) remembered between manual runs, same syntax as RoutineParameters.
    var parameterValues: [String: String]?
    let createdAt: Date
    var lastRunAt: Date?
    var nextRunAt: Date?                               // cached from the schedule; nil for manual/event
    var legacyOrigin: AutomationLegacyOrigin?          // set by migration, nil otherwise
    var schemaVersion: Int                             // 1
}

nonisolated enum AutomationTrigger: Codable, Equatable, Sendable {
    case schedule(AutomationSchedule)
    case event(AutomationEvent)
    case manual
}

nonisolated enum AutomationEvent: Codable, Equatable, Sendable {
    case newCanvasItem
    case meetingStarting(minutesBefore: Int)           // 1...120
    case screenTextAppears(text: String)               // backed by ScreenWatcherStore, one watch per automation
    case fileDropped(folderPath: String)               // polled folder, files added since the last look
}

/// What data the run starts from. Fetched by Wisp (no model) and put in front of the model as DATA.
nonisolated enum AutomationSource: Codable, Equatable, Sendable {
    case nothing
    case todaysCalendar
    case canvasDeadlines(withinDays: Int)
    case reminders(listName: String?)
    case clipboard
    case screenText
    case folderFiles(path: String)
}

nonisolated enum AutomationAction: Codable, Equatable, Sendable {
    /// A model turn: the instruction (with `{blank|default}` blanks) plus the source data. The buddy's
    /// persona, memory and thread apply.
    case askBuddy(instruction: String)
    /// Existing JobsEngine work, no model. The automation is DRIVEN BY JobsEngine: see 4.6.
    case syncCanvas
    case buildDailyChecklist
    /// Existing StudyBlockPlanner proposals; writing them always asks (JobsStudyBlockApproving).
    case proposeStudyBlocks
}

nonisolated enum AutomationOutput: Codable, Equatable, Hashable, Sendable {
    case notchCard                                     // reply in the notch + glance card if the answer carries one
    case remindersChecklist(listTitle: String)         // default list title "Wisp Today"; only Wisp's own lists
    case calendarBlock                                 // ALWAYS asks, even attended
    case notification
    case buddyThreadMessage                            // filed in the buddy's thread (BuddyThreadStore)
    case spokenLine                                    // the [SAY: ...] line, only in voice mode
}

nonisolated enum AutomationNotifyPolicy: String, Codable, CaseIterable, Sendable {
    case always, onlyWhenSomethingNew, onlyOnFailure, never
}

nonisolated enum AutomationLegacyOrigin: Codable, Equatable, Hashable, Sendable {
    case routine(UUID)                                 // WispRoutine.id
    case buddyJob(UUID)                                // WispBuddy.id
    case jobsCanvas
    case jobsDailyChecklist
}
```

Validation (`Automation.validationProblems() -> [String]`, empty = valid): non-empty name, at least one
output, `calendarBlock` only with `.proposeStudyBlocks` or an `.askBuddy` whose text says to schedule,
`meetingStarting` minutes in range, schedule fields in range, a scheduled `askBuddy` whose instruction
has a blank without a default is invalid ("needs a value for {topic}" because no one is there to answer).

### 4.2 Schedule

```swift
nonisolated struct AutomationSchedule: Codable, Equatable, Sendable {
    enum Recurrence: Codable, Equatable, Sendable {
        case once(Date)
        case daily
        case weekdays                                  // Monday to Friday
        case weekly(weekday: Int)                      // 1 = Sunday ... 7 = Saturday, as Calendar
        case monthly(dayOfMonth: Int)                  // 1...31; a short month runs on its last day
    }
    var recurrence: Recurrence
    var hour: Int                                      // 0...23, wall-clock in the zone below
    var minute: Int                                    // 0...59
    /// Nil = the Mac's current zone at evaluation time (so travel moves the run). A set identifier pins it.
    var timeZoneIdentifier: String?

    /// First run strictly after `date`; nil for a past `.once`. Built on Calendar.nextDate with
    /// `.nextTime` so a spring-forward gap runs at the next valid time and a fall-back repeat runs once.
    func nextRunDate(after date: Date, calendar: Calendar) -> Date?

    /// The latest scheduled slot in (`lastRunAt`, `now`], or nil. The engine runs a missed slot ONCE,
    /// never once per missed day. `lastRunAt == nil` uses `createdAt`.
    func missedRunDate(lastRunAt: Date?, createdAt: Date, now: Date, calendar: Calendar) -> Date?

    /// "Every weekday at 8:00 AM", "Every Monday at 9:00 AM", "On the 1st at 7:00 PM", "Once, Fri 3:00 PM".
    func summary(calendar: Calendar) -> String

    init(legacy buddySchedule: BuddySchedule)          // daily/weekly map across; .once is not a schedule (caller makes it .manual)

    /// Words in -> schedule, deterministic. Wraps `BuddySchedule.inferred(fromInstruction:)` for the
    /// words it knows and adds weekdays, monthly, "at 8", "at 3:30pm", "tomorrow", "tonight".
    /// Nil when the text names no time at all.
    static func inferred(fromText text: String, now: Date, calendar: Calendar) -> AutomationSchedule?
}
```

### 4.3 Drafts and the parser

```swift
nonisolated struct AutomationBuddyReference: Equatable, Sendable {
    let id: UUID
    let name: String
    let specialty: BuddySpecialty?
}

nonisolated enum AutomationDraftField: String, CaseIterable, Sendable {
    case name, trigger, source, output, buddy, notify
}

nonisolated struct AutomationDraft: Equatable, Sendable {
    var originalText: String
    var name: String
    var buddyID: UUID?
    var trigger: AutomationTrigger
    var source: AutomationSource
    var action: AutomationAction
    var outputs: [AutomationOutput]
    var notify: AutomationNotifyPolicy
    /// Fields the parser guessed or could not fill: the draft card highlights these chips.
    var uncertainFields: Set<AutomationDraftField>
    /// Why: a short, human reason per uncertain field ("I assumed 8:00 AM, change it if you meant evening").
    var notes: [AutomationDraftField: String]

    var isReadyToSave: Bool { get }                    // valid + no uncertain trigger/output
    func makeAutomation(id: UUID, now: Date) -> Automation
    init(from automation: Automation)                  // editing an existing one reuses the same card
    init(template: AutomationTemplate, buddyID: UUID?)
}

nonisolated enum AutomationDraftParser {
    enum Result: Equatable, Sendable {
        /// A complete draft; the card opens with nothing highlighted or only soft guesses.
        case draft(AutomationDraft)
        /// A draft plus the one thing the parser cannot decide. The card opens with that chip open.
        case needsChoice(AutomationDraft, field: AutomationDraftField, question: String)
        /// Looks like an automation but too unclear; a model may help (see modelAssist...).
        case unsure(AutomationDraft)
        /// An ordinary question or command. Q passes it on untouched.
        case notAnAutomation
    }

    static func parse(
        _ text: String,
        now: Date,
        calendar: Calendar,
        buddies: [AutomationBuddyReference]
    ) -> Result

    /// Cheap pre-check Q calls on every turn before any other work: recurrence words (every, each, daily,
    /// weekdays, weekly, monthly, nightly), "when ..." event phrases, "remind me ... at/tomorrow/on".
    /// "remind me in 10 minutes" and "set a timer" are NOT automations (FastCommandRouter owns timers).
    static func looksLikeAutomationRequest(_ text: String) -> Bool

    /// The text-only prompt for the local/selected model, used ONLY for `.unsure`. It asks for one JSON
    /// object naming draft fields. The model never runs anything.
    static func modelAssistPrompt(for text: String, partial: AutomationDraft) -> String
    /// Lenient JSON -> fills only fields it is allowed to (name, trigger, source, outputs, notify),
    /// validated by the same rules; returns nil if nothing usable came back.
    static func applyModelReply(_ reply: String, to partial: AutomationDraft) -> AutomationDraft?
}
```

Required parse behaviour (the `Tests/AutomationDraft` cases): "every weekday at 8 tell me what's due today"
-> weekdays 08:00, canvasDeadlines(1) or todaysCalendar, notchCard; "every morning summarize Hacker News" ->
daily 09:00 (soft guess noted), askBuddy; "every Sunday evening plan my week" -> weekly(1) 18:00;
"on the 1st of each month remind me to pay rent" -> monthly(1), remindersChecklist; "10 minutes before
every meeting show me the agenda" -> `.event(.meetingStarting(10))`; "when a new Canvas assignment shows up
tell me" -> `.event(.newCanvasItem)`; "tell me when the build says Succeeded" -> `.event(.screenTextAppears("Succeeded"))`;
"every day" with no time -> `.needsChoice(field: .trigger, ...)`; "what's the weather" -> `.notAnAutomation`;
"text size bigger" -> `.notAnAutomation`.

### 4.4 Templates

```swift
nonisolated enum AutomationTemplateID: String, Codable, CaseIterable, Identifiable, Sendable {
    case morningBrief, canvasDeadlines, dailyChecklist, weeklyReview, meetingPrep, focusBlock, studyPlan, screenWatch
    var id: String { rawValue }
}
nonisolated struct AutomationTemplate: Identifiable, Equatable, Sendable {
    let id: AutomationTemplateID
    let title: String
    let summary: String                                // one short line
    let symbolName: String
    let suggestedStarterBuddy: StarterBuddyKind
    let trigger: AutomationTrigger
    let source: AutomationSource
    let action: AutomationAction
    let outputs: [AutomationOutput]
    let notify: AutomationNotifyPolicy
    /// Blanks the card asks for before saving (e.g. screenWatch asks for the text to watch).
    let requiredBlanks: [String]
}
nonisolated enum AutomationTemplates {
    static let all: [AutomationTemplate]               // the eight, gallery order
    static func template(withID templateID: AutomationTemplateID) -> AutomationTemplate
}
```

Fixed defaults: morningBrief = weekdays 07:45, todaysCalendar + canvasDeadlines, notchCard + spokenLine;
canvasDeadlines = driven by JobsEngine canvas sync; dailyChecklist = driven by JobsEngine checklist (morning
window), output remindersChecklist("Wisp Today"); weeklyReview = weekly Sunday 18:00; meetingPrep =
`meetingStarting(10)`, todaysCalendar; focusBlock = proposeStudyBlocks, calendarBlock (always asks);
studyPlan = daily 19:00, canvasDeadlines(7), notchCard + remindersChecklist; screenWatch = `screenTextAppears`.

### 4.5 Store, history, runs

```swift
@MainActor
final class AutomationStore: ObservableObject {
    static let shared = AutomationStore()
    static let defaultFileURL: URL                     // ~/Library/Application Support/Wisp/automations.json (0600)
    init(fileURL: URL = AutomationStore.defaultFileURL)

    @Published private(set) var automations: [Automation]          // creation order

    func automation(withID automationID: UUID) -> Automation?
    func automations(ownedByBuddyID buddyID: UUID) -> [Automation]
    @discardableResult func add(_ automation: Automation) -> Automation
    func update(_ automation: Automation)
    func delete(automationID: UUID)
    func setEnabled(_ isEnabled: Bool, forAutomationID automationID: UUID)
    func markRan(automationID: UUID, at date: Date, nextRunAt: Date?)
    /// Unreadable file: leave it untouched, run empty (same rule as RoutineStore).
}

nonisolated enum AutomationRunReason: String, Codable, Sendable { case schedule, missedSchedule, event, manual, shortcutDigit, testRun }

nonisolated enum AutomationRunOutcome: Codable, Equatable, Sendable {
    case succeeded(summary: String)                    // first ~200 chars of the result
    case succeededNothingNew                           // ran, no change; not shown as news
    case failed(reason: String)                        // plain words, never a secret or a feed URL
    case needsApproval                                 // an unattended step was declined or timed out
    case skippedBusy                                   // another run of the same automation was active
    case skippedPaused
}

nonisolated struct AutomationRunRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let automationID: UUID
    let buddyID: UUID?
    let reason: AutomationRunReason
    let startedAt: Date
    var finishedAt: Date?
    var outcome: AutomationRunOutcome?                 // nil while running
    var resultText: String?                            // capped at 4000 chars, machine tags stripped
    var backgroundTaskID: UUID?                        // AgentTaskRegistry id, links to History
    var isTestRun: Bool                                // test runs are never persisted
}

nonisolated struct AutomationAttentionItem: Identifiable, Equatable, Sendable {
    let id: UUID                                       // the record id
    let automationID: UUID
    let title: String
    let detail: String                                 // the failure reason or "needs your OK"
    let occurredAt: Date
}

@MainActor
final class AutomationRunHistoryStore: ObservableObject {
    static let shared = AutomationRunHistoryStore()
    static let maximumRecordsPerAutomation = 30
    static let retentionDays = 30
    @Published private(set) var records: [AutomationRunRecord]     // newest first; ~/Library/Application Support/Wisp/automation-runs.json (0600)
    func records(forAutomationID automationID: UUID) -> [AutomationRunRecord]
    func latestRecord(forAutomationID automationID: UUID) -> AutomationRunRecord?
    func buddyID(forTaskID taskID: UUID) -> UUID?      // for the notch NEW list faces
    func clear(forAutomationID automationID: UUID)
    func append(_ record: AutomationRunRecord)
    func update(_ record: AutomationRunRecord)
}
```

### 4.6 Engine

```swift
@MainActor
final class AutomationEngine: ObservableObject {
    static let shared = AutomationEngine()

    struct UpcomingRun: Identifiable, Equatable, Sendable {
        let automationID: UUID
        let automationName: String
        let buddyID: UUID?
        let date: Date
        var id: UUID { automationID }
    }

    /// Next scheduled run of each enabled, scheduled automation, soonest first, max 8. Recomputed on every
    /// store change and every minute. Includes the two JobsEngine-driven automations (4.6 note).
    @Published private(set) var nextRuns: [UpcomingRun]
    @Published private(set) var runningAutomationIDs: Set<UUID>
    /// Buddies with an automation run in flight (the notch flank character).
    @Published private(set) var activeBuddyIDs: Set<UUID>
    /// Increments each time a run finishes successfully; B keys the bounce on it (Playful only).
    @Published private(set) var finishedBounceTrigger: Int
    @Published private(set) var lastFinishedBuddyID: UUID?
    /// Failures and declined approvals from the last 24h that the user has not dismissed; Today's "Needs you".
    @Published private(set) var needsYou: [AutomationAttentionItem]

    func start()                                       // minute timer + event listeners + migration; idempotent
    func stop()

    /// Runs now, unattended-safe rules apply when `reason` is a schedule/event reason. Returns the record.
    @discardableResult
    func run(automationID: UUID, reason: AutomationRunReason, parameterValues: [String: String]?) async -> AutomationRunRecord?

    /// Shows what a run WOULD produce, writing nothing: no Reminders, no Calendar, no thread entry, no
    /// notification, no record in history, no `lastRunAt`. Uses the same read-only tool rule as a
    /// scheduled run. Source data is fetched for real (reading is fine).
    func testRun(_ draft: AutomationDraft) async -> AutomationTestResult
    func testRun(automationID: UUID) async -> AutomationTestResult

    func setPaused(_ isPaused: Bool, forAutomationID automationID: UUID)   // maps to store.setEnabled(!isPaused)
    func dismissAttentionItem(id: UUID)

    /// Wires the live adapters. Called once from the launch path in CompanionManager (A's one-line edit).
    func configureLive(companionManager: CompanionManager)
}

struct AutomationTestResult: Equatable, Sendable {
    let previewText: String                            // what the notch card would say
    let wouldWrite: [String]                           // "Reminders: 4 items in Wisp Today", "Calendar: 2 blocks (will ask)"
    let problem: String?                               // set instead of previewText on failure
}
```

Schedule evaluation: every 60 s (`clockTick`), for each enabled `.schedule` automation not driven by
JobsEngine: if `missedRunDate(...)` is non-nil, run once with `.missedSchedule` (or `.schedule` if the slot
is within the last 90 s), then `markRan` and recompute `nextRunAt`. A run that cannot start because the
background-task limit is hit keeps its due state and retries the next tick. Overlapping runs of the same
automation: the second is recorded `.skippedBusy`.

Event triggers: `.newCanvasItem` listens to `JobsEngine.shared.latestDiff` (the added-items of each sync),
`.meetingStarting` polls `CalendarDataProvider.imminentTimedEventIfAuthorized` style data every 30 s (never
prompts), `.screenTextAppears` registers a watch through `ScreenWatcherStore` (A calls its public API only),
`.fileDropped` polls the folder every 30 s for files not seen before (set kept in the run record store).

JobsEngine-driven automations (`.syncCanvas`, `.buildDailyChecklist`): JobsEngine already owns its own
hourly and morning timers. The engine must NOT schedule them a second time. For these two, the automation
is a view onto JobsEngine: `nextRuns` derives their time from `JobsEngine.lastSyncedAt +
scheduledSyncIntervalSeconds` and the morning window; `setPaused` maps to
`JobsEngine.isCanvasJobEnabled` / `isDailyChecklistEnabled`; "Run now" calls `JobsEngine.syncNow()` /
`rebuildChecklistNow()`; the run record is written around those calls. JobsEngine is not edited.

Unattended safety (`AutomationToolPolicy`, pure):

```swift
nonisolated enum AutomationToolPolicy {
    /// A scheduled, event or test run exposes ONLY tools that never need confirmation, so nothing it does
    /// can depend on session auto-approve. Everything else (send, post, delete, calendar with guests, any
    /// MCP/Composio tool, cua-driver actions, run_shortcut, browser tasks) is simply not offered.
    static func permitsToolInUnattendedRun(toolName: String, requiresConfirmation: Bool) -> Bool {
        !requiresConfirmation
    }
}
```

Used as `AgentRunToolkit.permitsRegistryTool = { toolName in AutomationToolPolicy.permitsToolInUnattendedRun(toolName: toolName, requiresConfirmation: AgentToolRegistry.shared.requiresConfirmation(forToolNamed: toolName)) }`
**Exception (learned shortcuts, added later at the owner's request):** an `AutomationAction.replayLearnedShortcut`
replays tool calls the user saved and read on the save card, with no model choosing anything. For those steps only,
`AutomationToolPolicy.permitsRecordedShortcutStepInUnattendedRun(toolName:requiresConfirmation:)` allows a tool that
never asks for confirmation, including a trivial and reversible write such as music play/pause, which
`permitsToolInUnattendedRun` still refuses to a model. A step that asks (destructive, outward-facing, any other write)
is refused, as is a tool that isn't registered. The live replay checks every step before running the first, by metadata
and again by `ToolCallSafety` on the actual call, so no approval card is put up to an empty room. A manual run is
attended, so its steps ask as usual.
(A confirms the exact registry accessor when reading `AgentToolRegistry.swift`). `do_in_background` and
`ask_buddy` are never offered. A user pressing "Run now" (`reason == .manual` or `.shortcutDigit`) is an
attended run: the normal toolkit and the normal confirmation floor apply, still never bypassed by
`autoApproveThisSession` for anything on `ToolCallSafety`'s list. Output writes the engine does itself:
`remindersChecklist` only into Wisp-named lists via the existing writers; `calendarBlock` only through
`JobsStudyBlockApproving.askToWriteStudyBlocks`, which is on the always-ask list; if that card is not
answered the record is `.needsApproval` and the item lands in `needsYou`.

The one `CompanionManager` insertion (A), mirrors `startBuddyRun` because the system prompt and TTS are
private to that file:

```swift
// Inserted in CompanionManager.swift (a method of the class), directly after startBuddyRun:
func startAutomationRun(
    automation: Automation,
    buddy: WispBuddy?,
    resolvedInstruction: String,        // blanks filled, source data fenced as data
    isUnattended: Bool,                 // true => AutomationToolPolicy toolkit
    onSucceeded: @escaping @MainActor (UUID, String) -> Void
) -> UUID?                              // background task id, nil if the limit is reached
```

Title in History is `AgentTaskRecord.buddyRunTitlePrefix + buddy.name` for buddy-owned runs so existing
History code keeps working; the persona/memory/thread assembly is the same helper call chain as
`startBuddyRun` (A may factor a private helper in that file; it may not change `startBuddyRun`'s behaviour).

### 4.7 Migration (read-only on the old files)

```swift
nonisolated struct AutomationLegacySnapshot: Sendable {
    var routines: [WispRoutineSnapshot]
    var buddies: [WispBuddySnapshot]
    var jobsCanvasEnabled: Bool
    var jobsDailyChecklistEnabled: Bool
    var alreadyMigrated: Set<AutomationLegacyOrigin>
}
nonisolated struct WispRoutineSnapshot: Sendable { id, name, instruction, symbolName, shortcutDigit, lastParameterValues }
nonisolated struct WispBuddySnapshot: Sendable { id, name, instruction, schedule: BuddySchedule, notifiesWhenFinished: Bool? }

nonisolated enum AutomationMigrationPlanner {
    /// Pure: legacy snapshot -> automations to add. Skips anything in `alreadyMigrated`.
    static func plan(from snapshot: AutomationLegacySnapshot, plannerBuddyID: UUID, now: Date) -> [Automation]
}
```

Rules (each is a test in `Tests/AutomationMigration`, including a round trip: plan, encode, decode, plan
again = empty):

| Old | New |
|---|---|
| `WispRoutine` | `Automation(name: routine.name, buddyID: nil -> day's buddy, trigger: .manual, source: .nothing, action: .askBuddy(instruction: routine.instruction), outputs: [.notchCard], notify: .never, shortcutDigit: routine.shortcutDigit, parameterValues: routine.lastParameterValues, legacyOrigin: .routine(id))` |
| `WispBuddy` with `schedule == .daily(h,m)` | trigger `.schedule(daily h:m)`, `buddyID: buddy.id`, `action: .askBuddy(buddy.instruction)`, outputs `[.buddyThreadMessage, .notchCard]`, `notify: buddy.notifiesWhenFinished == false ? .never : .always`, `legacyOrigin: .buddyJob(buddy.id)` |
| `WispBuddy` with `.weekly(w,h,m)` | same with `weekly(weekday: w)` |
| `WispBuddy` with `.once` | trigger `.manual`, otherwise as above |
| Jobs Canvas (`JobsEngine.isCanvasJobEnabled` and a feed exists) | `Automation(name: "Canvas deadlines", buddyID: plannerBuddyID, trigger: .schedule(daily 07:00 placeholder, display only), action: .syncCanvas, outputs: [.notchCard], legacyOrigin: .jobsCanvas)`; `isEnabled` mirrors the JobsEngine switch |
| Jobs daily checklist | `Automation(name: "Daily checklist", buddyID: plannerBuddyID, action: .buildDailyChecklist, outputs: [.remindersChecklist(listTitle: "Wisp Today")], legacyOrigin: .jobsDailyChecklist)` |

The runner (`AutomationMigrationRunner.migrateIfNeeded()`) runs at every launch, is incremental by
`legacyOrigin`, and persists the set it has seen in `~/Library/Application Support/Wisp/automation-migration.json`.
It reads `routines.json`/`buddies.json` through `RoutineStore`/`BuddyStore` instances' in-memory arrays (no
file writes), never deletes or edits any old record, and after migrating a buddy job it sets
`BuddyStore.shared.buddyIDsWhoseSchedulesAreOwnedByAutomations` so the old minute scheduler stops running
that job (otherwise it would run twice). Routines keep working from the Routines page and their digit
shortcut through `RoutineStore` as today; the migrated automation is for scheduling and the shared run
history, and its digit is informational (no double fire). If the starter Planner has not been created yet,
migration calls `BuddyStore.shared.ensureStarterBuddies()` first.

Tests: `Tests/AutomationDraft`, `Tests/AutomationSchedule` (next run per recurrence, DST gaps and repeats
in `America/New_York` and `Europe/London`, month-end clamp, missed run runs once, once-in-the-past),
`Tests/AutomationMigration`, `Tests/AutomationEngine` (fake dependencies: unattended toolkit rule, busy skip,
test run writes nothing, JobsEngine-driven automations are not double scheduled, a declined approval becomes
`.needsApproval`).

---

## 5. Package Q: quick add, first run, menu bar

```swift
// QuickAdd/AutomationQuickAddRouter.swift
@MainActor
enum AutomationQuickAddRouter {
    /// Called early in sendTranscriptToClaudeWithScreenshot and for typed questions, AFTER FastCommandRouter
    /// (timers stay timers) and before the model. Returns true when it consumed the turn by opening the
    /// draft card; false means carry on as an ordinary turn. Skipped for dictation, titled routine/skill
    /// turns, and while agent confirmation is pending.
    static func route(_ transcript: String, buddyStore: BuddyStore, now: Date) -> Bool
}
// FirstRun/WispFirstRunState.swift
@MainActor final class WispFirstRunState: ObservableObject {
    static let shared = WispFirstRunState()
    @Published private(set) var isCompleted: Bool          // key "wisp.firstRun.completed"
    func markCompleted()
    func reset()                                           // Settings -> General "Run setup again"
}
// FirstRun/FirstRunSetupFlow.swift
struct FirstRunSetupFlow: View { init(onFinished: @escaping () -> Void) }
```

`FirstRunSetupFlow`, four steps, Skip on every step, one screen each: (1) `WispThemePicker`; (2)
`BuddyPersonalityPicker` for the Planner starter (`BuddyStore.updatePersonality`); (3) optional Canvas link
using `JobsEngine.shared.saveCanvasFeed(urlText:)` (the URL is a secret: never logged, never echoed); (4)
three template toggles (morningBrief, dailyChecklist, canvasDeadlines pre-suggested) that call
`AutomationStore.shared.add` with `AutomationDraft(template:buddyID:)`. It calls
`BuddyStore.shared.ensureStarterBuddies()` first. Nothing is enabled without a tap.

Menu bar (`MenuBarMenuController`): after "Ask Wisp..." add "New Automation..." which calls
`WispWindowRouter.shared.presentNewAutomation()` then `WispWindowNavigator.open(.automations)`. Nothing else
is added. "Pause Listening" stays.

Composer: placeholder text mentions "or say 'every weekday at 8...'"; routing is the router above, no new UI.

---

## 6. Package U: automations UI

All views are `@MainActor` SwiftUI in `WispWindow/Automations/`, using `WispPill`, `WispBento`, T's glass
helpers and `WispColor` tokens only. Signatures other packages rely on:

```swift
// AutomationsPage.swift  (WispPage.automations)
struct AutomationsPage: View { init() }                // list, "New", Say-it box, template gallery, empty state

// AutomationDraftCardView.swift  (the one editable card; all three setup paths end here)
struct AutomationDraftCardView: View {
    init(draft: AutomationDraft, onSave: @escaping (Automation) -> Void, onCancel: @escaping () -> Void)
}
// chips for trigger, source, output, buddy, notify (each tappable), Test run (calls AutomationEngine.testRun,
// writes nothing), Save. Uncertain fields are highlighted with their note.

// AutomationRunHistoryView.swift
struct AutomationRunHistoryView: View { init(automationID: UUID) }       // last result, time, failures with reason, pause switch

// AutomationTemplateGallery.swift
struct AutomationTemplateGallery: View { init(onPick: @escaping (AutomationTemplate) -> Void) }

// AutomationNextRunsTile.swift  (mounted by N on Today)
struct AutomationNextRunsTile: View { init() }         // reads AutomationEngine.shared.nextRuns; tap opens the page

// BuddyAutomationsSection.swift  (mounted by B in the buddy inspector's Automation tab)
struct BuddyAutomationsSection: View { init(buddyID: UUID) }

// SaveAsAutomationButton.swift  ("teach by example": mounted in HistoryTab by Q if time allows)
struct SaveAsAutomationButton: View { init(taskRecord: AgentTaskRecord) }
```

U consumes `WispWindowRouter.pendingAutomationDraft`, `automationIDToOpen` and `isNewAutomationRequested`
(takes and clears each). Teach-by-example builds a draft with `AutomationDraft(from:)`-style helper
`AutomationDraft.fromAnswerRecord(originalQuestion:)` (A provides, pure) so U holds no parsing logic.

---

## 7. What each package may assume from the others

- T assumes nothing. It must keep `WispColor`/`WispGradient`/`DS.*` names and types stable.
- B assumes T's `WispThemeStore` and `WispTheme.buddyPalette`, and A's `AutomationEngine` published fields,
  `AutomationRunHistoryStore.buddyID(forTaskID:)` and `AutomationTemplateID` (B only needs the enum).
- A assumes B's `StarterBuddyKind`, `StarterBuddyDefinition.*BuddyID`, `BuddyStore.ensureStarterBuddies()`,
  `BuddyStore.buddyIDsWhoseSchedulesAreOwnedByAutomations`, and `BuddySpecialty`.
- N assumes U's `AutomationNextRunsTile`, `AutomationsPage`, Q's `FirstRunSetupFlow`/`WispFirstRunState`, and
  A's `AutomationDraft`, `AutomationAttentionItem`.
- U assumes A's model/engine/store, T's glass helpers, B's `BuddyAvatar`.
- Q assumes A's parser and `AutomationStore`, N's router additions, U's views, B's picker, T's picker.

Stub-first files to create immediately (so the others compile): T `WispTheme.swift` + `WispThemeStore.swift`
+ `WispThemePicker.swift`; B `BuddyPersonality.swift` + `StarterBuddies.swift` + `BuddyPersonalityPicker.swift`;
A `Automation.swift` + `AutomationDraft.swift` + `AutomationTemplates.swift` + `AutomationEngine.swift`
(published fields) + `AutomationStore.swift`; U `AutomationNextRunsTile.swift` + `AutomationsPage.swift` +
`BuddyAutomationsSection.swift` + `AutomationDraftCardView.swift`; Q `FirstRunSetupFlow.swift` +
`WispFirstRunState.swift`.

## 8. Privacy and safety checklist (the review lens will check these)

- No automation, draft, run record or template ever contains the Canvas feed URL or any key.
- Source data (calendar, Canvas, clipboard, files, screen text) is fenced as data in the prompt, same as the
  clipboard blank today; page and file text is untrusted and never an instruction.
- Unattended runs offer only tools that never prompt; outward-facing and write-capable tools are absent, not
  merely gated. `calendarBlock` always asks. A prompt nobody answers is a decline (existing 45 s rule).
- Cloud-model buddies: an automation owned by a buddy on a cloud model never gets `.reminders`,
  `.clipboard`, `.screenText` or `.folderFiles` source data unless the draft card showed "this leaves your
  Mac" (the existing `deployment.sendsDataOffThisMachine` flag decides).
- Migration never writes or deletes an old store. Run history holds numbers, status and a capped result
  text, retained 30 days, file mode 0600.
- Island: black unless the tint switch is on; no other code path tints it. Reduce Motion disables every
  celebration and the backdrop drift; `allowsPlayfulMotion` is the only gate.
