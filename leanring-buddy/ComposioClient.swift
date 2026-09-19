//
//  ComposioClient.swift
//  leanring-buddy
//
//  A thin client for Composio's v3 management API — enough to power the
//  marketplace's Composio path: list the toolkits a user can install, create a
//  managed MCP server for the ones they choose, and mint a user-scoped MCP URL
//  Wisp then connects to over the Streamable HTTP transport.
//
//  Composio holds the third-party credentials; Wisp never sees them. The only
//  secret here is the user's own Composio API key (from ComposioKeychainStore),
//  sent as the `x-api-key` header — required on every call, and, as of March
//  2026, on the resulting MCP endpoint too.
//
//  Endpoints (base https://backend.composio.dev/api/v3):
//    GET  /toolkits                     — the installable catalog
//    POST /mcp/servers/custom           — create a managed MCP server for toolkits
//    POST /mcp/servers/generate         — mint a user-scoped MCP URL for a server
//

import Foundation

// MARK: - Models

/// One installable Composio integration (GitHub, Gmail, Slack, …).
struct ComposioToolkit: Identifiable, Sendable {
    let slug: String
    let name: String
    let description: String?
    let logoURL: String?
    var id: String { slug }
}

/// The result of provisioning a managed server and minting a user-scoped URL:
/// everything the marketplace needs to install it as a remote MCP entry.
struct ComposioProvisionedServer: Sendable {
    let serverId: String
    /// The per-user MCP endpoint Wisp connects to.
    let userScopedURL: URL
}

enum ComposioError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case malformedResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "no Composio API key is set."
        case .http(let status, let message):
            if status == 401 { return "Composio rejected the API key (401). check it in your Composio dashboard." }
            return "Composio returned HTTP \(status)\(message.isEmpty ? "" : " — \(message)")."
        case .malformedResponse(let detail):
            return "couldn't read Composio's response: \(detail)"
        case .network(let detail):
            return "couldn't reach Composio: \(detail)"
        }
    }
}

// MARK: - Client

struct ComposioClient: Sendable {
    private let baseURL = URL(string: "https://backend.composio.dev/api/v3")!
    private let apiKey: String
    private let urlSession: URLSession

    /// Builds a client from the stored key, or nil when none is set.
    init?(urlSession: URLSession = .shared) {
        guard let key = ComposioKeychainStore.apiKey(), !key.isEmpty else { return nil }
        self.apiKey = key
        self.urlSession = urlSession
    }

    /// Lists the toolkits available to install. Doubles as key validation: a
    /// 200 means the key works, a 401 that it doesn't.
    func listToolkits(limit: Int = 100) async throws -> [ComposioToolkit] {
        var components = URLComponents(url: baseURL.appendingPathComponent("toolkits"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]

        let data = try await get(components.url!)
        do {
            let decoded = try JSONDecoder().decode(ToolkitListResponse.self, from: data)
            return decoded.items.map { item in
                ComposioToolkit(
                    slug: item.slug,
                    name: item.name ?? item.slug,
                    description: item.meta?.description,
                    logoURL: item.meta?.logo
                )
            }
        } catch {
            throw ComposioError.malformedResponse(error.localizedDescription)
        }
    }

    /// Creates a managed MCP server for the given toolkits and mints a
    /// user-scoped URL for `userId` in one step.
    func provisionManagedServer(
        name: String,
        toolkits: [String],
        userId: String
    ) async throws -> ComposioProvisionedServer {
        let serverId = try await createManagedServer(name: name, toolkits: toolkits)
        let url = try await generateUserURL(serverId: serverId, userId: userId)
        return ComposioProvisionedServer(serverId: serverId, userScopedURL: url)
    }

    /// POST /mcp/servers/custom — returns the new server's id.
    func createManagedServer(name: String, toolkits: [String]) async throws -> String {
        let body: [String: Any] = [
            "name": name,
            "toolkits": toolkits,
            "managed_auth_via_composio": true
        ]
        let data = try await post(baseURL.appendingPathComponent("mcp/servers/custom"), body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverId = object["id"] as? String else {
            throw ComposioError.malformedResponse("no server id in create response")
        }
        return serverId
    }

    /// POST /mcp/servers/generate — returns the user-scoped MCP URL.
    func generateUserURL(serverId: String, userId: String) async throws -> URL {
        let body: [String: Any] = [
            "mcp_server_id": serverId,
            "managed_auth_by_composio": true,
            "user_ids": [userId]
        ]
        let data = try await post(baseURL.appendingPathComponent("mcp/servers/generate"), body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComposioError.malformedResponse("generate response wasn't an object")
        }

        // The per-user URL is the one to connect to; fall back to the base URL.
        let urlString: String?
        if let userURLs = object["user_ids_url"] as? [String], let first = userURLs.first {
            urlString = first
        } else {
            urlString = object["mcp_url"] as? String
        }

        guard let urlString, let url = URL(string: urlString) else {
            throw ComposioError.malformedResponse("no usable MCP URL in generate response")
        }
        return url
    }

    // MARK: - HTTP

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        return try await perform(request)
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ComposioError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ComposioError.malformedResponse("response wasn't HTTP")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
            throw ComposioError.http(status: httpResponse.statusCode, message: message)
        }

        return data
    }

    /// Pulls a human-readable reason out of Composio's error envelope.
    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = object["message"] as? String { return message }
        return ""
    }
}

// MARK: - Decoding

/// The toolkits list envelope, decoded leniently so a shape change in fields we
/// don't use doesn't break the catalog.
private struct ToolkitListResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let slug: String
        let name: String?
        let meta: Meta?
    }

    struct Meta: Decodable {
        let description: String?
        let logo: String?
    }
}
