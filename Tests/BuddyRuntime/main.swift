//
//  Buddy runtime suite: which conversation a run belongs to, the part of a
//  request a kept Claude Code session hasn't seen, missing-session detection,
//  and the session store's file (round trip, 0600, forgetting).
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

func texts(_ messages: [BuddyChatMessage]) -> [String] { messages.map(\.combinedText) }

// MARK: Conversation ids

let threadID = UUID()
let groupID = UUID()
check(BuddySessionPolicy.conversationID(threadID: nil, groupID: nil) == nil, "a main-thread run has no conversation id")
check(BuddySessionPolicy.conversationID(threadID: threadID, groupID: nil) == threadID, "a side-thread run is keyed by its thread")
check(BuddySessionPolicy.conversationID(threadID: nil, groupID: groupID) == groupID, "a group run is keyed by its group")
check(BuddySessionPolicy.conversationID(threadID: threadID, groupID: groupID) == groupID, "a group wins over a thread")

// MARK: What a kept session is sent

let firstPass = [
    BuddyChatMessage(role: .user, text: "earlier question"),
    BuddyChatMessage(role: .assistant, text: "earlier answer"),
    BuddyChatMessage(role: .user, text: "new question"),
]
check(texts(BuddySessionPolicy.messagesNotYetInSession(firstPass)) == ["new question"],
      "on a run's first pass only the new message is sent; the history is already in the session")

let laterPass = firstPass + [
    BuddyChatMessage(role: .assistant, blocks: [.text("checking"), .toolUse(id: "t1", name: "get_current_time", input: .object([:]))]),
    BuddyChatMessage(role: .user, blocks: [.toolResult(toolUseID: "t1", toolName: "get_current_time", content: "3pm", isError: false)]),
]
let laterPassDelta = BuddySessionPolicy.messagesNotYetInSession(laterPass)
check(laterPassDelta.count == 1 && laterPassDelta[0].combinedText.isEmpty && !laterPassDelta[0].blocks.isEmpty, "on a later pass only the tool results are sent")

let noHistory = [BuddyChatMessage(role: .user, text: "hello")]
check(texts(BuddySessionPolicy.messagesNotYetInSession(noHistory)) == ["hello"], "a request with no assistant message is all new")
check(BuddySessionPolicy.messagesNotYetInSession([BuddyChatMessage(role: .user, text: "q"), BuddyChatMessage(role: .assistant, text: "a")]).isEmpty,
      "a request ending on an assistant message has nothing new")
check(BuddySessionPolicy.messagesNotYetInSession([]).isEmpty, "an empty request has nothing new")

let nudge = laterPass + [
    BuddyChatMessage(role: .assistant, text: "[TOOL:broken"),
    BuddyChatMessage(role: .user, text: "that tool call was malformed"),
    BuddyChatMessage(role: .user, text: "second note"),
]
check(texts(BuddySessionPolicy.messagesNotYetInSession(nudge)) == ["that tool call was malformed", "second note"],
      "every message after the last reply is sent, in order")

// MARK: Missing sessions

check(BuddySessionPolicy.isMissingSessionFailure("No conversation found with session ID: ebbfda4c-9bb8-4ca1-8adf-1ca7844f3042"),
      "the CLI's wording for a gone session is recognised (measured, Claude Code 2.1.296)")
check(BuddySessionPolicy.isMissingSessionFailure("error: Session not found"), "other wording for a gone session is recognised")
check(!BuddySessionPolicy.isMissingSessionFailure("Not logged in · Please run /login"), "a sign-in failure is not a gone session")
check(!BuddySessionPolicy.isMissingSessionFailure("Claude usage limit reached"), "a usage limit is not a gone session")

// MARK: Runtime kind

