//
//  GlanceCard.swift
//  leanring-buddy
//
//  A small, read-only visual card the assistant can show in the notch to
//  *show* an answer instead of only speaking it — a weather readout, a short
//  list, a few key/value facts, a row of stats.
//
//  The mechanism is the one this codebase already trusts: a fixed text tag
//  parsed out of the model reply, exactly like [POINT:...], [BOX:...] and
//  [TOOL:...]. Native structured output is not on the table — the resident
//  local vision model cannot produce it reliably (see
//  StructuredTextToolProtocol.swift for the measurements) — but it does emit a
//  demonstrated tag shape consistently. So the model writes one tag,
//
//      [CARD:{"blocks":[ ... ]}]
//
//  at the very end of its reply, and this file turns that back into a typed
//  card while stripping the tag so it is never spoken aloud.
//
//  Small models fall apart on open-ended UI schemas, so the schema here is
//  deliberately narrow: at most three blocks, a fixed block vocabulary
//  (header / list / keyValue / stats), semantic tone words rather than colors,
//  and a fixed icon allowlist. Anything off-schema is dropped silently rather
//  than rendered wrong — the same forgiving posture as ScreenAnnotationParser.
//

import Foundation

// MARK: - Card model

/// Semantic tone the model may attach to a row, pair or stat. The renderer —
/// not the model — maps these to concrete `DS.Colors`, so the model never
/// sends a hex value it would get wrong.
enum GlanceTone: String, Equatable {
    case good
    case bad
    case neutral
}

/// One row of a `.list` block: a short line of text, an optional leading icon,
/// and a tone.
struct GlanceListRow: Equatable {
    let text: String
    let iconName: String?
    let tone: GlanceTone
}

/// One entry of a `.keyValue` block, e.g. "Humidity" → "60%".
struct GlanceKeyValuePair: Equatable {
    let key: String
    let value: String
    let tone: GlanceTone
}

/// One entry of a `.stats` block: a large value with a small caption beneath,
/// e.g. value "72°" label "Feels like".
struct GlanceStat: Equatable {
    let label: String
    let value: String
    let tone: GlanceTone
}

/// A single block within a card. The vocabulary is fixed for v1 — no charts,
/// no free-form HTML — because a small model produces a constrained shape far
/// more reliably than an open one.
enum GlanceBlock: Equatable {
    /// A title line, optionally with a leading icon and a trailing accessory
    /// (a temperature, a count, a status word).
    case header(title: String, iconName: String?, trailingText: String?)
    /// A short vertical list of lines.
    case list(rows: [GlanceListRow])
    /// Key/value fact pairs.
    case keyValue(pairs: [GlanceKeyValuePair])
    /// A row of prominent stats.
    case stats(items: [GlanceStat])
}

/// A read-only visual card rendered in the notch. Holds an ordered list of
/// blocks; `id` distinguishes one shown card from the next so the UI can
/// animate a replacement.
struct GlanceCard: Identifiable, Equatable {
    let id: UUID
    let blocks: [GlanceBlock]

    init(id: UUID = UUID(), blocks: [GlanceBlock]) {
        self.id = id
        self.blocks = blocks
    }

    /// The SF Symbol names the model is allowed to reference. Keeping this to a
    /// small, curated set means the model cannot invent a symbol name that
    /// renders as an empty box, and the renderer always has something sensible
    /// to draw.
    static let allowedIconNames: Set<String> = [
        "sun.max",
        "cloud",
        "cloud.rain",
        "cloud.snow",
        "cloud.bolt",
        "wind",
        "thermometer",
        "checkmark.circle",
        "xmark.circle",
        "exclamationmark.triangle",
        "info.circle",
        "star",
        "clock",
        "calendar",
        "bell",
        "envelope",
        "doc",
        "folder",
        "magnifyingglass",
        "list.bullet",
        "chart.bar",
        "arrow.up",
        "arrow.down",
        "location",
        "person"
    ]

    /// Substituted for any icon name the model asks for that is not in the
    /// allowlist, so an unknown symbol becomes a neutral glyph rather than a
    /// blank.
    static let defaultIconName = "info.circle"
}

// MARK: - App-matched card intents

