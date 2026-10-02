//
//  CodingAgentHookServer.swift
//  leanring-buddy
//
//  Listens on a Unix domain socket for events from the hook relay
//  (`CodingAgentHookRelay`) and hands them to `CodingAgentSessionStore`.
//
//  Local only, and only for this user: the socket lives in a 0700 folder, is
//  itself 0600, and every connection's peer UID is checked against ours, so
//  another account on the Mac can't feed Wisp events or answer a permission.
//  Payloads are capped at 1 MB, reads time out after 5s, and at most 32
//  connections are served at once.
//
//  Socket I/O happens on background threads; parsing is pure; state changes
//  hop to the main actor. A permission request's connection is held open —
//  the relay is waiting on it — until the user answers in the notch, the
//  request times out, or a newer request from the same session replaces it.
//  Adapted from Coucou's HookServer (MIT).
//

import Darwin
import Foundation

/// The reply a held permission request gets. Raw values are the relay's
/// vocabulary: "ask" means "no decision" — the relay prints nothing and
/// Claude Code asks in the terminal as it normally would.
nonisolated enum CodingAgentPermissionDecision: String, Sendable {
    case allow
    case alwaysAllow = "always"
    case deny
    case noDecision = "ask"
}

/// One held connection waiting for a permission decision. Answers exactly once;
/// later calls do nothing, so a timeout racing a click can't write twice.
nonisolated final class CodingAgentPermissionResponder: @unchecked Sendable {
    private let clientFileDescriptor: Int32
    private let answerLock = NSLock()
    private var hasAnswered = false

    init(clientFileDescriptor: Int32) {
        self.clientFileDescriptor = clientFileDescriptor
    }

    func answer(_ decision: CodingAgentPermissionDecision) {
        answerLock.lock()
        let isFirstAnswer = !hasAnswered
        hasAnswered = true
        answerLock.unlock()
        guard isFirstAnswer else { return }
        let fileDescriptor = clientFileDescriptor
        DispatchQueue.global(qos: .userInitiated).async {
            CodingAgentHookServer.sendLine(#"{"permissionDecision":"\#(decision.rawValue)"}"#, to: fileDescriptor)
            close(fileDescriptor)
        }
    }
}

nonisolated final class CodingAgentHookServer: @unchecked Sendable {
    static let shared = CodingAgentHookServer()

    private static let maximumPayloadByteCount = 1_048_576
    private static let receiveTimeoutSeconds = 5
    private static let maximumConcurrentConnections = 32

    private let stateLock = NSLock()
    private var listeningFileDescriptor: Int32 = -1
    private var openConnectionCount = 0

    /// Where parsed events go. Set once on the main actor before `start()`.
    private var eventHandler: (@MainActor @Sendable (CodingAgentHookEvent, CodingAgentPermissionResponder?) -> Void)?

    private init() {}

    var isListening: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listeningFileDescriptor >= 0
    }

    /// Installs the relay files and starts listening. Safe to call more than once.
    /// The socket path and relay install are parameters only so the test suite
    /// can run the real server on a temporary socket.
    func start(
        socketPath: String = CodingAgentHookRelay.socketURL.path,
        installsRelayFiles: Bool = true,
        eventHandler: @escaping @MainActor @Sendable (CodingAgentHookEvent, CodingAgentPermissionResponder?) -> Void
    ) {
        stateLock.lock()
        let isAlreadyListening = listeningFileDescriptor >= 0
        self.eventHandler = eventHandler
        stateLock.unlock()
        guard !isAlreadyListening else { return }

        // Writing to a socket whose relay has already hung up (a permission
        // answered after the relay gave up) must return EPIPE, not kill Wisp.
        // SO_NOSIGPIPE on the accepted socket was measured NOT to prevent
        // the signal here — the app died of SIGPIPE on the first hook event —
        // so the signal is ignored process-wide, the usual choice for a
        // socket server.
        signal(SIGPIPE, SIG_IGN)

        if installsRelayFiles {
            do {
                try CodingAgentHookRelay.installRelayFiles()
            } catch {
                print("⚠️ Coding agents: couldn't write the hook relay: \(error)")
            }
        }
        let listeningThread = Thread { [weak self] in self?.runAcceptLoop(socketPath: socketPath) }
        listeningThread.name = "Wisp coding-agent hook server"
        listeningThread.start()
    }

    // MARK: - Accepting

    private func runAcceptLoop(socketPath: String) {
        let maximumSocketPathByteCount = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard socketPath.utf8.count <= maximumSocketPathByteCount else {
            print("⚠️ Coding agents: socket path too long (\(socketPath.utf8.count) bytes): \(socketPath)")
            return
        }
        // A socket file left by a previous run would make bind fail.
        unlink(socketPath)

        let serverFileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFileDescriptor >= 0 else { return }

        var socketAddress = sockaddr_un()
        socketAddress.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &socketAddress.sun_path) { sunPathBytes in
            for (byteIndex, pathByte) in socketPath.utf8.enumerated() where byteIndex < sunPathBytes.count - 1 {
                sunPathBytes[byteIndex] = pathByte
            }
        }
        let bindResult = withUnsafePointer(to: &socketAddress) { socketAddressPointer in
            socketAddressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("⚠️ Coding agents: couldn't bind the hook socket (errno \(errno))")
            close(serverFileDescriptor)
            return
        }
        chmod(socketPath, 0o600)
        guard listen(serverFileDescriptor, 32) == 0 else {
            close(serverFileDescriptor)
            return
        }

        stateLock.lock()
        listeningFileDescriptor = serverFileDescriptor
        stateLock.unlock()

        while true {
            let clientFileDescriptor = accept(serverFileDescriptor, nil, nil)
            guard clientFileDescriptor >= 0 else {
                if errno == EINTR { continue }
                break
            }
            // Same user only.
            var peerUserID: uid_t = 0
            var peerGroupID: gid_t = 0
            guard getpeereid(clientFileDescriptor, &peerUserID, &peerGroupID) == 0, peerUserID == getuid() else {
                close(clientFileDescriptor)
                continue
            }
            stateLock.lock()
            let hasRoomForConnection = openConnectionCount < Self.maximumConcurrentConnections
            if hasRoomForConnection { openConnectionCount += 1 }
            stateLock.unlock()
            guard hasRoomForConnection else {
                close(clientFileDescriptor)
                continue
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(clientFileDescriptor)
            }
        }

        stateLock.lock()
        listeningFileDescriptor = -1
        stateLock.unlock()
    }

    // MARK: - One client

    private func handleClient(_ clientFileDescriptor: Int32) {
        defer {
            stateLock.lock()
            openConnectionCount -= 1
            stateLock.unlock()
        }
        var receiveTimeout = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(clientFileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        // Belt and braces with the process-wide SIG_IGN in `start`.
        var noSigPipe: Int32 = 1
        setsockopt(clientFileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        guard let payloadData = readOneLine(from: clientFileDescriptor),
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
            close(clientFileDescriptor)
            return
        }

        let hookEvent = CodingAgentHookEventParser.parse(payload: payload)
        stateLock.lock()
        let eventHandler = self.eventHandler
        stateLock.unlock()

        if case .permissionRequested = hookEvent.kind {
            // Held open: the relay is waiting for the decision.
            let permissionResponder = CodingAgentPermissionResponder(clientFileDescriptor: clientFileDescriptor)
            guard let eventHandler else {
                permissionResponder.answer(.noDecision)
                return
            }
            Task { @MainActor in eventHandler(hookEvent, permissionResponder) }
        } else {
            // No reply: the relay hangs up right after sending (it never
            // reads one), so writing here would only hit a closed socket.
            close(clientFileDescriptor)
            if let eventHandler {
                Task { @MainActor in eventHandler(hookEvent, nil) }
            }
        }
    }

    /// Reads up to the first newline (the relay sends exactly one JSON line).
    private func readOneLine(from clientFileDescriptor: Int32) -> Data? {
        var receivedData = Data()
        var readBuffer = [UInt8](repeating: 0, count: 4096)
        while receivedData.count <= Self.maximumPayloadByteCount {
            let receivedByteCount = recv(clientFileDescriptor, &readBuffer, readBuffer.count, 0)
            guard receivedByteCount > 0 else { break }
            if let newlineIndex = readBuffer[0..<receivedByteCount].firstIndex(of: UInt8(ascii: "\n")) {
                receivedData.append(contentsOf: readBuffer[0..<newlineIndex])
                return receivedData
            }
            receivedData.append(contentsOf: readBuffer[0..<receivedByteCount])
        }
        guard !receivedData.isEmpty, receivedData.count <= Self.maximumPayloadByteCount else { return nil }
        return receivedData
    }

    static func sendLine(_ text: String, to clientFileDescriptor: Int32) {
        let lineBytes = Array((text + "\n").utf8)
        lineBytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sentByteCount = 0
            while sentByteCount < rawBuffer.count {
                let justSentByteCount = send(clientFileDescriptor, baseAddress + sentByteCount, rawBuffer.count - sentByteCount, 0)
                if justSentByteCount <= 0 { break }
                sentByteCount += justSentByteCount
            }
        }
    }
}
