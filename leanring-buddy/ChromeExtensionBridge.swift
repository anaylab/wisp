//
//  ChromeExtensionBridge.swift
//  leanring-buddy
//
//  The connection between Wisp and the "Wisp Tabs" Chrome extension
//  (`chrome-extension/` at the repo root).
//
//  Why an extension at all: Wisp already drives Chrome through AppleScript,
//  but AppleScript cannot see or make tab groups — `chrome.tabGroups` exists
//  only for extensions. So organizing tabs needs a small extension in the
//  browser, and a way for Wisp to reach it.
//
//  Why this shape: an MV3 service worker cannot accept connections, so Wisp
//  listens and the extension dials in, over a WebSocket on the loopback
//  interface only. Two things keep that from being a door into the user's
//  tabs:
//
//  * The listener is bound to loopback, so nothing off this Mac can reach it.
//  * The WebSocket handshake is rejected unless its `Origin` is exactly this
//    extension's. Browsers set `Origin` themselves and a web page cannot forge
//    it, so a site the user visits cannot connect to localhost and pose as the
//    extension. The ID is fixed by the public key in the extension's manifest.
//
//  The protocol is a tiny JSON request/response: Wisp sends
//  `{id, method, params}`, the extension answers `{id, result}` or
//  `{id, error}`. The extension also sends `{type: "hello"}` on connect and a
//  `{type: "ping"}` every 20s to keep its service worker alive. Since 1.1.0 it
//  also sends unsolicited `{type: "event"}` frames (published on
//  `extensionEventPublisher`, never answered) and `{type: "capabilities"}`
//  whenever the user grants or removes a permission
//  (docs/chrome-extension/contracts.md). Frames are read by the pure
//  `ChromeExtensionIncomingMessage.parse`.
//

import Combine
import Foundation
import Network

@MainActor
final class ChromeExtensionBridge: ObservableObject {
    static let shared = ChromeExtensionBridge()

    /// Must match `WISP_BRIDGE_URL` in `chrome-extension/background.js`.
    nonisolated static let listeningPort: UInt16 = 47823

    /// The only origin allowed to connect. The ID is derived from the public
    /// key in `chrome-extension/manifest.json`, so it is the same on every
    /// install of the unpacked extension.
    nonisolated static let allowedExtensionID = "kpblnefdnmlodeagdnfodnbbdbkacnce"
    nonisolated static let allowedExtensionOrigin = "chrome-extension://\(allowedExtensionID)"

    /// Long enough for Chrome to group a few dozen tabs, short enough that a
    /// wedged service worker does not leave the user waiting on a spinner.
    nonisolated static let requestTimeoutSeconds: Double = ChromeExtensionRequestTimeout.defaultSeconds

    enum ConnectionState: Equatable {
        case notStarted
        /// Listening; the extension is not installed, Chrome is closed, or the
        /// service worker has not reconnected yet (it retries every 30s).
        case waitingForExtension
        case connected(extensionVersion: String, browserName: String)
        /// The port could not be opened — most likely another copy of Wisp.
        case failed(reason: String)
    }

    enum BridgeError: LocalizedError {
        case extensionNotConnected
        case timedOut(method: String)
        case extensionReportedError(String)
        case connectionClosed
        case unreadableReply

        var errorDescription: String? {
            switch self {
            case .extensionNotConnected:
                return "the wisp tabs chrome extension isn't connected. install it from the chrome-extension folder (chrome://extensions → load unpacked) and make sure chrome is open."
            case .timedOut(let method):
                return "chrome didn't answer in time (\(method))."
            case .extensionReportedError(let message):
                return "chrome said: \(message)"
            case .connectionClosed:
                return "the connection to chrome closed mid-request."
            case .unreadableReply:
                return "chrome sent back something i couldn't read."
            }
        }
    }

    @Published private(set) var connectionState: ConnectionState = .notStarted

    /// What the user has let the extension do, from its `hello` and later
    /// `capabilities` messages. Empty while no extension is connected.
    @Published private(set) var grantedCapabilities: Set<ChromeExtensionCapability> = []

    /// Every event the extension sends. Subscribers filter by `eventName`;
    /// the bridge itself knows nothing about specific events. Events are
    /// fire-and-forget and are not replayed to late subscribers.
    let extensionEventPublisher = PassthroughSubject<ChromeExtensionEvent, Never>()

    func hasCapability(_ capability: ChromeExtensionCapability) -> Bool {
        grantedCapabilities.contains(capability)
    }

