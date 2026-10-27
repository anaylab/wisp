//
//  ComposioClient.swift
//  leanring-buddy
//
//  Composio's "connect" universal MCP server: one hosted endpoint that exposes
//  a handful of meta-tools (COMPOSIO_SEARCH_TOOLS, COMPOSIO_MULTI_EXECUTE_TOOL,
//  COMPOSIO_MANAGE_CONNECTIONS, …) through which the model reaches 500+ apps.
//  It authenticates with the account's connect API key in the
//  `x-consumer-api-key` header and speaks the MCP Streamable HTTP transport —
//  so Wisp connects to it with the same transport it uses for any remote server.
//
//  This client's only job is to validate the key before Wisp installs the
//  server: it performs an MCP `initialize` against the endpoint and checks the
//  key is accepted. Everything after that — discovering and running tools,
//  per-app OAuth — happens over the installed MCP server itself, not here.
//
//  (An earlier draft targeted Composio's platform managed-server API at
//  backend.composio.dev with an `x-api-key`; that is a different product and a
//  different key. This account uses the connect server, so that is what Wisp
//  integrates with.)
//

import Foundation

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

struct ComposioClient: Sendable {
    /// The connect universal MCP endpoint. Fixed for the connect product.
    static let mcpEndpoint = URL(string: "https://connect.composio.dev/mcp")!
    /// The header the connect product authenticates with — note this is
    /// `x-consumer-api-key`, not the platform API's `x-api-key`.
    static let authHeaderName = "x-consumer-api-key"

    private let apiKey: String
    private let urlSession: URLSession

    init?(urlSession: URLSession = .shared) {
        guard let key = ComposioKeychainStore.apiKey(), !key.isEmpty else { return nil }
        self.apiKey = key
        self.urlSession = urlSession
    }

    /// Confirms the key is accepted by performing an MCP `initialize` against
    /// the connect server. A 401 means the key is wrong; a 2xx with a JSON-RPC
    /// result means it works.
    func validate() async throws {
        var request = URLRequest(url: Self.mcpEndpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: Self.authHeaderName)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "Wisp", "version": "1.0"]
            ]
        ])

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
            throw ComposioError.http(status: httpResponse.statusCode, message: "")
        }

        // A well-formed initialize reply confirms the handshake; the body is SSE
        // ("data: {json}") or a bare JSON object depending on the negotiated
        // content type, so accept either as long as it mentions a result.
        let body = String(data: data, encoding: .utf8) ?? ""
        guard body.contains("\"result\"") else {
            throw ComposioError.malformedResponse("no initialize result from the connect server")
        }
    }
}
