//
//  Chrome extension foundation suite: reading the extension's frames
//  (hello / ping / capabilities / event / reply), decoding event payloads,
//  capability names, and the request-timeout cap.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

let fixedReceiveDate = Date(timeIntervalSince1970: 1_000)

func parse(_ frameText: String) -> ChromeExtensionIncomingMessage? {
    ChromeExtensionIncomingMessage.parse(Data(frameText.utf8), receivedAt: fixedReceiveDate)
}

func jsonObject(_ data: Data) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

// MARK: - Hello

check(
    parse(#"{"type":"hello","extensionVersion":"1.1.0","browserName":"Chrome","capabilities":["tabs","pages.read"]}"#)
        == .hello(extensionVersion: "1.1.0", browserName: "Chrome", capabilities: [.tabs, .pagesRead]),
    "hello with capabilities"
)
check(
    parse(#"{"type":"hello","extensionVersion":"1.0.0","browserName":"Brave"}"#)
        == .hello(extensionVersion: "1.0.0", browserName: "Brave", capabilities: [.tabs]),
    "a 1.0.0 hello without capabilities can do tabs"
)
check(
    parse(#"{"type":"hello"}"#) == .hello(extensionVersion: "unknown", browserName: "Chrome", capabilities: [.tabs]),
    "hello with every field missing still connects, like before"
)
check(
    parse(#"{"type":"hello","capabilities":["tabs","downloads","teleport"]}"#)
        == .hello(extensionVersion: "unknown", browserName: "Chrome", capabilities: [.tabs, .downloads]),
    "unknown capability names from a newer extension are ignored"
)

// MARK: - Ping and capabilities

check(parse(#"{"type":"ping"}"#) == .ping, "ping")
check(parse(#"{"type":"capabilities","capabilities":["tabs","downloads"]}"#) == .capabilities([.tabs, .downloads]), "capabilities")
check(parse(#"{"type":"capabilities","capabilities":[]}"#) == .capabilities([]), "empty capabilities")
check(parse(#"{"type":"capabilities"}"#) == nil, "capabilities without a list is dropped")
check(parse(#"{"type":"capabilities","capabilities":"tabs"}"#) == nil, "capabilities that aren't a list are dropped")

// MARK: - Events

if case .event(let tabUpdatedEvent)? = parse(
    #"{"type":"event","event":"tab.updated","data":{"id":5,"windowId":1,"title":"B","url":"https://b.example","status":"complete","changedFields":["title"]},"at":1700000000123}"#
) {
    check(tabUpdatedEvent.eventName == "tab.updated", "event name")
    check(abs(tabUpdatedEvent.occurredAt.timeIntervalSince1970 - 1_700_000_000.123) < 0.0001, "event time from epoch ms")
    let tabPayload = tabUpdatedEvent.decodePayload(as: ChromeExtensionTabEventPayload.self)
    check(tabPayload?.id == 5 && tabPayload?.windowId == 1, "tab payload ids")
    check(tabPayload?.title == "B" && tabPayload?.status == "complete", "tab payload fields")
    check(tabPayload?.changedFields == ["title"], "tab payload changed fields")

    struct WrongShape: Decodable { let somethingElse: String }
    check(tabUpdatedEvent.decodePayload(as: WrongShape.self) == nil, "decoding into the wrong shape is nil, not a crash")
} else {
    check(false, "a tab.updated event parses")
}

if case .event(let eventWithoutDataOrTime)? = parse(#"{"type":"event","event":"window.focused"}"#) {
    check(jsonObject(eventWithoutDataOrTime.payloadJSON) == [:], "missing data is an empty object")
    check(eventWithoutDataOrTime.occurredAt == fixedReceiveDate, "missing time falls back to when it arrived")
} else {
    check(false, "an event without data or time still parses")
}

if case .event(let focusLostEvent)? = parse(#"{"type":"event","event":"window.focused","data":{"focusedWindowId":null},"at":"soon"}"#) {
    check(jsonObject(focusLostEvent.payloadJSON)?["focusedWindowId"] is NSNull, "null values survive")
    check(focusLostEvent.occurredAt == fixedReceiveDate, "a non-numeric time falls back to when it arrived")
} else {
    check(false, "an event with a null field parses")
}

check(parse(#"{"type":"event","data":{}}"#) == nil, "event without a name is dropped")
check(parse(#"{"type":"event","event":"","data":{}}"#) == nil, "event with an empty name is dropped")
check(parse(#"{"type":"event","event":42}"#) == nil, "event with a numeric name is dropped")
check(parse(#"{"type":"event","event":"tab.updated","data":[1,2]}"#) == nil, "event whose data isn't an object is dropped")
check(parse(#"{"type":"event","event":"tab.updated","data":"text"}"#) == nil, "event whose data is a string is dropped")
let overlongEventName = String(repeating: "a", count: ChromeExtensionIncomingMessage.maximumEventNameLength + 1)
check(parse(#"{"type":"event","event":"\#(overlongEventName)"}"#) == nil, "event with an overlong name is dropped")

// MARK: - Replies

if case .reply(let requestID, .result(let resultData))? = parse(#"{"id":7,"result":{"groupId":3}}"#) {
    check(requestID == 7, "reply id")
    check(jsonObject(resultData) == ["groupId": 3], "reply result")
} else {
    check(false, "a result reply parses")
}
if case .reply(_, .result(let emptyResultData))? = parse(#"{"id":8}"#) {
    check(jsonObject(emptyResultData) == [:], "a reply without result is an empty object, like before")
} else {
    check(false, "a reply without result parses")
}
if case .reply(_, .result(let arrayResultData))? = parse(#"{"id":9,"result":[1,2]}"#) {
    check(((try? JSONSerialization.jsonObject(with: arrayResultData)) as? [Int]) == [1, 2], "array results pass through")
} else {
    check(false, "an array result parses")
}
check(parse(#"{"id":10,"error":"tabIds must be a non-empty list of tab ids"}"#)
      == .reply(requestID: 10, outcome: .error("tabIds must be a non-empty list of tab ids")), "error reply")
check(parse(#"{"id":11,"error":"boom","result":{}}"#) == .reply(requestID: 11, outcome: .error("boom")), "error wins over result")
check(parse(#"{"id":"7","result":{}}"#) == nil, "string id is dropped")
check(parse(#"{"id":7.5,"result":{}}"#) == nil, "fractional id is dropped")
check(parse(#"{"id":true,"result":{}}"#) == nil, "boolean id is dropped")
check(parse(#"{"result":{}}"#) == nil, "reply without an id is dropped")

// MARK: - Malformed, unknown and oversized frames

check(parse("") == nil, "empty frame")
check(parse("{not json") == nil, "malformed JSON")
check(parse("[1,2,3]") == nil, "a top-level array")
check(parse("null") == nil, "null")
check(parse(#""hello""#) == nil, "a bare string")
check(parse(#"{"type":"teleport"}"#) == nil, "unknown type")
check(parse(#"{"type":7}"#) == nil, "non-string type")
check(parse(#"{"type":"hello","id":3,"result":{}}"#) != nil && {
    if case .hello? = parse(#"{"type":"hello","id":3,"result":{}}"#) { return true }
    return false
}(), "a typed frame is never read as a reply")

let oversizedText = String(repeating: "x", count: ChromeExtensionIncomingMessage.maximumFrameByteCount)
check(parse(#"{"type":"event","event":"tab.updated","data":{"title":"\#(oversizedText)"}}"#) == nil, "oversized frame is dropped")
let justUnderLimitText = String(repeating: "x", count: 1_000_000)
check(parse(#"{"type":"event","event":"tab.updated","data":{"title":"\#(justUnderLimitText)"}}"#) != nil, "a 1 MB frame is fine")

// MARK: - Capabilities and timeouts

check(ChromeExtensionCapability.allCases.map(\.rawValue) == ["tabs", "pages.read", "downloads"], "wire names match contracts §3")
check(ChromeExtensionCapability.capabilities(fromWireNames: ["pages.read", "pages.read"]) == [.pagesRead], "duplicates collapse")
check(ChromeExtensionCapability.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.whatItAllows.isEmpty }, "every capability has copy")

check(ChromeExtensionRequestTimeout.clampedSeconds(20) == 20, "20s is allowed")
check(ChromeExtensionRequestTimeout.clampedSeconds(30) == 30, "30s is the cap")
check(ChromeExtensionRequestTimeout.clampedSeconds(120) == 30, "longer is capped at 30s")
check(ChromeExtensionRequestTimeout.clampedSeconds(0) == 10, "zero gets the default")
check(ChromeExtensionRequestTimeout.clampedSeconds(-5) == 10, "negative gets the default")
check(ChromeExtensionRequestTimeout.clampedSeconds(.nan) == 10, "NaN gets the default")
check(ChromeExtensionRequestTimeout.clampedSeconds(.infinity) == 10, "infinity gets the default")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
