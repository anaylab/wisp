//
//  ChromeExtensionIncomingMessage.swift
//  leanring-buddy
//
//  Reads one WebSocket frame from the Wisp Tabs extension into what it is:
//  hello, ping, a capability change, an event, or the reply to a request
//  (docs/chrome-extension/contracts.md §1). Anything else (malformed JSON, a
//  missing field, a type this build doesn't know, an oversized frame) reads as
//  nil and is dropped, the same as the bridge has always done.
//
//  Pure (Foundation only) so `Tests/ChromeExtFoundation` can test it without
//  the app. `ChromeExtensionBridge` acts on the result.
//

import Foundation

nonisolated enum ChromeExtensionIncomingMessage: Equatable {
    /// `instanceID` is the extension's per-profile id (2.0.0); older
    /// extensions send none.
    case hello(extensionVersion: String, browserName: String, capabilities: Set<ChromeExtensionCapability>, instanceID: String? = nil)
    case ping
    case capabilities(Set<ChromeExtensionCapability>)
    case event(ChromeExtensionEvent)
    case reply(requestID: Int, outcome: ReplyOutcome)

    enum ReplyOutcome: Equatable {
        /// The `result` value, re-serialised (an empty object when absent).
        case result(Data)
        /// The extension's `error` text.
        case error(String)
        /// The `result` couldn't be re-serialised. The request still gets an
        /// answer (an unreadable-reply error) instead of waiting for its timeout.
        case unreadableResult
    }

    /// The extension caps text at 20,000 characters and lists at 500 items, so
    /// a real frame is far below this. Anything larger is a bug or not the
    /// extension, and isn't worth parsing. Generous enough for a future
    /// screenshot reply (phase 03's `captureVisibleTab`).
    static let maximumFrameByteCount = 16 * 1024 * 1024

    /// The extension's instance id is a UUID; anything longer is cut.
    static let maximumInstanceIDLength = 64

    /// Event names are short `area.verb` strings; a long one isn't ours.
    static let maximumEventNameLength = 100

    /// `receivedAt` stands in for an event's time when the frame has no `at`.
    static func parse(_ frameData: Data, receivedAt: Date = Date()) -> ChromeExtensionIncomingMessage? {
        guard frameData.count <= maximumFrameByteCount,
              let message = (try? JSONSerialization.jsonObject(with: frameData)) as? [String: Any] else {
            return nil
        }

        // Typed messages first: a frame with a `type` is never a reply.
        if let messageTypeValue = message["type"] {
            guard let messageType = messageTypeValue as? String else { return nil }
            return parseTypedMessage(messageType: messageType, message: message, receivedAt: receivedAt)
        }

        return parseReply(message)
    }

    private static func parseTypedMessage(
        messageType: String,
        message: [String: Any],
        receivedAt: Date
    ) -> ChromeExtensionIncomingMessage? {
        switch messageType {
        case "hello":
            let extensionVersion = message["extensionVersion"] as? String ?? "unknown"
            let browserName = message["browserName"] as? String ?? "Chrome"
            // An extension older than 1.1.0 sends no capability list; it can
            // only do tabs.
            let capabilities: Set<ChromeExtensionCapability>
            if let wireNames = message["capabilities"] as? [String] {
                capabilities = ChromeExtensionCapability.capabilities(fromWireNames: wireNames)
            } else {
                capabilities = [.tabs]
            }
            let instanceID = (message["instanceId"] as? String).map { String($0.prefix(maximumInstanceIDLength)) }
            return .hello(extensionVersion: extensionVersion, browserName: browserName, capabilities: capabilities, instanceID: instanceID)

        case "ping":
            return .ping

        case "capabilities":
            guard let wireNames = message["capabilities"] as? [String] else { return nil }
            return .capabilities(ChromeExtensionCapability.capabilities(fromWireNames: wireNames))

        case "event":
            guard let eventName = message["event"] as? String,
                  !eventName.isEmpty,
                  eventName.count <= maximumEventNameLength else { return nil }
            // `data` is always an object on the wire; a missing one is empty.
            let payloadObject = message["data"] ?? [String: Any]()
            guard payloadObject is [String: Any],
                  let payloadJSON = try? JSONSerialization.data(withJSONObject: payloadObject) else { return nil }
            let occurredAt: Date
            if let epochMilliseconds = (message["at"] as? NSNumber)?.doubleValue, epochMilliseconds.isFinite, epochMilliseconds > 0 {
                occurredAt = Date(timeIntervalSince1970: epochMilliseconds / 1000)
            } else {
                occurredAt = receivedAt
            }
            return .event(ChromeExtensionEvent(eventName: eventName, payloadJSON: payloadJSON, occurredAt: occurredAt))

        default:
            return nil
        }
    }

    private static func parseReply(_ message: [String: Any]) -> ChromeExtensionIncomingMessage? {
        // JSONSerialization hands numbers back as NSNumber; a fractional or
        // boolean id isn't one Wisp sent.
        guard let requestIDNumber = message["id"] as? NSNumber,
              CFGetTypeID(requestIDNumber) != CFBooleanGetTypeID(),
              let requestID = Int(exactly: requestIDNumber.doubleValue) else {
            return nil
        }

        if let extensionErrorMessage = message["error"] as? String {
            return .reply(requestID: requestID, outcome: .error(extensionErrorMessage))
        }
        let resultObject = message["result"] ?? [String: Any]()
        guard let resultData = try? JSONSerialization.data(withJSONObject: resultObject, options: [.fragmentsAllowed]) else {
            return .reply(requestID: requestID, outcome: .unreadableResult)
        }
        return .reply(requestID: requestID, outcome: .result(resultData))
    }
}

/// How long one request may wait for the extension (contracts.md §1).
nonisolated enum ChromeExtensionRequestTimeout {
    /// Long enough for Chrome to group a few dozen tabs, short enough that a
    /// wedged service worker does not leave the user waiting on a spinner.
    static let defaultSeconds: Double = 10
    /// Nothing waits longer than this: a long job is many short requests.
    static let maximumSeconds: Double = 30

    /// A requested timeout, capped at 30s; nonsense (zero, negative, NaN)
    /// gets the default.
    static func clampedSeconds(_ requestedSeconds: Double) -> Double {
        guard requestedSeconds.isFinite, requestedSeconds > 0 else { return defaultSeconds }
        return min(requestedSeconds, maximumSeconds)
    }
}
