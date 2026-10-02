//
//  CodingAgentHookInstaller.swift
//  leanring-buddy
//
//  Adds (or removes) Wisp's hook entries in a coding agent's settings file, so
//  the agent calls the relay on every event:
//
//    Claude Code   ~/.claude/settings.json          hooks.<Event>[].hooks[]
//    Gemini CLI    ~/.gemini/settings.json          hooks.<Event>[].hooks[]  (--agent gemini)
//    Antigravity   ~/.gemini/config/hooks.json      a "wisp" hook set        (--agent antigravity)
//
//  These files belong to the user and to other tools, so the rules are strict:
//  only entries whose command runs `wisp-agent-hook` are ever added or removed;
//  a file that isn't valid JSON (or whose "hooks" has an unexpected shape) is
//  left untouched with an explanation; the change is shown as a preview before
//  anything is written; the file is backed up (dated copy beside it) first;
//  and if it changed between preview and confirm, nothing is written.
//
//  The merging is pure (`CodingAgentHookSettingsMerger`) so it's testable
//  without touching a real settings file. Adapted from Coucou's installers (MIT).
//

import CryptoKit
import Foundation

nonisolated enum CodingAgentHookTarget: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case geminiCLI
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .geminiCLI: return "Gemini CLI"
        case .antigravity: return "Antigravity"
        }
    }

    /// The path as the user would type it, for labels.
    var displaySettingsPath: String {
        switch self {
        case .claudeCode: return "~/.claude/settings.json"
        case .geminiCLI: return "~/.gemini/settings.json"
        case .antigravity: return "~/.gemini/config/hooks.json"
        }
    }

    var settingsFileURL: URL {
        let homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode: return homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        case .geminiCLI: return homeDirectoryURL.appendingPathComponent(".gemini/settings.json")
        case .antigravity: return homeDirectoryURL.appendingPathComponent(".gemini/config/hooks.json")
        }
    }

    var whatItEnables: String {
        switch self {
        case .claudeCode: return "Live sessions in the notch, and Allow / Deny for its permission prompts."
        case .geminiCLI: return "Live sessions in the notch. Permission prompts stay in the terminal."
        case .antigravity: return "Live sessions in the notch. Permission prompts stay in the terminal."
        }
    }
}

nonisolated enum CodingAgentHookInstallerError: LocalizedError {
    case unreadableSettingsFile(path: String)
    case invalidSettingsJSON(path: String)
    case unexpectedHooksShape(path: String, keyPath: String)
    case settingsFileChangedSincePreview(path: String)
    case backupFailed(path: String, underlyingDescription: String)

    var errorDescription: String? {
        switch self {
        case .unreadableSettingsFile(let path):
            return "\(path) can't be read. Wisp hasn't touched it."
        case .invalidSettingsJSON(let path):
            return "\(path) isn't valid JSON. Wisp hasn't touched it."
        case .unexpectedHooksShape(let path, let keyPath):
            return "\(path): \(keyPath) isn't in the shape Wisp expects. Wisp hasn't touched it."
        case .settingsFileChangedSincePreview(let path):
            return "\(path) changed since the preview. Nothing was written. Try again."
        case .backupFailed(let path, let underlyingDescription):
            return "Couldn't back up \(path), so nothing was written: \(underlyingDescription)"
        }
    }
}

