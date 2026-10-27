//
//  MCPTransport.swift
//  leanring-buddy
//
//  One bidirectional channel to an MCP server, independent of how the bytes
//  travel. A stdio transport spawns a child process and speaks over its
//  stdin/stdout; a Streamable HTTP transport POSTs to a URL and reads the
//  response stream. Both present the same surface to `MCPServerConnection`,
//  which owns every piece of JSON-RPC framing above this line — id issuing,
//  the pending-request table, timeouts, and the MCP handshake.
//
//  Splitting the transport out is what lets Wisp reach remote MCP servers
//  (Composio's hosted, managed-OAuth toolkits) without duplicating the
//  JSON-RPC machinery. Phase 0 introduces the protocol and moves the existing
//  stdio implementation behind it with no change in behavior.
//

import Foundation

/// A transport carries already-serialised JSON-RPC messages to and from one
/// MCP server. Implementations are responsible only for byte transport and the
/// framing their medium needs (a trailing newline for stdio NDJSON, an HTTP
/// request/response for Streamable HTTP). They never inspect or build JSON-RPC.
protocol MCPTransport: Sendable {
    /// Opens the channel: spawns the process or establishes the connection.
    /// Must be called before `send` or `incomingMessages`. Throws an
    /// `MCPClientError` when the server cannot be reached or started.
    func start() async throws

    /// Sends one JSON-RPC message, already serialised to JSON data. The
    /// transport applies whatever framing its medium requires.
    func send(_ messageJSON: Data) async throws

    /// The stream of incoming JSON-RPC messages, one JSON object per element as
    /// a UTF-8 string. Iterated exactly once by the owning connection. The
    /// stream finishes when the channel closes for any reason.
    func incomingMessages() async -> AsyncStream<String>

    /// Recent diagnostic lines — a stdio server's stderr, or an HTTP
    /// transport's connection errors. Often the only place a startup failure
    /// explains itself, so it is surfaced rather than discarded.
    func recentDiagnostics() async -> [String]

    /// Closes the channel and releases its resources. Safe to call more than
    /// once, including after a failed `start`.
    func close() async
}