check(!BuddyRuntimeKind.wispLoop.sendsDataOffThisMachine, "Wisp's own loop doesn't itself leave the Mac")
check(BuddyRuntimeKind.claudeCodeSession.sendsDataOffThisMachine, "a Claude Code session leaves the Mac")
let oldBuddyJSON = Data(#"{"kind":null}"#.utf8)
nonisolated struct RuntimeHolder: Codable { var kind: BuddyRuntimeKind? }
check((try? JSONDecoder().decode(RuntimeHolder.self, from: oldBuddyJSON))?.kind == nil, "a missing runtime decodes as nil (Wisp's loop)")
check((try? JSONDecoder().decode(RuntimeHolder.self, from: Data(#"{"kind":"claudeCodeSession"}"#.utf8)))?.kind == .claudeCodeSession,
      "the stored name round-trips")

// MARK: Session store

let buildDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
let storeFileURL = URL(fileURLWithPath: buildDirectory).appendingPathComponent("store/buddy-sessions.json")
nonisolated final class ForgottenIDs: @unchecked Sendable {
    var ids: [UUID] = []
}
let forgotten = ForgottenIDs()
let store = BuddySessionStore(fileURL: storeFileURL, removeForgottenSessionFiles: { forgotten.ids += $0 })

let buddy = UUID()
let otherBuddy = UUID()
let mainKey = BuddySessionKey(buddyID: buddy, conversationID: nil)
let threadKey = BuddySessionKey(buddyID: buddy, conversationID: threadID)
let otherKey = BuddySessionKey(buddyID: otherBuddy, conversationID: nil)
let mainSession = UUID()
let threadSession = UUID()
let otherSession = UUID()

check(store.record(for: mainKey) == nil, "a new store has no sessions")
store.noteAnsweredCall(in: mainKey, sessionID: mainSession)
store.noteAnsweredCall(in: mainKey, sessionID: mainSession)
store.noteAnsweredCall(in: threadKey, sessionID: threadSession)
store.noteAnsweredCall(in: otherKey, sessionID: otherSession)
check(store.record(for: mainKey)?.answeredCallCount == 2, "each answered call is counted")
check(store.record(for: threadKey)?.sessionID == threadSession, "a side thread has its own session")

let replacementSession = UUID()
store.noteAnsweredCall(in: mainKey, sessionID: replacementSession)
check(store.record(for: mainKey)?.sessionID == replacementSession && store.record(for: mainKey)?.answeredCallCount == 1,
      "a replacement session starts its own record")

let permissions = (try? FileManager.default.attributesOfItem(atPath: storeFileURL.path))?[.posixPermissions] as? Int
check(permissions == 0o600, "the store file is private (0600)")

let reloadedStore = BuddySessionStore(fileURL: storeFileURL, removeForgottenSessionFiles: { _ in })
check(reloadedStore.record(for: threadKey)?.sessionID == threadSession, "sessions survive a relaunch")
check(reloadedStore.records(ofBuddyWithID: buddy).count == 2, "a buddy's sessions are listed together")

store.forgetSession(for: threadKey)
check(store.record(for: threadKey) == nil, "a forgotten thread session is gone")
check(forgotten.ids == [threadSession], "forgetting a session removes its CLI file")
store.forgetSession(for: threadKey)
check(forgotten.ids == [threadSession], "forgetting nothing removes nothing")

store.forgetSessions(ofBuddyWithID: buddy)
check(store.records(ofBuddyWithID: buddy).isEmpty, "forgetting a buddy drops all its sessions")
check(store.record(for: otherKey)?.sessionID == otherSession, "another buddy's session is untouched")
check(forgotten.ids == [threadSession, replacementSession], "the buddy's session files go too")
check(BuddySessionStore(fileURL: storeFileURL, removeForgottenSessionFiles: { _ in }).record(for: mainKey) == nil,
      "forgetting is saved")

// MARK: Workspace

let workspaceBuddy = UUID()
let workspaceURL = BuddyWorkspace.folderURL(forBuddyWithID: workspaceBuddy)
check(workspaceURL.path.hasSuffix("Wisp/buddy-workspaces/\(workspaceBuddy.uuidString)"), "each buddy has its own workspace folder")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