/// What the model asked for when it requests a weather card. It supplies only
/// the place — never the numbers — so a small model's job stays trivial and Wisp
/// fetches the live conditions through a data provider (Phase 3B).
struct WeatherCardRequest: Equatable {
    let locationName: String
}

/// What the model asked for when it requests a places-nearby card. It supplies
/// only what the user is looking for — "coffee", "ramen", "pharmacy" — never a
/// location or any results. Wisp resolves the user's current location on-device
/// and searches Apple Maps itself (`PlacesDataProvider`), so the small model's
/// job stays trivial and nothing it invents can become a wrong result.
struct PlacesCardRequest: Equatable {
    let query: String
}

/// What the model asked for when it requests a reminders card: optionally one
/// list by name, and which slice to show. It never supplies reminders itself —
/// Wisp reads them on-device through EventKit (`RemindersDataProvider`).
///
/// `nonisolated` because the reminders provider actor reads it off the main
/// actor, and the fast-path/parse code builds it from plain values.
nonisolated struct RemindersCardRequest: Equatable {
    /// The Reminders list to show, matched case-insensitively, or nil for every
    /// list.
    let listName: String?
    let filter: RemindersFilter
}

/// What the model (or the "set a timer for…" fast path) asked for when it
/// requests a timer card: how long, and an optional short label ("tea"). The
/// countdown itself is owned by `WispTimerStore`, not by the card, so it keeps
/// running after the card is replaced.
nonisolated struct TimerCardRequest: Equatable {
    /// Whole seconds, already validated into `1...maximumDurationSeconds`.
    let durationSeconds: Int
    let label: String?

    /// The longest timer Wisp will run. Past a day a "timer" is really a
    /// reminder, and an absurd value is more likely a model slip than intent.
    static let maximumDurationSeconds = 24 * 60 * 60
}

/// What the model asked for when it requests a card from a user-configured
/// source (`~/.wisp/sources.json`). It names which source; Wisp fetches that
/// endpoint and maps the response into generic blocks. The model never sees the
/// URL or the response — just the source's name.
struct SourceCardRequest: Equatable {
    let sourceName: String
}

/// The parsed *intent* of a `[CARD:…]` tag: which kind of card the model asked
/// for, plus whatever the model supplied for it.
///
/// Data-sourced kinds (`.weather`) carry only an intent — the renderer resolves
/// the live data separately. Model-supplied kinds (`.generic`) already hold
/// everything they need to draw. Future app-matched kinds (`calendar`, `music`,
/// `mail`) are added here as new cases.
enum GlanceCardRequest: Equatable {
    /// Show a native-styled weather card for a place; data fetched by Wisp.
    case weather(WeatherCardRequest)
    /// Show the user's upcoming calendar events; read on-device via EventKit.
    case calendar
    /// Show what is currently playing in Music or Spotify; read on this machine.
    case nowPlaying
    /// Show places near the user matching a query; located on-device and
    /// searched against Apple Maps by Wisp.
    case places(PlacesCardRequest)
    /// Show a card from a user-configured source (an HTTPS endpoint), rendered
    /// as generic blocks from the fetched JSON.
    case source(SourceCardRequest)
    /// Show the user's incomplete reminders; read on-device via EventKit.
    case reminders(RemindersCardRequest)
    /// Start a countdown timer and show it live; run on-device by Wisp.
    case timer(TimerCardRequest)
    /// The constrained, model-supplied block card — the fallback for anything
    /// without a dedicated app template.
    case generic(GlanceCard)
}

/// A card that is ready to render — the notch holds one of these. It is what a
/// `GlanceCardRequest` becomes after resolution: a `.generic` card is already
/// complete when parsed, while a `.weather` card carries a `WeatherCardState`
/// that starts as loading and becomes loaded (or failed) when its data provider
/// returns, so the card can appear immediately and fill in.
enum ResolvedGlanceCard: Equatable {
    case generic(GlanceCard)
    case weather(WeatherCardState)
    case calendar(CalendarCardState)
    case nowPlaying(NowPlayingCardState)
    /// A places-nearby card. Its `query` is carried through the loading/failed
    /// states so the card can label itself while it resolves.
    case places(PlacesCardState)
    /// A user-configured source card. Its `sourceName` is carried through the
    /// loading/failed states so the card can label itself while it resolves.
    case source(SourceCardState)
    /// A reminders card, read on-device through EventKit.
    case reminders(RemindersCardState)
    /// A live countdown. The state only names the timer; the countdown itself
    /// lives in `WispTimerStore` so it outlives this card.
    case timer(TimerCardState)
    /// The result of adding an event, with Undo. The state only names the
    /// event; its details and undo progress live in `CreatedCalendarEventStore`.
    case calendarEventAdded(CalendarEventAddedCardState)
    /// The result of adding a reminder, with Undo; details in `CreatedReminderStore`.
    case reminderAdded(ReminderAddedCardState)
}