/// Pure JSON merging for each agent's settings format.
nonisolated enum CodingAgentHookSettingsMerger {
    /// Claude Code's events and each hook's timeout in seconds. The permission
    /// hook waits for the user, so it gets Claude Code's 120s maximum.
    static let claudeCodeEventTimeouts: [(eventName: String, timeoutSeconds: Int)] = [
        ("SessionStart", 10), ("SessionEnd", 10),
        ("UserPromptSubmit", 10),
        ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
        ("PermissionRequest", 120),
        ("Notification", 10),
        ("Stop", 10), ("StopFailure", 10),
        ("SubagentStart", 10), ("SubagentStop", 10),
    ]

    /// Gemini CLI's event names, the canonical name the relay is told, and
    /// the timeout in milliseconds (Gemini's unit).
    static let geminiCLIEvents: [(geminiEventName: String, canonicalEventName: String, timeoutMilliseconds: Int)] = [
        ("SessionStart", "SessionStart", 10_000),
        ("SessionEnd", "SessionEnd", 10_000),
        ("BeforeTool", "PreToolUse", 5_000),
        ("AfterTool", "PostToolUse", 5_000),
        ("BeforeAgent", "UserPromptSubmit", 5_000),
        ("AfterAgent", "Stop", 5_000),
    ]

    /// The key of Wisp's own hook set in Antigravity's hooks.json.
    static let antigravityHookSetKey = "wisp"

    static func isWispHookCommand(_ command: String) -> Bool {
        command.contains(CodingAgentHookRelay.wrapperScriptFileName)
    }

    static func containsWispHooks(target: CodingAgentHookTarget, settings: [String: Any]) -> Bool {
        if target == .antigravity {
            return settings[antigravityHookSetKey] != nil
        }
        guard let hooksByEvent = settings["hooks"] as? [String: Any] else { return false }
        return hooksByEvent.values.contains { eventHooks in
            guard let hookGroups = eventHooks as? [[String: Any]] else { return false }
            return hookGroups.contains { groupContainsWispHook($0) }
        }
    }

    static func installingHooks(
        for target: CodingAgentHookTarget,
        into settings: [String: Any],
        commandBase: String,
        settingsPathForErrors: String
    ) throws -> [String: Any] {
        switch target {
        case .claudeCode:
            var updatedHooksByEvent = try hooksDictionary(in: settings, settingsPathForErrors: settingsPathForErrors)
            for (eventName, timeoutSeconds) in claudeCodeEventTimeouts {
                var hookGroups = try hookGroupList(updatedHooksByEvent[eventName], eventName: eventName, settingsPathForErrors: settingsPathForErrors)
                hookGroups = removingWispHooks(from: hookGroups)
                hookGroups.append(["hooks": [["type": "command", "command": commandBase, "timeout": timeoutSeconds]]])
                updatedHooksByEvent[eventName] = hookGroups
            }
            var updatedSettings = settings
            updatedSettings["hooks"] = updatedHooksByEvent
            return updatedSettings

        case .geminiCLI:
            var updatedHooksByEvent = try hooksDictionary(in: settings, settingsPathForErrors: settingsPathForErrors)
            for (geminiEventName, canonicalEventName, timeoutMilliseconds) in geminiCLIEvents {
                var hookGroups = try hookGroupList(updatedHooksByEvent[geminiEventName], eventName: geminiEventName, settingsPathForErrors: settingsPathForErrors)
                hookGroups = removingWispHooks(from: hookGroups)
                hookGroups.append([
                    "matcher": "*",
                    "hooks": [[
                        "type": "command",
                        "command": "\(commandBase) --agent gemini \(canonicalEventName)",
                        "timeout": timeoutMilliseconds,
                    ]],
                ])
                updatedHooksByEvent[geminiEventName] = hookGroups
            }
            var updatedSettings = settings
            updatedSettings["hooks"] = updatedHooksByEvent
            return updatedSettings

        case .antigravity:
            // Tool hooks take a matcher group; lifecycle hooks are bare handlers.
            var wispHookSet: [String: Any] = [:]
            for eventName in ["PreToolUse", "PostToolUse"] {
                let hookEntry: [String: Any] = ["type": "command", "command": "\(commandBase) --agent antigravity \(eventName)", "timeout": 10]
                wispHookSet[eventName] = [["matcher": "*", "hooks": [hookEntry]]]
            }
            for eventName in ["PreInvocation", "PostInvocation", "Stop"] {
                let hookEntry: [String: Any] = ["type": "command", "command": "\(commandBase) --agent antigravity \(eventName)", "timeout": 10]
                wispHookSet[eventName] = [hookEntry]
            }
            var updatedSettings = settings
            updatedSettings[antigravityHookSetKey] = wispHookSet
            return updatedSettings
        }
    }

    static func removingHooks(
        for target: CodingAgentHookTarget,
        from settings: [String: Any],
        settingsPathForErrors: String
    ) throws -> [String: Any] {
        var updatedSettings = settings
        if target == .antigravity {
            updatedSettings.removeValue(forKey: antigravityHookSetKey)
            return updatedSettings
        }
        guard settings["hooks"] != nil else { return settings }
        var updatedHooksByEvent = try hooksDictionary(in: settings, settingsPathForErrors: settingsPathForErrors)
        for (eventName, eventHooks) in updatedHooksByEvent {
            guard let hookGroups = eventHooks as? [[String: Any]] else { continue }
            let remainingHookGroups = removingWispHooks(from: hookGroups)
            if remainingHookGroups.isEmpty {
                updatedHooksByEvent.removeValue(forKey: eventName)
            } else {
                updatedHooksByEvent[eventName] = remainingHookGroups
            }
        }
        if updatedHooksByEvent.isEmpty {
            updatedSettings.removeValue(forKey: "hooks")
        } else {
            updatedSettings["hooks"] = updatedHooksByEvent
        }
        return updatedSettings
    }

    /// Drops Wisp's hooks from each group, and groups left empty by that.
    /// Other tools' hooks in the same group are kept as they were.
    static func removingWispHooks(from hookGroups: [[String: Any]]) -> [[String: Any]] {
        hookGroups.compactMap { hookGroup in
            // An older flat entry: the command sits on the group itself.
            if let groupCommand = hookGroup["command"] as? String, isWispHookCommand(groupCommand) {
                return nil
            }
            guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { return hookGroup }
            let remainingInnerHooks = innerHooks.filter { !isWispHookCommand($0["command"] as? String ?? "") }
            guard !remainingInnerHooks.isEmpty else { return nil }
            var updatedGroup = hookGroup
            updatedGroup["hooks"] = remainingInnerHooks
            return updatedGroup
        }
    }

    private static func groupContainsWispHook(_ hookGroup: [String: Any]) -> Bool {
        if let groupCommand = hookGroup["command"] as? String, isWispHookCommand(groupCommand) { return true }
        let innerHooks = hookGroup["hooks"] as? [[String: Any]] ?? []
        return innerHooks.contains { isWispHookCommand($0["command"] as? String ?? "") }
    }

    private static func hooksDictionary(in settings: [String: Any], settingsPathForErrors: String) throws -> [String: Any] {
        guard let rawHooks = settings["hooks"] else { return [:] }
        guard let hooksByEvent = rawHooks as? [String: Any] else {
            throw CodingAgentHookInstallerError.unexpectedHooksShape(path: settingsPathForErrors, keyPath: "\"hooks\"")
        }
        return hooksByEvent
    }

    private static func hookGroupList(_ rawEventHooks: Any?, eventName: String, settingsPathForErrors: String) throws -> [[String: Any]] {
        guard let rawEventHooks else { return [] }
        guard let hookGroups = rawEventHooks as? [[String: Any]] else {
            throw CodingAgentHookInstallerError.unexpectedHooksShape(path: settingsPathForErrors, keyPath: "\"hooks\".\"\(eventName)\"")
        }
        return hookGroups
    }
}