    var isExtensionConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    private var listener: NWListener?
    /// At most one extension connection at a time. A newer one replaces an
    /// older one, which is what happens when Chrome restarts the service
    /// worker before the old socket has noticed it is dead.
    private var activeConnection: NWConnection?
    private var nextRequestID = 1
    private var pendingRequestsByID: [Int: PendingRequest] = [:]

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Data, Error>
    }

    private init() {}

    // MARK: - Listening

    /// Opens the loopback listener. Safe to call more than once.
    func start() {
        guard listener == nil else { return }

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        // Runs during the HTTP upgrade, before any message can be exchanged.
        webSocketOptions.setClientRequestHandler(.main) { _, requestHeaders in
            let originHeaderValue = requestHeaders.first { header in
                header.name.caseInsensitiveCompare("Origin") == .orderedSame
            }?.value
            let isAllowedOrigin = originHeaderValue == Self.allowedExtensionOrigin
            if !isAllowedOrigin {
                print("🧩 Chrome bridge: rejected a connection from origin \(originHeaderValue ?? "(none)")")
            }
            return NWProtocolWebSocket.Response(
                status: isAllowedOrigin ? .accept : .reject,
                subprotocol: nil,
                additionalHeaders: nil
            )
        }

        guard let listeningPort = NWEndpoint.Port(rawValue: Self.listeningPort) else { return }
        let listenerParameters = NWParameters.tcp
        listenerParameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        // Bound to 127.0.0.1 itself. `requiredInterfaceType = .loopback` was
        // tried first and still bound every interface (`*:47823` in lsof).
        listenerParameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: listeningPort)
        listenerParameters.allowLocalEndpointReuse = true

        let newListener: NWListener
        do {
            newListener = try NWListener(using: listenerParameters)
        } catch {
            connectionState = .failed(reason: error.localizedDescription)
            return
        }

        newListener.stateUpdateHandler = { [weak self] listenerState in
            MainActor.assumeIsolated {
                self?.handleListenerStateChange(listenerState)
            }
        }
        newListener.newConnectionHandler = { [weak self] incomingConnection in
            MainActor.assumeIsolated {
                self?.acceptExtensionConnection(incomingConnection)
            }
        }
        listener = newListener
        newListener.start(queue: .main)
    }

    private func handleListenerStateChange(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            if !isExtensionConnected {
                connectionState = .waitingForExtension
            }
        case .failed(let listenerError):
            print("🧩 Chrome bridge: listener failed — \(listenerError)")
            connectionState = .failed(reason: "port \(Self.listeningPort) is unavailable (\(listenerError.localizedDescription)). is another copy of wisp running?")
            listener?.cancel()
            listener = nil
        default:
            break
        }
    }

    private func acceptExtensionConnection(_ incomingConnection: NWConnection) {
        if let previousConnection = activeConnection {
            dropConnection(previousConnection)
        }
        activeConnection = incomingConnection

        incomingConnection.stateUpdateHandler = { [weak self, weak incomingConnection] connectionState in
            MainActor.assumeIsolated {
                guard let self, let incomingConnection else { return }
                switch connectionState {
                case .ready:
                    self.receiveNextMessage(on: incomingConnection)
                case .failed, .cancelled:
                    self.dropConnection(incomingConnection)
                default:
                    break
                }
            }
        }
        incomingConnection.start(queue: .main)
    }

    /// Forgets a connection and fails every request still waiting on it.
    private func dropConnection(_ connection: NWConnection) {
        guard connection === activeConnection else {
            connection.cancel()
            return
        }
        activeConnection = nil
        connection.stateUpdateHandler = nil
        connection.cancel()

        let orphanedRequests = pendingRequestsByID.values
        pendingRequestsByID.removeAll()
        for orphanedRequest in orphanedRequests {
            orphanedRequest.continuation.resume(throwing: BridgeError.connectionClosed)
        }

        grantedCapabilities = []
        if listener != nil {
            connectionState = .waitingForExtension
        }
    }

    // MARK: - Receiving

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] messageContent, _, _, receiveError in
            MainActor.assumeIsolated {
                guard let self, let connection, connection === self.activeConnection else { return }
                if receiveError != nil {
                    self.dropConnection(connection)
                    return
                }
                if let messageContent {
                    self.handleMessageFromExtension(messageContent)
                }
                self.receiveNextMessage(on: connection)
            }
        }
    }

    private func handleMessageFromExtension(_ messageData: Data) {
        guard let incomingMessage = ChromeExtensionIncomingMessage.parse(messageData) else { return }

        switch incomingMessage {
        case .hello(let extensionVersion, let browserName, let capabilities):
            grantedCapabilities = capabilities
            connectionState = .connected(extensionVersion: extensionVersion, browserName: browserName)
            print("🧩 Chrome bridge: extension \(extensionVersion) connected from \(browserName) — \(capabilities.map(\.rawValue).sorted())")
        case .ping:
            // Only exists to keep the service worker alive.
            break
        case .capabilities(let capabilities):
            grantedCapabilities = capabilities
        case .event(let extensionEvent):
            extensionEventPublisher.send(extensionEvent)
        case .reply(let requestID, let outcome):
            guard let pendingRequest = pendingRequestsByID.removeValue(forKey: requestID) else { return }
            switch outcome {
            case .result(let resultData):
                pendingRequest.continuation.resume(returning: resultData)
            case .error(let extensionErrorMessage):
                pendingRequest.continuation.resume(throwing: BridgeError.extensionReportedError(extensionErrorMessage))
            case .unreadableResult:
                pendingRequest.continuation.resume(throwing: BridgeError.unreadableReply)
            }
        }
    }

    // MARK: - Requests

    private struct RequestEnvelope<Parameters: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: Parameters
    }

    /// Sends one request to the extension and decodes its result.
    func sendRequest<Parameters: Encodable, Result: Decodable>(
        method: String,
        parameters: Parameters,
        resultType: Result.Type
    ) async throws -> Result {
        let request = try makeRequestFrame(method: method, parameters: parameters, timeoutSecondsForExtension: nil)
        let resultData = try await sendRequestReturningData(
            method: method,
            request: request,
            timeoutSeconds: Self.requestTimeoutSeconds
        )
        return try decodeResult(resultData, as: Result.self)
    }

    /// Sends one request that may take longer than the default 10s (a long
    /// page read, waiting for a page to settle). The wait is capped at 30s,
    /// and the same number goes to the extension as `params.timeoutSeconds`
    /// so its handler can budget its own work (contracts.md §1).
    func sendRequest<Parameters: Encodable, Result: Decodable>(
        method: String,
        parameters: Parameters,
        resultType: Result.Type,
        timeoutSeconds: Double
    ) async throws -> Result {
        let clampedTimeoutSeconds = ChromeExtensionRequestTimeout.clampedSeconds(timeoutSeconds)
        let request = try makeRequestFrame(
            method: method,
            parameters: parameters,
            timeoutSecondsForExtension: clampedTimeoutSeconds
        )
        let resultData = try await sendRequestReturningData(
            method: method,
            request: request,
            timeoutSeconds: clampedTimeoutSeconds
        )
        return try decodeResult(resultData, as: Result.self)
    }

    private func decodeResult<Result: Decodable>(_ resultData: Data, as resultType: Result.Type) throws -> Result {
        do {
            return try JSONDecoder().decode(Result.self, from: resultData)
        } catch {
            throw BridgeError.unreadableReply
        }
    }

    /// One encoded request and the id its reply will carry.
    private struct RequestFrame {
        let requestID: Int
        let frameData: Data
    }

    private func makeRequestFrame<Parameters: Encodable>(
        method: String,
        parameters: Parameters,
        timeoutSecondsForExtension: Double?
    ) throws -> RequestFrame {
        let requestID = nextRequestID
        nextRequestID += 1

        let envelopeData = try JSONEncoder().encode(RequestEnvelope(id: requestID, method: method, params: parameters))
        guard let timeoutSecondsForExtension else {
            return RequestFrame(requestID: requestID, frameData: envelopeData)
        }

        // Adds `timeoutSeconds` inside `params` without each caller's
        // parameter struct having to carry it.
        guard var envelopeObject = (try? JSONSerialization.jsonObject(with: envelopeData)) as? [String: Any] else {
            return RequestFrame(requestID: requestID, frameData: envelopeData)
        }
        var parametersObject = envelopeObject["params"] as? [String: Any] ?? [:]
        parametersObject["timeoutSeconds"] = timeoutSecondsForExtension
        envelopeObject["params"] = parametersObject
        return RequestFrame(requestID: requestID, frameData: try JSONSerialization.data(withJSONObject: envelopeObject))
    }

    private func sendRequestReturningData(
        method: String,
        request: RequestFrame,
        timeoutSeconds: Double
    ) async throws -> Data {
        let requestID = request.requestID
        guard isExtensionConnected, let connection = activeConnection else {
            throw BridgeError.extensionNotConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequestsByID[requestID] = PendingRequest(method: method, continuation: continuation)

            let textFrameMetadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let sendContext = NWConnection.ContentContext(identifier: "wisp-request", metadata: [textFrameMetadata])
            connection.send(
                content: request.frameData,
                contentContext: sendContext,
                isComplete: true,
                completion: .contentProcessed { [weak self] sendError in
                    guard sendError != nil else { return }
                    MainActor.assumeIsolated {
                        self?.failPendingRequest(requestID, with: BridgeError.connectionClosed)
                    }
                }
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                self?.failPendingRequest(requestID, with: BridgeError.timedOut(method: method))
            }
        }
    }

    /// Fails a request if it is still waiting; a no-op once it has an answer.
    private func failPendingRequest(_ requestID: Int, with requestError: Error) {
        guard let pendingRequest = pendingRequestsByID.removeValue(forKey: requestID) else { return }
        pendingRequest.continuation.resume(throwing: requestError)
    }
}
