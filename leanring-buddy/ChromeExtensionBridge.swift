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
//  Several Chromium browsers can run the extension at once (Arc, Brave, Edge,
//  Vivaldi, Chrome's channels: same unpacked extension, same ID). The bridge
//  keeps one connection per browser, named by the app that owns the socket
//  (`ChromeExtensionPeerProcess`), and talks to one of them at a time, the
//  *active browser* (`ChromiumBrowserRouting`): requests go to it, only its
//  events are published, and `connectionState` / `grantedCapabilities`
//  describe it. Features written for one browser keep working unchanged. When
//  the active browser changes, `connectionState` passes through
//  `.waitingForExtension`, so anything that re-reads the extension's state on
//  connect re-reads the new browser's. Work that holds Chrome tab ids (a task
//  tab, research tabs, focus mode, page watches) holds the active browser with
//  `setActiveBrowserHeld(_:by:)`, because a tab id from one browser names a
//  different tab in another.
//

import AppKit
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

    /// The active browser's connection, or why there is none.
    @Published private(set) var connectionState: ConnectionState = .notStarted

    /// One browser running the extension and connected to Wisp.
    struct ConnectedBrowser: Identifiable, Equatable {
        /// The owning app's bundle identifier (or "name:<brand>" when the
        /// owner couldn't be found) plus the profile's instance id
        /// (`ChromiumBrowserCatalog.browserID`).
        let id: String
        let browserName: String
        let bundleIdentifier: String?
        /// What the extension's `hello` called itself, kept for name matching
        /// when `bundleIdentifier` is unknown.
        let helloBrowserName: String
        let extensionVersion: String
        var capabilities: Set<ChromeExtensionCapability>
        /// Lower connected earlier.
        let connectionOrder: Int
    }

    /// Every browser connected right now, in connection order.
    @Published private(set) var connectedBrowsers: [ConnectedBrowser] = []

    /// The browser requests go to (`ConnectedBrowser.id`), nil when none.
    @Published private(set) var activeBrowserID: String?

    var activeBrowser: ConnectedBrowser? {
        connectedBrowsers.first { $0.id == activeBrowserID }
    }

    /// Whether the active browser is the app with this bundle identifier, so
    /// "this tab" can be read from it. False when the owner of the
    /// connection is unknown and its brand name doesn't vouch for the app.
    func isActiveBrowser(bundleIdentifier: String) -> Bool {
        guard let activeBrowser else { return false }
        return Self.routingSummary(for: activeBrowser).isBrowser(withBundleIdentifier: bundleIdentifier)
    }

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

    /// One open socket and, once its `hello` has been read and its owner
    /// found, the browser it belongs to.
    private final class ExtensionLink {
        let connection: NWConnection
        var connectedBrowser: ConnectedBrowser?
        /// A `capabilities` message that arrived while the owner was still
        /// being looked up.
        var capabilitiesReceivedBeforeIdentified: Set<ChromeExtensionCapability>?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// Every open socket. A newer socket from the same browser replaces the
    /// older one, which is what happens when Chrome restarts the service
    /// worker before the old socket has noticed it is dead.
    private var linksByConnectionID: [ObjectIdentifier: ExtensionLink] = [:]
    private var nextConnectionOrder = 0
    private var nextRequestID = 1
    private var pendingRequestsByID: [Int: PendingRequest] = [:]
    /// Names of the work currently holding the active browser in place.
    private var activeBrowserHolderNames: Set<String> = []
    private var frontmostApplicationSubscription: AnyCancellable?

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Data, Error>
        /// The socket the request went out on; only that socket closing fails it.
        let connectionID: ObjectIdentifier
    }

    private init() {}

    // MARK: - The active browser

    /// Keeps the active browser where it is while `holderName`'s work is
    /// going, or lets it follow the user again once nothing holds it.
    func setActiveBrowserHeld(_ isHeld: Bool, by holderName: String) {
        if isHeld {
            activeBrowserHolderNames.insert(holderName)
        } else if activeBrowserHolderNames.remove(holderName) != nil, activeBrowserHolderNames.isEmpty {
            refreshActiveBrowser()
        }
    }

    private static func routingSummary(for connectedBrowser: ConnectedBrowser) -> ChromiumBrowserConnectionSummary {
        ChromiumBrowserConnectionSummary(
            browserID: connectedBrowser.id,
            bundleIdentifier: connectedBrowser.bundleIdentifier,
            helloBrowserName: connectedBrowser.helloBrowserName,
            connectionOrder: connectedBrowser.connectionOrder
        )
    }

    /// Re-picks the active browser and republishes what describes it.
    private func refreshActiveBrowser() {
        let identifiedLinks = linksByConnectionID.values.filter { $0.connectedBrowser != nil }
        let newConnectedBrowsers = identifiedLinks
            .compactMap(\.connectedBrowser)
            .sorted { $0.connectionOrder < $1.connectionOrder }
        if newConnectedBrowsers != connectedBrowsers {
            connectedBrowsers = newConnectedBrowsers
        }

        let newActiveBrowserID = ChromiumBrowserRouting.activeBrowserID(ChromiumBrowserRoutingInputs(
            connectedBrowsers: newConnectedBrowsers.map(Self.routingSummary(for:)),
            frontmostBundleIdentifier: FrontmostAppTracker.shared.lastExternalApplication?.bundleIdentifier,
            currentActiveBrowserID: activeBrowserID,
            isActiveBrowserHeld: !activeBrowserHolderNames.isEmpty
        ))
        let activeBrowserChanged = newActiveBrowserID != activeBrowserID
        if activeBrowserChanged {
            if let previousActiveBrowserID = activeBrowserID, newActiveBrowserID != nil {
                // Passing through "waiting" makes everything that re-reads
                // the extension's state on connect re-read the new browser's.
                print("🧩 Chrome bridge: switching from \(previousActiveBrowserID) to \(newActiveBrowserID ?? "none")")
                grantedCapabilities = []
                connectionState = .waitingForExtension
            }
            activeBrowserID = newActiveBrowserID
        }

        let newActiveBrowser = newConnectedBrowsers.first { $0.id == newActiveBrowserID }
        let newGrantedCapabilities = newActiveBrowser?.capabilities ?? []
        if newGrantedCapabilities != grantedCapabilities {
            grantedCapabilities = newGrantedCapabilities
        }
        let newConnectionState: ConnectionState
        if let newActiveBrowser {
            newConnectionState = .connected(extensionVersion: newActiveBrowser.extensionVersion, browserName: newActiveBrowser.browserName)
        } else if listener != nil {
            newConnectionState = .waitingForExtension
        } else {
            newConnectionState = connectionState
        }
        if newConnectionState != connectionState {
            connectionState = newConnectionState
        }
    }

    // MARK: - Listening

    /// Opens the loopback listener. Safe to call more than once.
    func start() {
        guard listener == nil else { return }

        // The active browser follows the user between connected browsers.
        frontmostApplicationSubscription = FrontmostAppTracker.shared.$lastExternalApplication
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshActiveBrowser()
                }
            }

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
            refreshActiveBrowser()
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
        let link = ExtensionLink(connection: incomingConnection)
        linksByConnectionID[ObjectIdentifier(incomingConnection)] = link

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

    /// Forgets a socket and fails every request still waiting on it.
    private func dropConnection(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        guard linksByConnectionID.removeValue(forKey: connectionID) != nil else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()

        let orphanedRequestIDs = pendingRequestsByID.filter { $0.value.connectionID == connectionID }.map(\.key)
        for orphanedRequestID in orphanedRequestIDs {
            pendingRequestsByID.removeValue(forKey: orphanedRequestID)?.continuation.resume(throwing: BridgeError.connectionClosed)
        }

        refreshActiveBrowser()
    }

    /// Finds the app behind a socket whose `hello` just arrived, then lists it
    /// as a connected browser, replacing an older socket from the same app.
    private func identifyBrowser(
        on connection: NWConnection,
        extensionVersion: String,
        helloBrowserName: String,
        instanceID: String?,
        capabilities: Set<ChromeExtensionCapability>
    ) {
        var peerPort: UInt16?
        if case .hostPort(_, let remotePort) = connection.endpoint {
            peerPort = remotePort.rawValue
        }
        Task { @MainActor [weak self] in
            var peerApplication: ChromeExtensionPeerApplication?
            if let peerPort {
                peerApplication = await ChromeExtensionPeerProcess.owningApplication(peerPort: peerPort, listeningPort: Self.listeningPort)
            }
            guard let self, let link = self.linksByConnectionID[ObjectIdentifier(connection)] else { return }

            let browserID = ChromiumBrowserCatalog.browserID(
                bundleIdentifier: peerApplication?.bundleIdentifier,
                helloBrowserName: helloBrowserName,
                instanceID: instanceID
            )
            let browserName = ChromiumBrowserCatalog.displayName(
                bundleIdentifier: peerApplication?.bundleIdentifier,
                applicationName: peerApplication?.applicationName,
                helloBrowserName: helloBrowserName
            )
            for olderLink in self.linksByConnectionID.values
            where olderLink !== link && olderLink.connectedBrowser?.id == browserID {
                self.dropConnection(olderLink.connection)
            }

            self.nextConnectionOrder += 1
            link.connectedBrowser = ConnectedBrowser(
                id: browserID,
                browserName: browserName,
                bundleIdentifier: peerApplication?.bundleIdentifier,
                helloBrowserName: helloBrowserName,
                extensionVersion: extensionVersion,
                capabilities: link.capabilitiesReceivedBeforeIdentified ?? capabilities,
                connectionOrder: self.nextConnectionOrder
            )
            link.capabilitiesReceivedBeforeIdentified = nil
            print("🧩 Chrome bridge: extension \(extensionVersion) connected from \(browserName) (\(browserID)) — \(capabilities.map(\.rawValue).sorted())")
            self.refreshActiveBrowser()
        }
    }

    // MARK: - Receiving

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] messageContent, _, _, receiveError in
            MainActor.assumeIsolated {
                guard let self, let connection, let link = self.linksByConnectionID[ObjectIdentifier(connection)] else { return }
                if receiveError != nil {
                    self.dropConnection(connection)
                    return
                }
                if let messageContent {
                    self.handleMessage(messageContent, from: link)
                }
                self.receiveNextMessage(on: connection)
            }
        }
    }

    private func handleMessage(_ messageData: Data, from link: ExtensionLink) {
        guard let incomingMessage = ChromeExtensionIncomingMessage.parse(messageData) else { return }

        switch incomingMessage {
        case .hello(let extensionVersion, let browserName, let capabilities, let instanceID):
            guard link.connectedBrowser == nil else { return }
            identifyBrowser(
                on: link.connection,
                extensionVersion: extensionVersion,
                helloBrowserName: browserName,
                instanceID: instanceID,
                capabilities: capabilities
            )
        case .ping:
            // Only exists to keep the service worker alive.
            break
        case .capabilities(let capabilities):
            if link.connectedBrowser != nil {
                link.connectedBrowser?.capabilities = capabilities
                refreshActiveBrowser()
            } else {
                link.capabilitiesReceivedBeforeIdentified = capabilities
            }
        case .event(let extensionEvent):
            // Only the active browser's events: features keep Chrome tab ids,
            // and another browser's tab 12 is a different tab.
            guard let connectedBrowser = link.connectedBrowser, connectedBrowser.id == activeBrowserID else { return }
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

    /// Sends one request to a particular connected browser rather than the
    /// active one. Only for things about that browser itself, such as opening
    /// its permissions page from the Settings card; anything carrying a tab
    /// id goes to the active browser.
    func sendRequest<Parameters: Encodable, Result: Decodable>(
        method: String,
        parameters: Parameters,
        resultType: Result.Type,
        toBrowserWithID browserID: String
    ) async throws -> Result {
        let request = try makeRequestFrame(method: method, parameters: parameters, timeoutSecondsForExtension: nil)
        let resultData = try await sendRequestReturningData(
            method: method,
            request: request,
            timeoutSeconds: Self.requestTimeoutSeconds,
            browserID: browserID
        )
        return try decodeResult(resultData, as: Result.self)
    }

    /// Brings a connected browser's app to the front (the active one when no
    /// id is given), so a page the extension just opened is seen. Falls back
    /// to Google Chrome when the browser's app isn't known.
    func bringBrowserForward(browserID: String? = nil) {
        let browser = connectedBrowsers.first { $0.id == (browserID ?? activeBrowserID) }
        let bundleIdentifier = browser?.bundleIdentifier ?? ChromiumBrowserCatalog.googleChromeBundleIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.activate()
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
        timeoutSeconds: Double,
        browserID requestedBrowserID: String? = nil
    ) async throws -> Data {
        let requestID = request.requestID
        guard let targetBrowserID = requestedBrowserID ?? activeBrowserID,
              let targetLink = linksByConnectionID.values.first(where: { $0.connectedBrowser?.id == targetBrowserID }) else {
            throw BridgeError.extensionNotConnected
        }
        let connection = targetLink.connection

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequestsByID[requestID] = PendingRequest(
                method: method,
                continuation: continuation,
                connectionID: ObjectIdentifier(connection)
            )

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
