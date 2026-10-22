//
//  BrowserPageSnapshotDecoding.swift
//  leanring-buddy
//
//  The one place a page snapshot's JSON becomes a `BrowserPageSnapshot`.
//
//  Two scripts produce that JSON — the one `AppleScriptBrowserController`
//  injects and the Chrome extension's content/dom-agent.js — and the planners,
//  the plan validator and every browser prompt are written against what comes
//  out. Decoding both through here is what keeps the two controllers' page
//  text identical, down to the "(a dialog is open: …)" line.
//
//  Lenient on purpose, like the decoding it replaced: an element missing its
//  id, role or label is dropped, an empty state reads as none, and a field of
//  the wrong type is ignored rather than failing the whole page.
//
//  Pure (Foundation only) so `Tests/ChromeExtDOMController` can compile it.
//

import Foundation

enum BrowserPageSnapshotDecoding {
    /// A snapshot from its JSON object (`JSONSerialization` output).
    static func snapshot(fromJSONObject root: [String: Any]) -> BrowserPageSnapshot {
        let elements = (root["elements"] as? [[String: Any]] ?? []).compactMap(element(fromJSONObject:))

        var text = root["text"] as? String ?? ""
        // Where the viewport sits in the page, so the agent knows whether
        // scrolling could reveal more — and when it has reached the bottom.
        if let scrollDescription = root["scroll"] as? String, !scrollDescription.isEmpty {
            text = "(\(scrollDescription))\n" + text
        }
        // A modal is the one thing on the page that must be dealt with before
        // anything behind it can be clicked, so it is named outright.
        if let dialogLabel = root["dialog"] as? String, !dialogLabel.isEmpty {
            text = "(a dialog is open: \(dialogLabel) — its elements are listed first)\n" + text
        }

        return BrowserPageSnapshot(
            url: root["url"] as? String ?? "",
            title: root["title"] as? String ?? "",
            headings: root["headings"] as? [String] ?? [],
            elements: elements,
            text: text
        )
    }

    /// A snapshot from JSON text, or nil when it isn't a JSON object.
    static func snapshot(fromJSONData data: Data) -> BrowserPageSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return snapshot(fromJSONObject: root)
    }

    /// One listed element, or nil when it lacks what an action needs.
    static func element(fromJSONObject elementObject: [String: Any]) -> BrowserElement? {
        guard let id = elementObject["id"] as? String,
              let role = elementObject["role"] as? String,
              let label = elementObject["label"] as? String else { return nil }
        let state = elementObject["state"] as? String
        return BrowserElement(
            id: id,
            role: role,
            label: label,
            href: elementObject["href"] as? String,
            value: elementObject["value"] as? String,
            state: (state?.isEmpty ?? true) ? nil : state,
            isSensitiveInput: (elementObject["sensitive"] as? Bool) ?? false
        )
    }

    /// The `elements` list of a reply (`findElements`), decoded the same way.
    static func elements(fromJSONData data: Data) -> [BrowserElement] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (root["elements"] as? [[String: Any]] ?? []).compactMap(element(fromJSONObject:))
    }
}
