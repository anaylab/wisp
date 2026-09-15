//
//  AgentSettingsStore.swift
//  leanring-buddy
//
//  User-facing agent settings. Currently the agent's working folder — the
//  directory file-touching tools (like the Claude Code worker) run in. Defaults
//  to the shipped `CodeProjectDirectory` and can be pointed anywhere the user
//  grants access to.
//
//  The resolved path is also readable off the main actor (via UserDefaults) so
//  the tool registry, which resolves it inside a tool call, does not have to hop
//  actors just to read a string.
//

import Combine
import Foundation

@MainActor
final class AgentSettingsStore: ObservableObject {
    static let shared = AgentSettingsStore()

    /// The chosen working directory path, or nil to use the shipped default.
    @Published var workingDirectoryPath: String? {
        didSet {
            let userDefaults = UserDefaults.standard
            if let workingDirectoryPath, !workingDirectoryPath.isEmpty {
                userDefaults.set(workingDirectoryPath, forKey: Self.workingDirectoryKey)
            } else {
                userDefaults.removeObject(forKey: Self.workingDirectoryKey)
            }
        }
    }

    nonisolated private static let workingDirectoryKey = "wisp.agent.workingDirectory"

    private init() {
        workingDirectoryPath = UserDefaults.standard.string(forKey: Self.workingDirectoryKey)
    }

    /// The path the agent will actually use, expanded, for display.
    var resolvedWorkingDirectoryDisplayPath: String {
        (Self.resolvedWorkingDirectoryPath() as NSString).abbreviatingWithTildeInPath
    }

    var isUsingDefaultWorkingDirectory: Bool {
        workingDirectoryPath == nil
    }

    func setWorkingDirectory(_ url: URL) {
        workingDirectoryPath = url.path
    }

    func resetWorkingDirectoryToDefault() {
        workingDirectoryPath = nil
    }

    /// The shipped default working directory (from Info.plist).
    nonisolated static var defaultWorkingDirectoryPath: String {
        AppBundleConfiguration.stringValue(forKey: "CodeProjectDirectory") ?? "~/Downloads/clicky"
    }

    /// Resolves the working directory path without touching the main actor, so a
    /// tool call can read it inline. Prefers the user's choice, then the default.
    nonisolated static func resolvedWorkingDirectoryPath() -> String {
        if let storedPath = UserDefaults.standard.string(forKey: workingDirectoryKey), !storedPath.isEmpty {
            return storedPath
        }
        return defaultWorkingDirectoryPath
    }
}
