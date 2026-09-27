//
//  TestSupport.swift
//  ModelProviderContract
//
//  A tiny assertion harness and a fake Ollama server.
//
//  The suite talks to a local socket rather than to the real model on purpose.
//  The property that matters most here — that an accumulated callback becomes
//  each fragment exactly once — can only be asserted if the test controls
//  where the chunk boundaries fall. A live 7B model picks those boundaries
//  itself and picks different ones every run, so it can demonstrate that
//  streaming works but can never prove that nothing was duplicated.
//

import Foundation

// MARK: - Stubs

/// `LocalOllamaAPI` reads this to size `num_ctx` and `num_predict`. The real
/// `CompanionManager` drags in SwiftUI, ScreenCaptureKit and PostHog, none of
/// which this suite needs. Agent mode is the shipped setting.
enum CompanionManager {
    static var isAgentModeEnabled: Bool { true }
}

// MARK: - Assertions

final class TestResults: @unchecked Sendable {
    private(set) var passed = 0
    private(set) var failed = 0
    private var currentSection = ""

    func section(_ name: String) {
        currentSection = name
        print("\n── \(name) ──")
    }

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  PASS  \(name)")
        } else {
            failed += 1
            let extra = detail()
            print("  FAIL  \(name)\(extra.isEmpty ? "" : "\n        → \(extra)")")
        }
    }

    func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, "expected \(expected), got \(actual)")
    }

    func summarise() -> Int32 {
        print("\n\(String(repeating: "─", count: 52))")
        print("  \(passed) passed, \(failed) failed, \(passed + failed) total")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - Fake Ollama server

/// A minimal HTTP server that speaks Ollama's NDJSON streaming dialect.
///
/// Deliberately hand-rolled over POSIX sockets: the suite must run with
/// nothing installed and nothing listening, so that a failure means the
/// provider is wrong rather than that an external service moved.
final class FakeOllamaServer: @unchecked Sendable {
    /// One reply the server should stream, split exactly where the test wants.
    struct Script: Sendable {
        let chunks: [String]
        let promptTokens: Int?
        let outputTokens: Int?
        /// Pause between chunks. Only needed by the cancellation test, which
        /// must interrupt a stream that is genuinely still in flight.
        let delayBetweenChunks: TimeInterval

        init(chunks: [String], promptTokens: Int? = 1234, outputTokens: Int? = 7,
             delayBetweenChunks: TimeInterval = 0.01) {
            self.chunks = chunks
            self.promptTokens = promptTokens
            self.outputTokens = outputTokens
            self.delayBetweenChunks = delayBetweenChunks
        }
    }

    private let listeningSocket: Int32
    private let lock = NSLock()
    private var script: Script
    private var lastRequestBody: Data?

    private(set) var port: UInt16 = 0
    var baseURL: String { "http://127.0.0.1:\(port)" }

    /// The most recent request body, so a test can assert what was actually
    /// put on the wire — that an image survived translation, for instance.
    var lastRequestJSON: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let body = lastRequestBody else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    func setScript(_ newScript: Script) {
        lock.lock(); script = newScript; lock.unlock()
    }

    init(script: Script) {
        self.script = script
        listeningSocket = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(listeningSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // ephemeral: the OS picks a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(listeningSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(listeningSocket, 16)

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(listeningSocket, $0, &length)
            }
        }
        port = bound.sin_port.byteSwapped == 0 ? bound.sin_port : bound.sin_port.byteSwapped
    }

    func start() {
        Thread.detachNewThread { [weak self] in
            while let self {
                let connection = accept(self.listeningSocket, nil, nil)
                guard connection >= 0 else { return }
                // Writing to a socket the client has already closed raises
                // SIGPIPE, whose default action is to kill the process — and
                // it kills it before stdio flushes, so the suite dies having
                // printed nothing at all. The cancellation test closes its
                // connection mid-stream by design, leaving this thread partway
                // through a reply nobody is reading, so that is not a hazard
                // but the expected case. SO_NOSIGPIPE turns the doomed write
                // into the EPIPE that `send` already ignores.
                var suppressSigpipe: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigpipe,
                           socklen_t(MemoryLayout<Int32>.size))
                self.serve(connection)
            }
        }
    }

    func stop() { close(listeningSocket) }

    private func serve(_ connection: Int32) {
        // Read headers, then exactly Content-Length bytes of body.
        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let read = recv(connection, &buffer, buffer.count, 0)
            if read <= 0 { close(connection); return }
            raw.append(contentsOf: buffer[0..<read])
            headerEnd = raw.range(of: Data("\r\n\r\n".utf8))
        }
        let headerText = String(decoding: raw[..<headerEnd!.lowerBound], as: UTF8.self)
        var contentLength = 0
        for line in headerText.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        var body = raw[headerEnd!.upperBound...]
        while body.count < contentLength {
            let read = recv(connection, &buffer, buffer.count, 0)
            if read <= 0 { break }
            body.append(contentsOf: buffer[0..<read])
        }
        lock.lock(); lastRequestBody = Data(body); let current = script; lock.unlock()

        // No Content-Length on the response: the client reads until EOF, which
        // is what lets chunks arrive one at a time.
        let responseHeader = Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n".utf8)
        _ = responseHeader.withUnsafeBytes { send(connection, $0.baseAddress, responseHeader.count, 0) }

        for chunk in current.chunks {
            let payload: [String: Any] = ["message": ["role": "assistant", "content": chunk], "done": false]
            writeLine(connection, payload)
            if current.delayBetweenChunks > 0 { Thread.sleep(forTimeInterval: current.delayBetweenChunks) }
        }
        var final: [String: Any] = ["done": true]
        if let p = current.promptTokens { final["prompt_eval_count"] = p }
        if let o = current.outputTokens { final["eval_count"] = o }
        writeLine(connection, final)
        close(connection)
    }

    private func writeLine(_ connection: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)  // newline — NDJSON, one object per line
        _ = data.withUnsafeBytes { send(connection, $0.baseAddress, data.count, 0) }
    }
}
