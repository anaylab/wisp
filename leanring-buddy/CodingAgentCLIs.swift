//
//  CodingAgentCLIs.swift
//  leanring-buddy
//
//  The coding-agent command line tools Wisp can recognise on this Mac (the
//  same kind of list OpenBot shows under its agents). Detection only: it
//  looks for the executable on the user's login-shell PATH and never runs it,
//  reads its credentials or sends anything anywhere.
//

import Foundation

struct CodingAgentCLI: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    /// Executable names to look for, in order.
    let executableNames: [String]
    let installHint: String

    static let known: [CodingAgentCLI] = [
        CodingAgentCLI(id: "claude", displayName: "Claude Code", executableNames: ["claude"],
                       installHint: "npm install -g @anthropic-ai/claude-code"),
        CodingAgentCLI(id: "codex", displayName: "Codex", executableNames: ["codex"],
                       installHint: "npm install -g @openai/codex"),
        CodingAgentCLI(id: "cursor", displayName: "Cursor", executableNames: ["cursor-agent"],
                       installHint: "curl https://cursor.com/install -fsS | bash"),
        CodingAgentCLI(id: "cline", displayName: "Cline", executableNames: ["cline"],
                       installHint: "npm install -g cline"),
        CodingAgentCLI(id: "grok", displayName: "Grok", executableNames: ["grok"],
                       installHint: "See x.ai for the Grok CLI"),
        CodingAgentCLI(id: "muse", displayName: "Muse", executableNames: ["muse"],
                       installHint: "See the Muse docs"),
        CodingAgentCLI(id: "opencode", displayName: "OpenCode", executableNames: ["opencode"],
                       installHint: "npm install -g opencode-ai"),
    ]
}

enum CodingAgentCLIDetector {
    /// The path of each installed CLI, by id. Spawns the login shell once (its
    /// PATH is cached), so call it off the main actor.
    static func installedExecutablePaths() -> [String: String] {
        var pathsByID: [String: String] = [:]
        for cli in CodingAgentCLI.known {
            for executableName in cli.executableNames {
                if let path = LoginShellEnvironment.locateExecutable(named: executableName) {
                    pathsByID[cli.id] = path
                    break
                }
            }
        }
        return pathsByID
    }
}
