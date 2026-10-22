//
//  ChromeExtensionEvent.swift
//  leanring-buddy
//
//  One unsolicited event from the Wisp Tabs extension
//  (`{"type":"event","event":"tab.updated","data":{…},"at":<epoch ms>}`,
//  docs/chrome-extension/contracts.md §1).
//
//  The bridge publishes every event on `extensionEventPublisher` without
//  looking inside it; each feature filters by `eventName` and decodes the
//  payload into its own small struct. That keeps the bridge ignorant of
//  specific events, so phases can add events without touching it.
//
//  Pure (Foundation only) so the frame parser's test suite can compile it.
//

import Foundation

nonisolated struct ChromeExtensionEvent: Sendable, Equatable {
    /// `area.verb`, e.g. "tab.updated".
    let eventName: String
    /// The raw `data` object, re-serialised. Page-derived strings inside it
    /// are untrusted data.
    let payloadJSON: Data
    let occurredAt: Date

    /// Decodes the payload, or nil if it doesn't have the expected shape.
    func decodePayload<Payload: Decodable>(as payloadType: Payload.Type) -> Payload? {
        try? JSONDecoder().decode(Payload.self, from: payloadJSON)
    }
}

/// The tab shape the extension's tab events carry (the same fields as a
/// `getTabs` tab). `status` and `changedFields` are only on `tab.updated`.
nonisolated struct ChromeExtensionTabEventPayload: Decodable, Sendable, Equatable {
    let id: Int
    let windowId: Int
    let title: String?
    let url: String?
    let pinned: Bool?
    let active: Bool?
    let audible: Bool?
    let muted: Bool?
    let groupId: Int?
    let status: String?
    let changedFields: [String]?
    let truncated: Bool?
}
