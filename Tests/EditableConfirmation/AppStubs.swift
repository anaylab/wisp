//
//  The few app names the confirmation-card code refers to, without compiling
//  the files that define them (each of those reaches far into the app). Kept
//  identical to the real values; if one changes there, change it here.
//

enum ShortcutsToolRouting { static let runShortcutToolName = "run_shortcut" }
enum BuddyDelegationToolNames { static let askBuddy = "ask_buddy" }
enum MessagingToolNames { static let sendIMessage = "send_imessage" }

// `GlanceCard.swift` (the card model the confirmation card is made of) also
// names the resolved states of the data-backed card kinds. Nothing here
// renders those, so empty stand-ins are enough to compile it.
struct WeatherCardState: Equatable {}
struct CalendarCardState: Equatable {}
struct NowPlayingCardState: Equatable {}
struct PlacesCardState: Equatable {}
struct SourceCardState: Equatable {}
struct RemindersCardState: Equatable {}
struct TimerCardState: Equatable {}
enum RemindersFilter: String, Equatable {
    case today
    init(lenientRawValue: String?) { self = .today }
}
