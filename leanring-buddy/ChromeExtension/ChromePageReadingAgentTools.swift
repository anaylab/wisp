//
//  ChromePageReadingAgentTools.swift
//  leanring-buddy
//
//  `chrome_read_tab` and `chrome_read_selection`: the model reads a Chrome
//  tab's text, or what the user selected in it, through the Wisp Tabs
//  extension — any tab, visible or not, with no screenshot.
//
//  Read-only and local (`.reading(.localMachine)`), so they never ask. Their
//  `chrome_` names put them in the `.browser` tool scope and the buddy Browser
//  group with the other Chrome tools. Without the `pages.read` capability each
//  one answers with how to allow it, rather than the model not knowing the
//  ability exists.
//

import Foundation

enum ChromePageReadingToolDefinitions {
    static let readTabToolName = "chrome_read_tab"
    static let readSelectionToolName = "chrome_read_selection"

    private static let tabArgumentSchema: JSONValue = .object([
        "type": .string("string"),
        "description": .string("Which tab: a tab id from chrome_list_tabs, or a word from its title or address. Leave out for the tab the user is looking at.")
    ])

    static let readTab = BuddyToolDefinition(
        name: readTabToolName,
        description: "Read the text of a Chrome tab (the one the user is looking at, or one named by id, title or address): its title, address and main text, without a screenshot. Use to summarize a page or answer what it says.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["tab": tabArgumentSchema])
        ]),
        metadata: .reading(.localMachine)
    )

    static let readSelection = BuddyToolDefinition(
        name: readSelectionToolName,
        description: "Read the text the user has selected in a Chrome tab, with a little of the page around it. Use when the user asks about \"this\" bit they highlighted.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["tab": tabArgumentSchema])
        ]),
        metadata: .reading(.localMachine)
    )
}

extension AgentToolRegistry {

    /// Registers the page-reading tools. Always registered, like the tab
    /// tools: when the extension or the permission is missing the reply says
    /// how to fix it.
    func registerChromePageReadingTools() {
        register(ChromePageReadingToolDefinitions.readTab) { input in
            await Self.readChromeTab(input: input, readingSelection: false)
        }

        register(ChromePageReadingToolDefinitions.readSelection) { input in
            await Self.readChromeTab(input: input, readingSelection: true)
        }
    }

    @MainActor
    private static func readChromeTab(input: JSONValue, readingSelection: Bool) async -> String {
        let characterBudget = ChromePageTextPrompt.characterBudget(
            isLocalModel: BuddyChatProviderSelection.current == .localOllama
        )
        do {
            let tabID: Int?
            switch try await resolvedChromeTab(from: input) {
            case .showingTab:
                tabID = nil
            case .tab(let resolvedTabID):
                tabID = resolvedTabID
            case .ambiguous(let candidates):
                return ChromeTabReferenceResolver.ambiguityReply(for: candidates)
            case .notFound:
                return "no open chrome tab matches that. call chrome_list_tabs for the open tabs and their ids."
            }

            if readingSelection {
                let selection = try await ChromePageReader.readSelection(tabID: tabID)
                return ChromePageTextPrompt.promptText(for: selection, characterBudget: characterBudget)
            }
            let pageText = try await ChromePageReader.readPage(tabID: tabID, maximumCharacters: characterBudget)
            guard !pageText.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // No title here: it's page text, and this reply isn't fenced.
                return "that tab has no readable text — it may be an app, a video or an image. a screenshot would show more."
            }
            return ChromePageTextPrompt.promptText(for: pageText, characterBudget: characterBudget)
        } catch {
            return error.localizedDescription
        }
    }

    /// The `tab` argument (or `tab_id`) resolved against the open tabs. A
    /// missing argument needs no tab list at all.
    @MainActor
    private static func resolvedChromeTab(from input: JSONValue) async throws -> ChromeTabReferenceResolver.Resolution {
        var rawReference: String?
        if case .object(let arguments) = input {
            for argumentName in ["tab", "tab_id", "tabId"] {
                switch arguments[argumentName] {
                case .string(let textReference)?:
                    rawReference = textReference
                case .number(let numericReference)?:
                    rawReference = Int(exactly: numericReference).map(String.init)
                default:
                    continue
                }
                break
            }
        }
        let trimmedReference = (rawReference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReference.isEmpty else { return .showingTab }

        let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
        let candidates = snapshot.tabs.map { tab in
            ChromeTabReferenceResolver.Candidate(id: tab.id, windowId: tab.windowId, title: tab.title, url: tab.url, isActive: tab.active)
        }
        return ChromeTabReferenceResolver.resolve(trimmedReference, among: candidates, focusedWindowID: snapshot.focusedWindowId)
    }
}
