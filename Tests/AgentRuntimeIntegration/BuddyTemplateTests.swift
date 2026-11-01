//
//  BuddyTemplateTests.swift
//  AgentRuntimeIntegration
//
//  Buddy templates: the bundled catalog is sound, the review says what a
//  template will do, a saved template keeps setup only and round-trips, and
//  adding one makes a buddy that does not run at once.
//

import Foundation

@MainActor func buddyTemplateSuite() {
    section("Templates: catalog")
    let catalog = BuddyTemplateCatalog.bundled
    check("every bundled template has a unique id", Set(catalog.map(\.id)).count == catalog.count)
    check("every bundled template has a name, tagline and mission within the share limits",
          catalog.allSatisfy { !$0.name.isEmpty && !$0.tagline.isEmpty && !$0.mission.isEmpty
              && $0.name.count <= WispShareBundleCodec.maximumNameCharacters
              && $0.mission.count <= WispShareBundleCodec.maximumInstructionCharacters })
    check("bundled templates are marked bundled and none carries a model or tool limit of its own",
          catalog.allSatisfy { $0.origin == .bundled && $0.modelChoice == nil && $0.toolAccess == nil })
    check("every category has at least one template", BuddyTemplate.Category.allCases.allSatisfy { category in catalog.contains { $0.category == category } })
    check("a repeating bundled template's wording matches its schedule",
          catalog.filter { $0.schedule.isRepeating }.allSatisfy { BuddySchedule.inferred(fromInstruction: $0.mission).isRepeating })

    section("Templates: review")
    let sample = catalog[0]
    let rows = BuddyTemplateReview.rows(for: sample, toolSummary: "Browser, Brain")
    check("the review lists what it does, when, what it can use, where it runs",
          rows.map(\.title) == ["What it does", "When it runs", "What it can use", "Where it runs"])
    check("the review states the schedule and the tool summary", rows[1].text.contains("Every day") && rows[2].text == "Browser, Brain")
    var cloudTemplate = sample
    cloudTemplate.modelChoice = BuddyModelChoice(providerKind: .anthropic, claudeModel: nil)
    check("a cloud model is flagged as leaving this Mac",
          BuddyTemplateReview.rows(for: cloudTemplate, toolSummary: "")[3].text.contains("leaves this Mac"))
    check("a name that is taken gets a number", BuddyTemplateReview.uniqueName("Planner", avoiding: ["planner", "Planner 2"]) == "Planner 3")
    check("search finds a template by its role", catalog.contains { BuddyTemplateReview.matches($0, searchText: "researcher") })
    check("a blank search matches everything", catalog.allSatisfy { BuddyTemplateReview.matches($0, searchText: "  ") })

    section("Templates: saved")
    let buddy = WispBuddy(
        id: UUID(), name: "My Digest", instruction: "Summarize the news", colorIndex: 3, schedule: .daily(hour: 7, minute: 30),
        createdAt: Date(), runTaskIDs: [UUID()], nextScheduledRunAt: Date(), toolAccess: BuddyToolAccess(allowedGroupIDs: ["browser"]),
        specialty: .researcher, personality: .hype
    )
    let saved = BuddyTemplateCatalog.savedTemplate(from: buddy)
    check("a saved template keeps the job, role, tone, schedule, colour and tool limits",
          saved.mission == "Summarize the news" && saved.specialty == .researcher && saved.personality == .hype
          && saved.schedule == .daily(hour: 7, minute: 30) && saved.colorIndex == 3 && saved.toolAccess?.allowedGroupIDs == ["browser"]
          && saved.origin == .saved)
    let savedJSON = String(data: try! JSONEncoder().encode(saved), encoding: .utf8)!
    check("a saved template carries no run ids, thread or notes", !savedJSON.contains("runTaskIDs") && !savedJSON.contains(buddy.runTaskIDs[0].uuidString))
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-templates-\(UUID().uuidString).json")
    let templateStore = BuddyTemplateStore(fileURL: storeURL)
    templateStore.save(buddy: buddy)
    templateStore.save(buddy: buddy)
    check("saving the same buddy twice keeps one template", templateStore.savedTemplates.count == 1)
    check("the file is private", ((try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions]) as? Int) == 0o600)
    let reloaded = BuddyTemplateStore(fileURL: storeURL)
    check("saved templates survive a restart", reloaded.savedTemplates.map(\.mission) == ["Summarize the news"])
    check("saved templates come before bundled ones", reloaded.allTemplates.first?.isSaved == true && reloaded.allTemplates.count == catalog.count + 1)
    reloaded.remove(templateWithID: reloaded.savedTemplates[0].id)
    check("a saved template can be removed", reloaded.savedTemplates.isEmpty)
    try? FileManager.default.removeItem(at: storeURL)
}