// MARK: - Tag parsing

/// Turns a `[CARD:{...json...}]` tag in a model reply into a `GlanceCard`, and
/// strips the tag from the text that gets spoken. Modeled on
/// `ScreenAnnotationParser` and `StructuredTextToolProtocol`.
enum GlanceCardParser {

    /// Instructions appended to the system prompt teaching the single card
    /// tag. Kept as terse as the annotation instructions on purpose: every
    /// token here shares the context window with a screenshot, and long
    /// preambles are where small models start improvising syntax.
    ///
    /// One worked example is included because small models copy a demonstrated
    /// shape far more reliably than they follow a description of it — with the
    /// same liability the tool prompt has, that the example gets parroted
    /// verbatim, hence the explicit warning not to copy its values.
    static let promptInstructions = """


    showing a card:
    when seeing an answer beats hearing it, you can show one card in the notch. write one tag at the very end of your reply, after the spoken text, and nothing after it. the body is valid json.

    for weather, do NOT write the numbers — just name the place, and wisp fills in live conditions itself:
    [CARD:{"kind":"weather","location":"San Francisco"}]

    for the user's upcoming events, just ask for the calendar — wisp reads it:
    [CARD:{"kind":"calendar"}]

    for what's playing right now (Music or Spotify), just ask — wisp reads it:
    [CARD:{"kind":"music"}]

    for ANYTHING the user wants to find near them — restaurants, coffee, food, a bar, a pharmacy, a store, a gas station, or anywhere they say "near me", "nearby", "closest", or "around here" — you do NOT know the real places and must NEVER name one or invent an address. ALWAYS end your reply with this tag and let wisp find them; the query is just the type of place:
    [CARD:{"kind":"places","query":"coffee"}]
    keep your spoken words to a short lead-in like "here are some nearby", then this tag. (a places answer still appends [POINT:none].)

    for the user's reminders — list is optional, filter is today, overdue or all — wisp reads them:
    [CARD:{"kind":"reminders","filter":"today"}]

    to start a timer, give its length in seconds and an optional label — wisp runs it and alerts when done:
    [CARD:{"kind":"timer","seconds":300,"label":"tea"}]

    for anything else, use blocks — at most three, each one of:
    - {"type":"header","title":"...","icon":"...","trailing":"..."} — a title line; icon and trailing are optional.
    - {"type":"list","rows":[{"text":"...","icon":"...","tone":"good|bad|neutral"}]} — a short list.
    - {"type":"keyValue","pairs":[{"key":"...","value":"...","tone":"..."}]} — fact pairs.
    - {"type":"stats","items":[{"label":"...","value":"...","tone":"..."}]} — prominent numbers.

    tone is one of good, bad, neutral — a meaning, never a color. keep every string to a few words. only add a card when it helps; otherwise reply with no tag.

    these are only illustrations of the format — never copy their values:
    here's the weather. [CARD:{"kind":"weather","location":"Chicago"}]
    here are the totals. [CARD:{"blocks":[{"type":"keyValue","pairs":[{"key":"Passing","value":"128","tone":"good"},{"key":"Failing","value":"3","tone":"bad"}]}]}]
    """

