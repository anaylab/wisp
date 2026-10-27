//
//  LearnedShortcutToolLookup.swift
//  leanring-buddy
//
//  The registry side of `LearnedShortcutPromotion`'s question "does this tool ask before it
//  runs?": nil for a tool that isn't registered (treated as unsafe), otherwise the registry's own
//  answer, which is derived from the tool's metadata.
//

import Foundation

@MainActor
enum LearnedShortcutToolLookup {
    static func requiresConfirmationIfRegistered(_ toolName: String) -> Bool? {
        let registry = AgentToolRegistry.shared
        return registry.toolNames.contains(toolName) ? registry.requiresConfirmation(forToolNamed: toolName) : nil
    }
}
