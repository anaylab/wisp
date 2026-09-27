//
//  ConfiguredSourceStore.swift
//  leanring-buddy
//
//  Loads the user's own data sources from `~/.wisp/sources.json` — the same
//  `~/.wisp/` convention used for `mcp.json` and `skills/`. Each source names an
//  HTTPS endpoint and a small list of field mappings (a JSON path → a label), so
//  the user can wire Wisp up to "multiple sources and APIs" and show any of them
//  as a card in the notch. The model only ever names a source; Wisp holds the
//  URL, headers, and mapping here and fetches through `RESTSourceDataProvider`.
//
//  The source-of-truth is the file on disk. This store reads it (and re-reads on
//  demand) and publishes the parsed list for the dashboard's Sources tab and the
//  card pipeline. It never writes credentials anywhere else.
//

import Combine
import Foundation

/// One user-configured field pulled out of a source's JSON response.
struct ConfiguredSourceField: Codable, Equatable {
    /// The label shown on the card for this value.
    let label: String
    /// A dot-separated path into the JSON response, e.g. "data.0.score".
    let path: String
    /// Optional semantic tone (good/bad/neutral) resolved to a DS colour by the
    /// generic card, never a raw colour.
    let tone: String?
}

/// One user-configured source: a name the model can ask for, an HTTPS endpoint,
/// optional request headers, and which fields to show.
struct ConfiguredSource: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let url: String
    let headers: [String: String]?
    let fields: [ConfiguredSourceField]
    /// Absent means enabled; only an explicit `false` disables it.
    let enabled: Bool?

    var isEnabled: Bool { enabled ?? true }
}

@MainActor
final class ConfiguredSourceStore: ObservableObject {
    static let shared = ConfiguredSourceStore()

    /// The parsed sources, newest read from disk. Empty when the file is absent
    /// or unreadable — a missing config is not an error, just no sources.
    @Published private(set) var sources: [ConfiguredSource] = []

    /// `~/.wisp/sources.json` — the file the user edits.
    let configFileURL: URL

    private init() {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        configFileURL = homeDirectory
            .appendingPathComponent(".wisp", isDirectory: true)
            .appendingPathComponent("sources.json", isDirectory: false)
        reload()
    }

    /// Re-reads the config file. Safe to call repeatedly (e.g. when the Sources
    /// tab appears). A malformed file leaves the previous list in place is *not*
    /// done — instead it clears to empty so the tab reflects the real file state.
    func reload() {
        guard let data = try? Data(contentsOf: configFileURL) else {
            sources = []
            return
        }
        guard let decoded = try? JSONDecoder().decode(SourcesFile.self, from: data) else {
            sources = []
            return
        }
        sources = decoded.sources
    }

    /// The enabled source with this name (case-insensitive), if any.
    func enabledSource(named name: String) -> ConfiguredSource? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sources.first {
            $0.isEnabled && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
    }

    /// The names of the enabled sources, for teaching the model which sources it
    /// may ask for.
    var enabledSourceNames: [String] {
        sources.filter(\.isEnabled).map(\.name)
    }

    /// The wire shape of the file: `{ "sources": [ ... ] }`.
    private struct SourcesFile: Decodable {
        let sources: [ConfiguredSource]
    }
}
