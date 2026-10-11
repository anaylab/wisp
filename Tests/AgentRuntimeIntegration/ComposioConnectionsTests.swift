//
//  ComposioConnectionsTests.swift
//  AgentRuntimeIntegration
//
//  The pure parts of the Composio app list: finding the sign-in link in a reply
//  whose field name has varied, and turning a typed name into a toolkit slug.
//

import Foundation

@MainActor func composioConnectionsSuite() {
    section("Composio connections: sign-in link and custom apps")

    let nested: [String: Any] = ["gmail": ["toolkit": "gmail", "status": "initiated", "redirect_url": "https://connect.composio.dev/link/abc"]]
    check("finds redirect_url", ComposioConnectionsStore.firstWebURL(in: nested)?.absoluteString == "https://connect.composio.dev/link/abc")

    let camel: [String: Any] = ["data": ["links": [["redirectUrl": "https://example.com/x"]]]]
    check("finds redirectUrl in nested arrays", ComposioConnectionsStore.firstWebURL(in: camel)?.absoluteString == "https://example.com/x")

    check("no link → nil", ComposioConnectionsStore.firstWebURL(in: ["status": "active"] as [String: Any]) == nil)
    check("ignores non-http strings", ComposioConnectionsStore.firstWebURL(in: ["url": "file:///etc/passwd"] as [String: Any]) == nil)

    check("typed name becomes a slug", ComposioApp.custom(named: "Google Maps")?.slug == "googlemaps")
    check("too short is refused", ComposioApp.custom(named: "x") == nil)
    check("curated slugs are unique", Set(ComposioApp.curated.map(\.slug)).count == ComposioApp.curated.count)
}
