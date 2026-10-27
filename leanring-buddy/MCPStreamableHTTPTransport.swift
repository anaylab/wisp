//
//  MCPStreamableHTTPTransport.swift
//  leanring-buddy
//
//  The remote MCP transport: speaks JSON-RPC to a hosted server over the MCP
//  "Streamable HTTP" transport. This is what lets Wisp reach servers it doesn't
//  spawn locally — notably Composio's hosted, managed-OAuth toolkits, which are
//  only reachable this way.
//
//  Streamable HTTP maps one JSON-RPC message to one HTTP POST:
//
//  * The client POSTs a single JSON-RPC message with
//    `Accept: application/json, text/event-stream`.
//  * For a request (one carrying an id), the server answers in that same POST's
//    response — either a single JSON object (`application/json`) or a
//    Server-Sent Events stream (`text/event-stream`) whose `data:` frames each
//    carry one JSON-RPC message, ending with the reply. For a notification the
//    server returns `202 Accepted` with no body.
//  * The server may issue a session id in the `Mcp-Session-Id` response header
//    on initialize; the client must echo it on every later request.
//  * As of March 2026 Composio rejects calls without a valid `x-api-key`
//    header (HTTP 401), so per-server headers are carried on every request.
//
//  Every reply the POST returns is fed into one long-lived message stream, so
//  `MCPServerConnection` matches it to the waiting request by id exactly as it
//  does for stdio — it never learns which transport carried the bytes.
//

import Foundation

/// Speaks JSON-RPC to a remote MCP server over Streamable HTTP.
///
/// An actor because the session id and diagnostics are shared mutable state.
/// Concurrent sends are fine: every `await` (the network calls, and each SSE
/// line) releases the actor, so a slow tool call does not block other requests.
actor MCPStreamableHTTPTransport: MCPTransport {
    private let endpoint: URL
    private let configuredHeaders: [String: String]
    private let urlSession: URLSession

    /// The protocol version the client declares in `initialize`. Sent on every
    /// request as `MCP-Protocol-Version`, matching what `MCPServerConnection`
    /// negotiates.
    private static let protocolVersion = "2024-11-05"

    /// Issued by the server on initialize; echoed on every later request.
    private var sessionID: String?

    /// The stream handed to the connection, and the continuation each POST
    /// response feeds. Long-lived: it spans every request until `close`.
    private var messageStream: AsyncStream<String>?
    private var messageContinuation: AsyncStream<String>.Continuation?

    /// Recent transport errors. The only place a failed handshake explains
    /// itself, so the dashboard reads it when a connection fails.
    private var diagnosticLines: [String] = []
    private static let retainedDiagnosticLineCount = 60

    init(url: URL, headers: [String: String] = [:], urlSession: URLSession = .shared) {
        self.endpoint = url
        self.configuredHeaders = headers
        self.urlSession = urlSession
    }

    // MARK: MCPTransport

    func start() async throws {
        // Nothing to connect: Streamable HTTP is request-per-POST. Just open the
        // message stream so replies have somewhere to go. Unbounded buffering so
        // a reply that arrives before the connection starts consuming is held
        // rather than dropped.
        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .unbounded
        )
        messageStream = stream
        messageContinuation = continuation
    }

    func send(_ messageJSON: Data) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = messageJSON
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        // Configured headers last so a server's required header (x-api-key,
        // Authorization) always wins.
        for (field, value) in configuredHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let responseBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (responseBytes, response) = try await urlSession.bytes(for: request)
        } catch {
            appendDiagnostic("request failed: \(error.localizedDescription)")
            throw MCPClientError.serverError("couldn't reach the server: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            appendDiagnostic("response was not HTTP")
            throw MCPClientError.serverError("the server gave a non-HTTP response.")
        }

        // Capture (but never clear) the session id the server assigns on
        // initialize, so every later request carries it.
        if let assignedSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id"),
           !assignedSessionID.isEmpty {
            sessionID = assignedSessionID
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodySnippet = try? await Self.collectString(from: responseBytes, limit: 500)
            let reason = Self.describeFailure(status: httpResponse.statusCode, body: bodySnippet)
            appendDiagnostic("HTTP \(httpResponse.statusCode): \(bodySnippet ?? "")")
            throw MCPClientError.serverError(reason)
        }

        // 202 Accepted is the response to a notification: nothing to read.
        if httpResponse.statusCode == 202 { return }

        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            try await pumpEventStream(responseBytes)
        } else {
            // A single JSON-RPC message as the whole body.
            let body = try await Self.collectString(from: responseBytes, limit: nil)
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                messageContinuation?.yield(trimmed)
            }
        }
    }

    func incomingMessages() -> AsyncStream<String> {
        messageStream ?? AsyncStream { $0.finish() }
    }

    func recentDiagnostics() -> [String] {
        diagnosticLines
    }

    func close() {
        messageContinuation?.finish()
        messageContinuation = nil
    }

    // MARK: SSE

    /// Reads a Server-Sent Events body, yielding each event's `data` payload as
    /// one JSON-RPC message. Multi-line `data:` fields are joined with newlines,
    /// per the SSE spec; other fields (event, id, retry, comments) are ignored.
    private func pumpEventStream(_ responseBytes: URLSession.AsyncBytes) async throws {
        var dataLines: [String] = []

        func dispatchPendingEvent() {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                messageContinuation?.yield(trimmed)
            }
        }

        do {
            for try await line in responseBytes.lines {
                if line.isEmpty {
                    // A blank line terminates an event.
                    dispatchPendingEvent()
                    continue
                }
                if line.hasPrefix(":") {
                    // A comment / keep-alive.
                    continue
                }
                if line.hasPrefix("data:") {
                    let value = line.dropFirst("data:".count)
                    // One optional leading space after the colon is stripped.
                    dataLines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : String(value))
                }
                // event:, id:, retry: are not needed by a tools-only client.
            }
        } catch {
            appendDiagnostic("event stream ended early: \(error.localizedDescription)")
            throw MCPClientError.serverError("the server's response stream failed: \(error.localizedDescription)")
        }

        // A stream that ends without a trailing blank line still has a final
        // event to deliver.
        dispatchPendingEvent()
    }

    // MARK: Helpers

    private static func collectString(from responseBytes: URLSession.AsyncBytes, limit: Int?) async throws -> String {
        var data = Data()
        for try await byte in responseBytes {
            data.append(byte)
            if let limit, data.count >= limit { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func describeFailure(status: Int, body: String?) -> String {
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch status {
        case 401:
            return "the server rejected the request (401). check the API key / auth header."
        case 403:
            return "the server refused access (403)."
        case 404:
            return "the server endpoint or session wasn't found (404)."
        default:
            let suffix = trimmedBody.isEmpty ? "" : " — \(trimmedBody)"
            return "the server returned HTTP \(status)\(suffix)."
        }
    }

    private func appendDiagnostic(_ line: String) {
        diagnosticLines.append(line)
        if diagnosticLines.count > Self.retainedDiagnosticLineCount {
            diagnosticLines.removeFirst(diagnosticLines.count - Self.retainedDiagnosticLineCount)
        }
    }
}
