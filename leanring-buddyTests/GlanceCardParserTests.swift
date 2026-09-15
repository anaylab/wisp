//
//  GlanceCardParserTests.swift
//  leanring-buddyTests
//
//  Proves the [CARD:...] tag is turned into a typed card *request* and stripped
//  from the spoken text — a weather intent for a data-sourced card, or a
//  validated generic block card — and that a small model's off-schema or
//  malformed output is tolerated: dropped, never crashed on.
//

import XCTest
@testable import Wisp

final class GlanceCardParserTests: XCTestCase {

    /// Pulls the blocks out of a `.generic` request, or nil for any other case,
    /// so the generic-card assertions stay readable.
    private func genericBlocks(_ request: GlanceCardRequest?) -> [GlanceBlock]? {
        guard case let .generic(card)? = request else { return nil }
        return card.blocks
    }

    // MARK: - Weather intent (data-sourced card)

    func testWeatherIntentParsesLocationAndStripsTag() {
        let reply = #"Here's the forecast. [CARD:{"kind":"weather","location":"San Francisco"}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(result.spokenText, "Here's the forecast.")
        XCTAssertEqual(result.request, .weather(WeatherCardRequest(locationName: "San Francisco")))
    }

    func testWeatherIntentWithoutLocationIsDropped() {
        // A weather card needs a place to fetch for; without one there is
        // nothing Wisp can show, so the request is dropped.
        let reply = #"[CARD:{"kind":"weather"}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertNil(result.request)
        XCTAssertEqual(result.spokenText, "")
    }

    // MARK: - A well-formed generic card

    func testGenericCardParsesBlocksAndStripsTagFromSpokenText() {
        let reply = """
        Here are the totals. [CARD:{"blocks":[\
        {"type":"header","title":"Test run","icon":"checkmark.circle","trailing":"OK"},\
        {"type":"keyValue","pairs":[\
        {"key":"Passing","value":"128","tone":"good"},\
        {"key":"Failing","value":"3","tone":"bad"}]}]}]
        """

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(result.spokenText, "Here are the totals.")

        XCTAssertEqual(
            genericBlocks(result.request),
            [
                .header(title: "Test run", iconName: "checkmark.circle", trailingText: "OK"),
                .keyValue(pairs: [
                    GlanceKeyValuePair(key: "Passing", value: "128", tone: .good),
                    GlanceKeyValuePair(key: "Failing", value: "3", tone: .bad)
                ])
            ]
        )
    }

    // MARK: - Schema clamping (generic)

    func testTooManyBlocksAreClampedToThree() {
        let reply = """
        [CARD:{"blocks":[\
        {"type":"header","title":"One"},\
        {"type":"header","title":"Two"},\
        {"type":"header","title":"Three"},\
        {"type":"header","title":"Four"},\
        {"type":"header","title":"Five"}]}]
        """

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(
            genericBlocks(result.request),
            [
                .header(title: "One", iconName: nil, trailingText: nil),
                .header(title: "Two", iconName: nil, trailingText: nil),
                .header(title: "Three", iconName: nil, trailingText: nil)
            ]
        )
    }

    func testUnknownBlockTypeIsDroppedButValidBlocksSurvive() {
        let reply = """
        [CARD:{"blocks":[\
        {"type":"header","title":"Kept"},\
        {"type":"chart","series":[1,2,3]},\
        {"type":"list","rows":[{"text":"Also kept"}]}]}]
        """

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(
            genericBlocks(result.request),
            [
                .header(title: "Kept", iconName: nil, trailingText: nil),
                .list(rows: [GlanceListRow(text: "Also kept", iconName: nil, tone: .neutral)])
            ]
        )
    }

    func testUnknownIconFallsBackToDefaultGlyph() {
        let reply = #"[CARD:{"blocks":[{"type":"header","title":"Weather","icon":"made.up.symbol"}]}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(
            genericBlocks(result.request)?.first,
            .header(title: "Weather", iconName: GlanceCard.defaultIconName, trailingText: nil)
        )
    }

    func testUnknownToneDefaultsToNeutral() {
        let reply = #"[CARD:{"blocks":[{"type":"list","rows":[{"text":"Item","tone":"spicy"}]}]}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(
            genericBlocks(result.request)?.first,
            .list(rows: [GlanceListRow(text: "Item", iconName: nil, tone: .neutral)])
        )
    }

    func testBlockWithNoUsableContentIsDropped() {
        // A header with a blank title and a list with only empty rows both have
        // nothing to render, so the whole card collapses to nil.
        let reply = #"[CARD:{"blocks":[{"type":"header","title":"   "},{"type":"list","rows":[{"text":""}]}]}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertNil(result.request)
    }

    // MARK: - Unknown kinds

    func testUnknownKindWithoutBlocksIsDropped() {
        let reply = #"[CARD:{"kind":"stocks","symbol":"AAPL"}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertNil(result.request)
    }

    func testUnknownKindWithBlocksFallsBackToGeneric() {
        // A kind we don't template for, but with usable blocks, still renders as
        // the generic card rather than being thrown away.
        let reply = #"[CARD:{"kind":"stocks","blocks":[{"type":"header","title":"AAPL 224.10"}]}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(
            genericBlocks(result.request),
            [.header(title: "AAPL 224.10", iconName: nil, trailingText: nil)]
        )
    }

    // MARK: - Malformed and absent tags

    func testMalformedJSONDropsCardButPreservesSpokenText() {
        let reply = "Here you go. [CARD:{not valid json at all}]"

        let result = GlanceCardParser.parse(reply)

        XCTAssertNil(result.request)
        // The prose is preserved and the malformed tag is not left to be spoken.
        XCTAssertEqual(result.spokenText, "Here you go.")
    }

    func testReplyWithoutCardTagIsUnchangedAndRequestIsNil() {
        let reply = "Just a normal spoken answer with no card."

        let result = GlanceCardParser.parse(reply)

        XCTAssertNil(result.request)
        XCTAssertEqual(result.spokenText, reply)
    }

    func testCardTagIsStrippedEvenWhenItIsTheEntireReply() {
        let reply = #"[CARD:{"blocks":[{"type":"header","title":"Only a card"}]}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(result.spokenText, "")
        XCTAssertEqual(
            genericBlocks(result.request),
            [.header(title: "Only a card", iconName: nil, trailingText: nil)]
        )
    }
}
