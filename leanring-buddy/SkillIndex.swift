//
//  SkillIndex.swift
//  leanring-buddy
//
//  The one line per skill appended to the system prompt so the model knows
//  what it can ask `load_skill` for.
//
//  Kept separate from StructuredTextToolProtocol, which renders tool
//  definitions generically: skills are a layer on top of one specific tool,
//  not a tool-protocol concept themselves.
//

import Foundation

enum SkillIndex {
    /// Renders the skill index, or an empty string if there is nothing to
    /// show — a machine with no skills configured pays nothing for this.
    static func promptInstructions(for skills: [SkillManager.SkillSummary]) -> String {
        guard !skills.isEmpty else { return "" }

        var lines = [
            "",
            "",
            "skills you can load with load_skill (call it once you know which one you need):"
        ]

        for skill in skills {
            lines.append("- \(skill.name): \(skill.description)")
        }

        return lines.joined(separator: "\n")
    }
}
