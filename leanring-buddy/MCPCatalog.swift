//
//  MCPCatalog.swift
//  leanring-buddy
//
//  The marketplace's catalog model: the shape of one browsable, installable MCP
//  server, and the small pieces of information a user must supply to install it
//  (an API token, a workspace id). Entries come from a catalog provider — a
//  bundled curated registry today, Composio's toolkit catalog in a later phase.
//
//  A catalog entry is a *template*: it names how to run or reach a server and
//  which fields the user fills in. Installing it turns the template plus the
//  filled-in values into a `~/.wisp/mcp.json` entry (see InstalledMCPServerStore).
//

import Foundation

/// One installable server in the marketplace.
struct MCPCatalogEntry: Identifiable, Decodable, Sendable {
    /// How the server runs once installed.
    enum Kind: String, Decodable, Sendable {
        case stdio   // a local command Wisp spawns
        case remote  // a hosted server reached over Streamable HTTP
    }

    /// A stable id, also used as the `~/.wisp/mcp.json` key. Lowercase, no
    /// spaces (for example "github", "brave-search").
    let id: String
    let name: String
    let summary: String
    let publisher: String
    /// An SF Symbol shown on the card.
    let iconSymbol: String
    let categories: [String]
    let homepage: String?
    let kind: Kind

    // Stdio template ---------------------------------------------------------
    /// The command to spawn (for example "npx", "uvx"). Stdio entries only.
    let command: String?
    /// Fixed arguments for the command. Stdio entries only.
    let arguments: [String]?

    // Remote template --------------------------------------------------------
    /// The Streamable HTTP endpoint. Remote entries only.
    let url: String?

    // User-supplied configuration -------------------------------------------
    /// Values the user must provide at install time — an API key, a token, a
    /// team id. Empty when the server needs nothing.
    let configFields: [ConfigField]?

    var resolvedCategories: [String] { categories }
    var resolvedArguments: [String] { arguments ?? [] }
    var resolvedConfigFields: [ConfigField] { configFields ?? [] }
}

/// One value the user fills in when installing an entry.
struct ConfigField: Identifiable, Decodable, Sendable {
    /// Where the value goes once installed.
    enum Target: String, Decodable, Sendable {
        case env     // an environment variable on a stdio command
        case header  // an HTTP header on a remote server
    }

    /// The variable / header name, also the field's id (for example
    /// "GITHUB_PERSONAL_ACCESS_TOKEN", "Authorization").
    let id: String
    let label: String
    let placeholder: String?
    let target: Target
    /// A secret is entered in a masked field. It is still written to the local
    /// config file, the same place Claude Desktop keeps such tokens.
    let secret: Bool

    var resolvedPlaceholder: String { placeholder ?? "" }
}

/// The bundled `curated-mcp-registry.json` file's top-level shape.
struct CuratedRegistryFile: Decodable, Sendable {
    let version: Int
    let servers: [MCPCatalogEntry]
}
