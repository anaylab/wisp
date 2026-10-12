//
//  CuaToolRoutingTests.swift
//  AgentRuntimeIntegration
//
//  cua-driver's tools reaching the model: the per-turn router used to hand
//  "click the New Note button in Notes" to the browser tools, and a cloud model
//  was held to the local model's six-tool limit, so they never did.
//

import Foundation

@MainActor func cuaToolRoutingSuite() {
    section("cua-driver tool routing")

    func tool(_ name: String, _ description: String) -> BuddyToolDefinition {
        BuddyToolDefinition(name: name, description: description, inputSchema: .object(["type": .string("object")]), requiresConfirmation: true)
    }
    let browserTools = [
        tool("click_element", "Click an element on the web page."),
        tool("read_page", "Read the current web page."),
        tool("browser_task", "Do a task in the browser."),
        tool("open_url", "Open a link in the browser."),
    ]
    let cuaTools = [
        tool("cua-driver__click", "Click against a target pid."),
        tool("cua-driver__get_window_state", "Walk a running app's AX tree."),
        tool("cua-driver__type_text", "Insert text into the target pid."),
    ]

    let unboostedNames = AgentToolRouter.select(
        from: browserTools + cuaTools, for: "click the New Note button in Notes", limit: 2
    ).map(\.name)
    check("without the boost, 'click' fills the slots with browser tools (got \(unboostedNames))",
          !unboostedNames.contains("cua-driver__get_window_state"))

    let boostedNames = AgentToolRouter.select(
        from: browserTools + cuaTools, for: "click the New Note button in Notes", limit: 2,
        boostedToolNames: ["cua-driver__click", "cua-driver__get_window_state", "cua-driver__type_text"],
        scopeOverride: .general
    ).map(\.name)
    check("with the boost and no browser bonus, cua's tools take the slots (got \(boostedNames))",
          boostedNames.allSatisfy { $0.hasPrefix("cua-driver__") })

    // Through the registry itself, with a request that names cua — the case that
    // doesn't depend on which apps happen to be running on the test machine.
    let registry = AgentToolRegistry.makeEmptyForTesting()
    for definition in browserTools + cuaTools {
        registry.register(definition) { _ in "" }
    }
    let registryNames = registry.definitions(forRequest: "use cua to click the New Note button", maximumToolCount: 3).map(\.name)
    check("the registry boosts cua's tools when the request names cua (got \(registryNames))",
          registryNames.filter { $0.hasPrefix("cua-driver__") }.count == 3)

    check("a cloud model is shown more tools than the local one",
          AgentToolScope.maximumExposedToolsForCloudModels > AgentToolScope.maximumExposedTools)
}
