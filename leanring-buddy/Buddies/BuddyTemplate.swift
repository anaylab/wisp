//
//  BuddyTemplate.swift
//  leanring-buddy
//
//  Buddy templates, after OpenBot's agent templates: a ready-made buddy you
//  read first and then add with one tap. OpenBot publishes templates to a
//  hosted page and installs them from a link; Wisp has no server and keeps
//  nothing off this Mac by default, so a template here is either bundled with
//  the app or one you saved yourself from a buddy of yours (to share one with
//  another person, the buddy's Share… file is still the way).
//
//  A template is setup only — the job, role, tone, schedule, optional tool
//  limits and model. Never a conversation, notes or files. Adding one always
//  goes through a review (`BuddyTemplateReview`) that says what it will do and
//  when, and a schedule only starts after that tap.
//

import Combine
import Foundation

struct BuddyTemplate: Codable, Identifiable, Equatable {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case daily
        case study
        case work
        case mac

        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: return "Daily"
            case .study: return "Study"
            case .work: return "Work"
            case .mac: return "On your Mac"
            }
        }
    }

    enum Origin: String, Codable { case bundled, saved }

    /// A slug for a bundled template, a UUID for a saved one.
    let id: String
    var name: String
    /// One line on the card: what you get.
    var tagline: String
    /// The buddy's job, sent as its run request.
    var mission: String
    var category: Category
    var specialty: BuddySpecialty
    var personality: BuddyPersonality
    var schedule: BuddySchedule
    /// Nil uses the specialty's colour.
    var colorIndex: Int?
    /// Nil uses the specialty's default tool limits.
    var toolAccess: BuddyToolAccess?
    /// Nil follows whatever model Wisp uses.
    var modelChoice: BuddyModelChoice?
    var origin: Origin

    var isSaved: Bool { origin == .saved }
}

/// What the review shows before a template is added, as plain rows.
struct BuddyTemplateReviewRow: Equatable, Identifiable {
    let title: String
    let text: String
    var id: String { title }
}

enum BuddyTemplateReview {
    /// The rows, in order: what it does, when it runs, what it can use, where
    /// it runs. `toolSummary` is passed in (it needs the tool-group names).
    static func rows(for template: BuddyTemplate, toolSummary: String) -> [BuddyTemplateReviewRow] {
        let whereItRuns: String
        if let modelChoice = template.modelChoice {
            whereItRuns = modelChoice.sendsDataOffThisMachine
                ? "\(modelChoice.displayName) — what it works on leaves this Mac"
                : "\(modelChoice.displayName) — on this Mac"
        } else {
            whereItRuns = "Whatever model Wisp uses"
        }
        return [
            BuddyTemplateReviewRow(title: "What it does", text: template.mission),
            BuddyTemplateReviewRow(title: "When it runs", text: template.schedule.summary()),
            BuddyTemplateReviewRow(title: "What it can use", text: toolSummary),
            BuddyTemplateReviewRow(title: "Where it runs", text: whereItRuns),
        ]
    }

    /// A name that is not already taken: "Hacker News", then "Hacker News 2".
    static func uniqueName(_ name: String, avoiding existingNames: [String]) -> String {
        let taken = Set(existingNames.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)".lowercased()) { suffix += 1 }
        return "\(name) \(suffix)"
    }