    /// Extracts the card tag and strips it from the spoken text.
    ///
    /// Returns the reply with the tag removed alongside the parsed card *request*
    /// — the intent the model expressed — or a nil request when there is no tag,
    /// the JSON cannot be read, or the requested card has nothing to show. A
    /// malformed tag is still stripped, so nothing tag-shaped is ever spoken,
    /// mirroring how the tool parser removes malformed tags too.
    static func parse(_ responseText: String) -> (spokenText: String, request: GlanceCardRequest?) {
        // Locate the tag opener. Case-insensitive, since the model occasionally
        // lowercases the keyword despite the prompt.
        guard let tagOpenerRange = responseText.range(of: "[CARD:", options: .caseInsensitive) else {
            return (responseText.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        // The JSON body starts at the first "{" after the opener.
        guard let jsonOpenBraceIndex = responseText[tagOpenerRange.upperBound...].firstIndex(of: "{"),
              let jsonCloseBraceIndex = matchingCloseBraceIndex(
                fromOpenBrace: jsonOpenBraceIndex,
                in: responseText
              ) else {
            // No decodable body at all — leave the text as-is rather than
            // hacking away at something we don't understand.
            return (responseText.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        // The tag closes at the next "]" after the JSON body, allowing
        // whitespace between. If the model never wrote the closing bracket, the
        // tag still ends at the JSON body so the fragment is not left to be
        // spoken.
        var tagRemovalEndIndex = responseText.index(after: jsonCloseBraceIndex)
        var scanIndex = tagRemovalEndIndex
        while scanIndex < responseText.endIndex, responseText[scanIndex].isWhitespace {
            scanIndex = responseText.index(after: scanIndex)
        }
        if scanIndex < responseText.endIndex, responseText[scanIndex] == "]" {
            tagRemovalEndIndex = responseText.index(after: scanIndex)
        }

        // Strip the whole tag from the spoken text.
        var spokenText = responseText
        spokenText.removeSubrange(tagOpenerRange.lowerBound..<tagRemovalEndIndex)
        let strippedSpokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Decode the body. Malformed JSON drops the card without crashing, but
        // the tag has already been stripped above.
        let jsonBodyText = String(responseText[jsonOpenBraceIndex...jsonCloseBraceIndex])
        guard let jsonData = jsonBodyText.data(using: .utf8),
              let decodedCard = try? JSONDecoder().decode(DecodedCard.self, from: jsonData) else {
            return (strippedSpokenText, nil)
        }

        return (strippedSpokenText, request(from: decodedCard))
    }

    /// Turns a decoded body into a typed request by reading its `kind`.
    ///
    /// `weather` needs a place to fetch for, so a weather card with no location
    /// is dropped. Everything else falls back to the generic block card — an
    /// absent kind, an explicit `generic`, or even an unknown kind that still
    /// carried usable blocks — and a card with no usable blocks is dropped.
    private static func request(from decodedCard: DecodedCard) -> GlanceCardRequest? {
        let kind = decodedCard.kind?.trimmingCharacters(in: .whitespaces).lowercased()

        if kind == "weather" {
            guard let locationName = trimmedNonEmpty(decodedCard.location) else {
                return nil
            }
            return .weather(WeatherCardRequest(locationName: locationName))
        }

        if kind == "calendar" {
            return .calendar
        }

        // The model may name the now-playing kind a few natural ways.
        if kind == "music" || kind == "nowplaying" || kind == "now_playing" {
            return .nowPlaying
        }

        if kind == "places" {
            guard let query = trimmedNonEmpty(decodedCard.query) else {
                return nil
            }
            return .places(PlacesCardRequest(query: query))
        }

        if kind == "source" {
            guard let sourceName = trimmedNonEmpty(decodedCard.name) else {
                return nil
            }
            return .source(SourceCardRequest(sourceName: sourceName))
        }

        // A reminders card needs nothing else: no list means every list, and
        // an absent or unknown filter means all incomplete reminders.
        if kind == "reminders" || kind == "reminder" {
            return .reminders(RemindersCardRequest(
                listName: trimmedNonEmpty(decodedCard.list),
                filter: RemindersFilter(lenientRawValue: decodedCard.filter)
            ))
        }

        if kind == "timer" || kind == "countdown" {
            guard let durationSeconds = validatedTimerDurationSeconds(from: decodedCard) else {
                return nil
            }
            return .timer(TimerCardRequest(
                durationSeconds: durationSeconds,
                label: validatedTimerLabel(decodedCard.label)
            ))
        }

        let validatedBlocks = validatedBlocks(from: decodedCard.blocks ?? [])
        guard !validatedBlocks.isEmpty else {
            return nil
        }
        return .generic(GlanceCard(blocks: validatedBlocks))
    }

    // MARK: Validation

    /// Reads a timer's length from the card body. The prompt asks for
    /// `seconds`, but a small model sometimes writes `minutes` instead, so that
    /// is accepted too (seconds wins if both appear). A missing, zero, negative
    /// or over-a-day length drops the card rather than starting a nonsense
    /// timer.
    private static func validatedTimerDurationSeconds(from decodedCard: DecodedCard) -> Int? {
        let requestedSeconds: Double
        if let seconds = decodedCard.seconds?.value {
            requestedSeconds = seconds
        } else if let minutes = decodedCard.minutes?.value {
            requestedSeconds = minutes * 60
        } else {
            return nil
        }

        guard requestedSeconds.isFinite else { return nil }
        let roundedSeconds = Int(requestedSeconds.rounded())
        guard roundedSeconds >= 1, roundedSeconds <= TimerCardRequest.maximumDurationSeconds else {
            return nil
        }
        return roundedSeconds
    }

    /// The longest timer label kept. It sits on one line in a narrow card.
    private static let maximumTimerLabelLength = 40

    /// Trims a timer label and caps its length; blank becomes no label.
    private static func validatedTimerLabel(_ rawLabel: String?) -> String? {
        guard let label = trimmedNonEmpty(rawLabel) else { return nil }
        return String(label.prefix(maximumTimerLabelLength))
    }

    /// The maximum number of blocks a card may show. Past this the card stops
    /// clarifying and starts crowding the notch, so extra blocks are dropped —
    /// the same `prefix` posture ScreenAnnotationParser takes.
    private static let maximumBlocksPerCard = 3

    /// Converts decoded blocks into model blocks, dropping any that are
    /// off-schema or empty, then caps the count.
    private static func validatedBlocks(from decodedBlocks: [DecodedBlock]) -> [GlanceBlock] {
        let blocks = decodedBlocks.compactMap(validatedBlock(from:))
        return Array(blocks.prefix(maximumBlocksPerCard))
    }

    /// Validates one decoded block. Returns nil for an unknown block type or a
    /// block with no usable content, so it is dropped silently.
    private static func validatedBlock(from decodedBlock: DecodedBlock) -> GlanceBlock? {
        switch decodedBlock.type.lowercased() {
        case "header":
            let title = trimmedNonEmpty(decodedBlock.title)
            guard let title else { return nil }
            return .header(
                title: title,
                iconName: normalizedIconName(decodedBlock.icon),
                trailingText: trimmedNonEmpty(decodedBlock.trailing)
            )

        case "list":
            let rows = (decodedBlock.rows ?? []).compactMap { decodedRow -> GlanceListRow? in
                guard let text = trimmedNonEmpty(decodedRow.text) else { return nil }
                return GlanceListRow(
                    text: text,
                    iconName: normalizedIconName(decodedRow.icon),
                    tone: tone(from: decodedRow.tone)
                )
            }
            guard !rows.isEmpty else { return nil }
            return .list(rows: rows)

        case "keyvalue":
            let pairs = (decodedBlock.pairs ?? []).compactMap { decodedPair -> GlanceKeyValuePair? in
                guard let key = trimmedNonEmpty(decodedPair.key),
                      let value = trimmedNonEmpty(decodedPair.value) else { return nil }
                return GlanceKeyValuePair(
                    key: key,
                    value: value,
                    tone: tone(from: decodedPair.tone)
                )
            }
            guard !pairs.isEmpty else { return nil }
            return .keyValue(pairs: pairs)

        case "stats":
            let items = (decodedBlock.items ?? []).compactMap { decodedStat -> GlanceStat? in
                guard let value = trimmedNonEmpty(decodedStat.value) else { return nil }
                return GlanceStat(
                    label: trimmedNonEmpty(decodedStat.label) ?? "",
                    value: value,
                    tone: tone(from: decodedStat.tone)
                )
            }
            guard !items.isEmpty else { return nil }
            return .stats(items: items)

        default:
            return nil
        }
    }

    /// Maps a raw icon name to an allowlisted one: absent stays absent, an
    /// allowlisted name is kept, and anything unknown falls back to the default
    /// glyph rather than a blank symbol.
    private static func normalizedIconName(_ rawIconName: String?) -> String? {
        guard let iconName = trimmedNonEmpty(rawIconName) else { return nil }
        return GlanceCard.allowedIconNames.contains(iconName) ? iconName : GlanceCard.defaultIconName
    }

    /// Maps a raw tone string to the enum, defaulting to `.neutral` for a
    /// missing or unrecognised value.
    private static func tone(from rawTone: String?) -> GlanceTone {
        guard let rawTone else { return .neutral }
        return GlanceTone(rawValue: rawTone.trimmingCharacters(in: .whitespaces).lowercased()) ?? .neutral
    }

    /// Trims a string and returns nil when nothing is left, so blank fields are
    /// treated the same as absent ones.
    private static func trimmedNonEmpty(_ rawText: String?) -> String? {
        guard let rawText else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Walks forward from an opening brace to its matching close, respecting
    /// braces that appear inside JSON string literals (and their escapes) so a
    /// "}" inside a value does not end the scan early. Returns nil if the
    /// braces never balance.
    private static func matchingCloseBraceIndex(
        fromOpenBrace openBraceIndex: String.Index,
        in text: String
    ) -> String.Index? {
        var braceDepth = 0
        var isInsideStringLiteral = false
        var previousCharacterWasBackslash = false
        var currentIndex = openBraceIndex

        while currentIndex < text.endIndex {
            let character = text[currentIndex]

            if isInsideStringLiteral {
                if previousCharacterWasBackslash {
                    previousCharacterWasBackslash = false
                } else if character == "\\" {
                    previousCharacterWasBackslash = true
                } else if character == "\"" {
                    isInsideStringLiteral = false
                }
            } else {
                switch character {
                case "\"":
                    isInsideStringLiteral = true
                case "{":
                    braceDepth += 1
                case "}":
                    braceDepth -= 1
                    if braceDepth == 0 {
                        return currentIndex
                    }
                default:
                    break
                }
            }

            currentIndex = text.index(after: currentIndex)
        }

        return nil
    }
}

// MARK: - JSON decoding shapes

/// The wire shape of a card's JSON body. Kept separate from the model types so
/// decoding stays lenient — every field is optional and validated afterward,
/// rather than a strict schema that would reject an otherwise usable card over
/// one missing key.
private struct DecodedCard: Decodable {
    /// Which app-matched card the model wants. Absent means the generic block
    /// card.
    let kind: String?
    /// The place a `weather` card is for.
    let location: String?
    /// What a `places` card is looking for (e.g. "coffee", "ramen").
    let query: String?
    /// The source a `source` card names (an entry in `~/.wisp/sources.json`).
    let name: String?
    /// The Reminders list a `reminders` card is for (optional).
    let list: String?
    /// Which reminders a `reminders` card shows: today, overdue or all.
    let filter: String?
    /// A `timer` card's length. Lenient so `300` and `"300"` both read.
    let seconds: LenientDecodedNumber?
    /// A fallback timer length some models write instead of `seconds`.
    let minutes: LenientDecodedNumber?
    /// A `timer` card's optional short label ("tea").
    let label: String?
    let blocks: [DecodedBlock]?
}

/// A number that decodes from either a JSON number or a numeric string, and
/// never throws: anything else becomes a nil `value`. A synthesized `Double?`
/// would fail the *whole* card decode on `"seconds":"300"`, which is exactly the
/// kind of near-miss a small model produces.
private struct LenientDecodedNumber: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let numberValue = try? container.decode(Double.self) {
            value = numberValue
        } else if let textValue = try? container.decode(String.self) {
            value = Double(textValue.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }
}

/// One decoded block. All block kinds share this one flat shape: the `type`
/// discriminator says which fields matter, and the rest are optional.
private struct DecodedBlock: Decodable {
    let type: String
    let title: String?
    let icon: String?
    let trailing: String?
    let rows: [DecodedListRow]?
    let pairs: [DecodedKeyValuePair]?
    let items: [DecodedStat]?
}

private struct DecodedListRow: Decodable {
    let text: String?
    let icon: String?
    let tone: String?
}

private struct DecodedKeyValuePair: Decodable {
    let key: String?
    let value: String?
    let tone: String?
}

private struct DecodedStat: Decodable {
    let label: String?
    let value: String?
    let tone: String?
}
