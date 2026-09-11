//
//  SkillManager.swift
//  leanring-buddy
//
//  Reads user-authored skills — markdown files with a short frontmatter
//  header — from ~/.wisp/skills/.
//
//  Only name and description are ever kept in memory. The full body is
//  re-read from disk each time it is asked for, so a skill can be edited on
//  disk and take effect on the very next call, and so an arbitrarily large
//  skill library costs nothing beyond one short index line per file until
//  the model actually asks to load one.
//
//  Frontmatter is two flat string fields, so a hand-rolled scanner is used
//  rather than a YAML dependency — nothing else in this project parses YAML.
//

import Foundation
import Combine

@MainActor
final class SkillManager: ObservableObject {
    static let shared = SkillManager()

    struct SkillSummary: Identifiable {
        var id: String { name }
        let name: String
        let description: String
        let fileURL: URL
    }

    /// Frontmatter descriptions are capped, not rejected, so a verbose
    /// one-liner degrades gracefully instead of silently dropping the skill.
    private static let maximumDescriptionLength = 100

    @Published private(set) var skills: [SkillSummary] = []

    private var skillsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wisp/skills")
    }

    /// Rescans ~/.wisp/skills/ and replaces the published index.
    ///
    /// A missing directory is the normal state for someone who has never
    /// added a skill, not an error — it simply yields an empty list.
    @discardableResult
    func loadSkills() -> [SkillSummary] {
        let directory = skillsDirectoryURL
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            skills = []
            return skills
        }

        let discovered = fileURLs
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { fileURL -> SkillSummary? in
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                      let frontmatter = Self.parseFrontmatter(text) else { return nil }
                return SkillSummary(
                    name: frontmatter.name,
                    description: frontmatter.description,
                    fileURL: fileURL
                )
            }
            .sorted { $0.name < $1.name }

        skills = discovered
        return discovered
    }

    /// The full body of one skill, read fresh from disk.
    func body(forSkillNamed name: String) -> String? {
        guard let summary = skills.first(where: { $0.name == name }),
              let text = try? String(contentsOf: summary.fileURL, encoding: .utf8),
              let frontmatter = Self.parseFrontmatter(text) else { return nil }
        return frontmatter.body
    }

    /// Splits a skill file into its `name`, `description` and body.
    ///
    /// Expects `---` on its own line, `key: value` lines in between, then
    /// `---` again followed by the body. A file missing either required
    /// field is treated as unparseable rather than partially loaded, so a
    /// broken skill is skipped cleanly instead of showing up half-described.
    private static func parseFrontmatter(_ text: String) -> (name: String, description: String, body: String)? {
        var lines = text.components(separatedBy: .newlines)[...]

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        var fields: [String: String] = [:]
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                lines.removeFirst()
                break
            }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                fields[key] = value
            }
            lines.removeFirst()
        }

        guard let name = fields["name"], !name.isEmpty,
              let rawDescription = fields["description"], !rawDescription.isEmpty else { return nil }

        let description = rawDescription.count > maximumDescriptionLength
            ? String(rawDescription.prefix(maximumDescriptionLength)) + "…"
            : rawDescription

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (name: name, description: description, body: body)
    }
}