    static func matches(_ template: BuddyTemplate, searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return [template.name, template.tagline, template.mission, template.specialty.title]
            .contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

enum BuddyTemplateCatalog {
    /// Bundled templates. Each is something Wisp can do with its own tools and
    /// no account; none needs a connected app.
    static let bundled: [BuddyTemplate] = [
        make("hacker-news", "Hacker News digest", "The top stories each morning, five lines.",
             "Every morning, summarize the top stories on Hacker News in five short lines, each with its link.",
             .daily, .researcher, .chill, .daily(hour: 8, minute: 0)),
        make("day-planner", "Day planner", "Your calendar and what to prepare for it.",
             "Every morning, tell me what's on my calendar today and what to prepare for each thing. Keep it short.",
             .daily, .planner, .coach, .daily(hour: 8, minute: 30)),
        make("evening-wind-down", "Evening wind-down", "Tomorrow's reminders and one thing to prep tonight.",
             "Every evening, list my reminders that are due tomorrow and suggest the one thing worth preparing tonight.",
             .daily, .planner, .chill, .daily(hour: 21, minute: 0)),
        make("weekly-review", "Weekly review", "A Sunday look back and a plan for the week.",
             "Every Sunday, help me look back on the week from my calendar and reminders, and plan the week ahead.",
             .daily, .planner, .coach, .weekly(weekday: 1, hour: 18, minute: 0)),
        make("swift-scout", "Swift project scout", "Interesting new Swift projects, weekly.",
             "Every Monday, find the most interesting new Swift projects on GitHub trending and say why each is worth a look.",
             .work, .researcher, .hype, .weekly(weekday: 2, hour: 9, minute: 0)),
        make("quiz-maker", "Quiz maker", "Five questions on what you're studying.",
             "Quiz me on the notes or the screen I'm looking at: ask five questions one at a time, then check my answers and explain what I missed.",
             .study, .general, .teacher, .once),
        make("essay-coach", "Essay coach", "The three biggest problems in a draft, not a rewrite.",
             "Read the draft I give you. Tell me the three biggest problems and one thing that works. Do not rewrite it for me.",
             .study, .writer, .teacher, .once),
        make("reply-drafter", "Reply drafter", "A polite reply, short and long.",
             "Draft a polite reply to whatever I paste or attach, in two lengths: one line, and a short paragraph.",
             .work, .writer, .chill, .once),
        make("bug-hunter", "Bug hunter", "Finds a bug you describe and explains the fix.",
             "Find and fix a bug I describe in my project, then explain the change in plain words.",
             .work, .coder, .deadpan, .once),
        make("tab-tidier", "Tab tidier", "Groups Chrome tabs by site and closes duplicates.",
             "Organize my Chrome tabs by site and close duplicates. Needs the Wisp Tabs extension.",
             .mac, .organizer, .chill, .once),
        make("build-watcher", "Build watcher", "Tells you when something on your screen finishes.",
             "Watch my screen and tell me when the thing I name finishes, like a build or a download.",
             .mac, .watcher, .deadpan, .once),
    ]

    private static func make(
        _ id: String, _ name: String, _ tagline: String, _ mission: String,
        _ category: BuddyTemplate.Category, _ specialty: BuddySpecialty,
        _ personality: BuddyPersonality, _ schedule: BuddySchedule
    ) -> BuddyTemplate {
        BuddyTemplate(
            id: id, name: name, tagline: tagline, mission: mission, category: category,
            specialty: specialty, personality: personality, schedule: schedule,
            colorIndex: nil, toolAccess: nil, modelChoice: nil, origin: .bundled
        )
    }

    /// A template from one of the user's own buddies: setup only.
    static func savedTemplate(from buddy: WispBuddy, id: UUID = UUID()) -> BuddyTemplate {
        BuddyTemplate(
            id: id.uuidString,
            name: buddy.name,
            tagline: String(buddy.instruction.prefix(80)),
            mission: buddy.instruction,
            category: .work,
            specialty: buddy.specialty ?? .general,
            personality: buddy.personality ?? .coach,
            schedule: buddy.schedule,
            colorIndex: buddy.colorIndex,
            toolAccess: buddy.toolAccess,
            modelChoice: buddy.modelChoice,
            origin: .saved
        )
    }
}

/// The user's saved templates, in `~/Library/Application Support/Wisp/buddy-templates.json`
/// (0600, local only).
@MainActor
final class BuddyTemplateStore: ObservableObject {
    static let shared = BuddyTemplateStore()
    static let maximumSavedTemplates = 50
    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/buddy-templates.json")

    @Published private(set) var savedTemplates: [BuddyTemplate] = []
    private let fileURL: URL

    init(fileURL: URL = BuddyTemplateStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([BuddyTemplate].self, from: data) {
            savedTemplates = decoded.filter(\.isSaved)
        }
    }

    var allTemplates: [BuddyTemplate] { savedTemplates + BuddyTemplateCatalog.bundled }

    /// Saves a buddy's setup. A second save of the same name replaces the first.
    @discardableResult
    func save(buddy: WispBuddy) -> BuddyTemplate {
        let template = BuddyTemplateCatalog.savedTemplate(from: buddy)
        savedTemplates.removeAll { $0.name.caseInsensitiveCompare(template.name) == .orderedSame }
        savedTemplates.insert(template, at: 0)
        if savedTemplates.count > Self.maximumSavedTemplates { savedTemplates.removeLast() }
        persist()
        return template
    }

    func remove(templateWithID templateID: String) {
        savedTemplates.removeAll { $0.id == templateID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(savedTemplates) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

extension BuddyStore {
    /// Adds a buddy from a template, after the user reviewed it. A repeating
    /// schedule starts from the next time it is due; "when asked" does not run
    /// at once (`createBuddy` would run a one-off straight away, so it is made
    /// with a repeating placeholder and then set to `.once`, as an import is).
    @discardableResult
    func addBuddy(from template: BuddyTemplate) -> WispBuddy {
        let created = createBuddy(
            instruction: template.mission,
            schedule: template.schedule.isRepeating ? template.schedule : .daily(hour: 9, minute: 0),
            modelChoice: template.modelChoice,
            toolAccess: template.toolAccess ?? template.specialty.toolAccess,
            specialty: template.specialty,
            personality: template.personality,
            name: BuddyTemplateReview.uniqueName(template.name, avoiding: buddies.map(\.name)),
            colorIndex: template.colorIndex ?? template.specialty.preferredColorIndex,
            runImmediately: false
        )
        if !template.schedule.isRepeating { updateSchedule(ofBuddyWithID: created.id, to: .once) }
        return created
    }
}