/// A change waiting for the user's confirmation.
nonisolated struct CodingAgentHookChangePreview: Identifiable, Sendable {
    let id = UUID()
    let target: CodingAgentHookTarget
    let isInstalling: Bool
    /// The file as it is now, re-serialised the way Wisp will write it, so the
    /// diff shows only real changes rather than formatting.
    let currentNormalizedText: String
    let proposedText: String
    /// SHA-256 of the file's exact bytes at preview time (empty file if absent).
    let currentFileFingerprint: String

    var addedLines: [String] { lineDifference.added }
    var removedLines: [String] { lineDifference.removed }

    private var lineDifference: (added: [String], removed: [String]) {
        let currentLines = currentNormalizedText.components(separatedBy: "\n")
        let proposedLines = proposedText.components(separatedBy: "\n")
        var addedLines: [String] = []
        var removedLines: [String] = []
        for change in proposedLines.difference(from: currentLines) {
            switch change {
            case .insert(_, let line, _): addedLines.append(line)
            case .remove(_, let line, _): removedLines.append(line)
            }
        }
        return (addedLines, removedLines)
    }
}

/// Reads, previews and writes the settings files.
nonisolated enum CodingAgentHookInstaller {
    static func isInstalled(_ target: CodingAgentHookTarget) -> Bool {
        guard let settings = try? readSettings(of: target) else { return false }
        return CodingAgentHookSettingsMerger.containsWispHooks(target: target, settings: settings)
    }

    static func preview(_ target: CodingAgentHookTarget, installing isInstalling: Bool) throws -> CodingAgentHookChangePreview {
        let currentFileData = (try? Data(contentsOf: target.settingsFileURL)) ?? Data()
        let currentSettings = try readSettings(of: target)
        let proposedSettings = isInstalling
            ? try CodingAgentHookSettingsMerger.installingHooks(
                for: target,
                into: currentSettings,
                commandBase: CodingAgentHookRelay.hookCommandBase,
                settingsPathForErrors: target.displaySettingsPath
            )
            : try CodingAgentHookSettingsMerger.removingHooks(
                for: target,
                from: currentSettings,
                settingsPathForErrors: target.displaySettingsPath
            )
        return CodingAgentHookChangePreview(
            target: target,
            isInstalling: isInstalling,
            currentNormalizedText: currentSettings.isEmpty ? "" : try serializedText(currentSettings),
            proposedText: try serializedText(proposedSettings),
            currentFileFingerprint: fingerprint(of: currentFileData)
        )
    }

    /// Writes a confirmed preview: checks the file hasn't changed since, backs it
    /// up, then replaces it atomically.
    static func apply(_ preview: CodingAgentHookChangePreview) throws {
        let settingsFileURL = preview.target.settingsFileURL
        let fileManager = FileManager.default
        let currentFileData = (try? Data(contentsOf: settingsFileURL)) ?? Data()
        guard fingerprint(of: currentFileData) == preview.currentFileFingerprint else {
            throw CodingAgentHookInstallerError.settingsFileChangedSincePreview(path: preview.target.displaySettingsPath)
        }

        if fileManager.fileExists(atPath: settingsFileURL.path) {
            let backupDateFormatter = DateFormatter()
            backupDateFormatter.locale = Locale(identifier: "en_US_POSIX")
            backupDateFormatter.dateFormat = "yyyyMMdd-HHmmss"
            let backupFileURL = settingsFileURL.deletingLastPathComponent()
                .appendingPathComponent("\(settingsFileURL.lastPathComponent).bak-\(backupDateFormatter.string(from: Date()))")
            do {
                try fileManager.copyItem(at: settingsFileURL, to: backupFileURL)
            } catch {
                throw CodingAgentHookInstallerError.backupFailed(
                    path: preview.target.displaySettingsPath,
                    underlyingDescription: error.localizedDescription
                )
            }
        }
        try fileManager.createDirectory(at: settingsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((preview.proposedText + "\n").utf8).write(to: settingsFileURL, options: .atomic)
    }

    /// An absent file is an empty object; one that can't be parsed is an error,
    /// never silently replaced.
    private static func readSettings(of target: CodingAgentHookTarget) throws -> [String: Any] {
        let settingsFileURL = target.settingsFileURL
        guard FileManager.default.fileExists(atPath: settingsFileURL.path) else { return [:] }
        let settingsData: Data
        do {
            settingsData = try Data(contentsOf: settingsFileURL)
        } catch {
            throw CodingAgentHookInstallerError.unreadableSettingsFile(path: target.displaySettingsPath)
        }
        if settingsData.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\t") }) {
            return [:]
        }
        guard let settings = (try? JSONSerialization.jsonObject(with: settingsData)) as? [String: Any] else {
            throw CodingAgentHookInstallerError.invalidSettingsJSON(path: target.displaySettingsPath)
        }
        return settings
    }

    private static func serializedText(_ settings: [String: Any]) throws -> String {
        let serializedData = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: serializedData, as: UTF8.self)
    }

    private static func fingerprint(of fileData: Data) -> String {
        SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
    }
}
