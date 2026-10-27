//
//  MCPCatalogProvider.swift
//  leanring-buddy
//
//  Where marketplace entries come from. A provider is just "give me the list of
//  installable servers", so the marketplace UI doesn't care whether they were
//  read from a bundled file or fetched from a service.
//
//  Phase 2 ships one provider: the curated registry baked into the app bundle
//  (curated-mcp-registry.json). A Composio provider that lists toolkits over the
//  API lands in Phase 3 and conforms to the same protocol.
//

import Foundation

enum MCPCatalogError: LocalizedError {
    case registryMissing
    case registryUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .registryMissing:
            return "the bundled MCP registry is missing from the app."
        case .registryUnreadable(let reason):
            return "the MCP registry couldn't be read: \(reason)"
        }
    }
}

protocol MCPCatalogProvider: Sendable {
    func entries() async throws -> [MCPCatalogEntry]
}

/// Loads the curated list shipped inside the app bundle.
struct CuratedRegistryCatalogProvider: MCPCatalogProvider {
    private let resourceName: String

    init(resourceName: String = "curated-mcp-registry") {
        self.resourceName = resourceName
    }

    func entries() async throws -> [MCPCatalogEntry] {
        guard let fileURL = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            throw MCPCatalogError.registryMissing
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(CuratedRegistryFile.self, from: data)
            return file.servers
        } catch {
            throw MCPCatalogError.registryUnreadable(error.localizedDescription)
        }
    }
}
