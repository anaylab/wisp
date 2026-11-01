//
//  Group chat suite: routing, handoff, shared history, transcript.
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

let mia = BuddyGroupMember(id: UUID(), name: "Mia")
let gmailDigest = BuddyGroupMember(id: UUID(), name: "Gmail Digest")
let gmail = BuddyGroupMember(id: UUID(), name: "Gmail")
let sam = BuddyGroupMember(id: UUID(), name: "Sam")
let members = [mia, gmail, gmailDigest, sam]

// MARK: - Routing

let addressed = BuddyGroupPolicy.route(userText: "@sam, what's new?", members: members, leadID: mia.id, lastOwnerID: mia.id)
check(addressed?.ownerID == sam.id && addressed?.reason == .addressed, "@Name picks that member, case-insensitively")
check(addressed?.text == "what's new?", "the address is removed from the request")
check(BuddyGroupPolicy.route(userText: "@Gmail Digest summarize", members: members, leadID: nil, lastOwnerID: nil)?.ownerID == gmailDigest.id,
      "the longest matching name wins")
check(BuddyGroupPolicy.route(userText: "@Gmail summarize", members: members, leadID: nil, lastOwnerID: nil)?.ownerID == gmail.id,
      "a shorter name still matches when the longer one doesn't")
check(BuddyGroupPolicy.route(userText: "@Miami hello", members: members, leadID: sam.id, lastOwnerID: nil)?.reason == .lead,
      "@Miami is not Mia: the name must end at a word boundary")
check(BuddyGroupPolicy.route(userText: "@Mia", members: members, leadID: nil, lastOwnerID: nil)?.text == "@Mia",
      "an address with nothing after it keeps the whole message as the request")
let continued = BuddyGroupPolicy.route(userText: "and tomorrow?", members: members, leadID: mia.id, lastOwnerID: sam.id)
check(continued?.ownerID == sam.id && continued?.reason == .continuedConversation, "an unaddressed message continues with the last owner")
check(BuddyGroupPolicy.route(userText: "hi", members: members, leadID: sam.id, lastOwnerID: nil)?.ownerID == sam.id, "no last owner: the lead answers")
check(BuddyGroupPolicy.route(userText: "hi", members: members, leadID: nil, lastOwnerID: nil)?.ownerID == mia.id, "no lead: the first member answers")
check(BuddyGroupPolicy.route(userText: "hi", members: members, leadID: nil, lastOwnerID: UUID())?.ownerID == mia.id, "a last owner who left the group is ignored")
check(BuddyGroupPolicy.route(userText: "hi", members: [], leadID: nil, lastOwnerID: nil) == nil, "an empty group routes nowhere")

// MARK: - Handoff

let handed = BuddyGroupPolicy.parseHandoff(in: "I'll let Sam check. [HANDOFF:Sam: find the invoice]", members: members, senderID: mia.id)
check(handed.visibleText == "I'll let Sam check.", "the tag is removed from what is shown")
check(handed.handoff?.target == sam && handed.handoff?.request == "find the invoice", "the tag names the teammate and the request")
let bareHandoff = BuddyGroupPolicy.parseHandoff(in: "Over to you [HANDOFF:sam]", members: members, senderID: mia.id)
check(bareHandoff.handoff?.request == "Over to you", "a tag with no request passes the visible answer on")
check(BuddyGroupPolicy.parseHandoff(in: "me [HANDOFF:Mia: x]", members: members, senderID: mia.id).handoff == nil, "a buddy cannot hand off to itself")
let unknown = BuddyGroupPolicy.parseHandoff(in: "ok [HANDOFF:Nobody: x]", members: members, senderID: mia.id)
check(unknown.handoff == nil && unknown.visibleText == "ok", "an unknown name is stripped and ignored")
check(BuddyGroupPolicy.parseHandoff(in: "plain answer", members: members, senderID: mia.id).handoff == nil, "no tag, no handoff")

// MARK: - Shared history

func message(_ author: BuddyGroupMessage.Author, _ text: String) -> BuddyGroupMessage {
    BuddyGroupMessage(id: UUID(), author: author, text: text, createdAt: Date(), taskID: nil)
}
let transcript = [
    message(.user, "plan dinner"),
    message(.buddy(mia.id), "Pasta?"),
    message(.buddy(sam.id), "Too heavy."),
    message(.notice, "Sam took over"),
    message(.user, "ok something light"),
]
let samHistory = BuddyGroupPolicy.historyMessages(for: sam.id, in: transcript, members: members)
check(samHistory.map(\.role) == [.user, .assistant, .user], "roles alternate from Sam's side")
check(samHistory[0].combinedText == "User: plan dinner\n\nMia: Pasta?", "the user and a teammate are merged and labelled")
check(samHistory[1].combinedText == "Too heavy.", "Sam's own answer is its assistant turn, unlabelled")
check(samHistory[2].combinedText == "User: ok something light", "notices never reach the model")
let kitHistory = BuddyGroupPolicy.historyMessages(for: mia.id, in: [message(.buddy(mia.id), "I spoke first"), message(.user, "hi")], members: members)
check(kitHistory.first?.role == .user, "the history never starts with the buddy's own turn")
let longHistory = BuddyGroupPolicy.historyMessages(for: mia.id, in: (0..<40).map { message(.user, "m\($0)") }, members: members)
check(longHistory.count == 1 && longHistory[0].combinedText.contains("m39") && !longHistory[0].combinedText.contains("m27"),
      "only the last \(BuddyGroupPolicy.maximumMessagesInPrompt) messages are used")
check(BuddyGroupPolicy.systemPromptAddendum(groupName: "Trip", members: members, buddyID: sam.id).contains("[HANDOFF:Name"), "the prompt teaches the handoff tag")
check(!BuddyGroupPolicy.systemPromptAddendum(groupName: "Solo", members: [sam], buddyID: sam.id).contains("HANDOFF"), "a lone member is not offered a handoff")
let handoffTranscript = [message(.user, "plan dinner"), message(.buddy(mia.id), "Pasta? Sam can check the fridge."), message(.user, "find the invoice"), message(.buddy(mia.id), "Handing to Sam.")]
let turnContext = BuddyGroupPolicy.turnContext(in: handoffTranscript, members: members)
check(turnContext.prior.count == 2 && turnContext.latestUserText == "find the invoice", "the context splits at the user's latest message")
check(turnContext.teammateLines == ["Mia: Handing to Sam."], "what teammates said since is carried along")
check(BuddyGroupPolicy.runRequestText(requestText: "find it", context: turnContext, handedOffBy: nil) == "find it", "the first answer gets the user's words as they are")
let handoffRequest = BuddyGroupPolicy.runRequestText(requestText: "find it", context: turnContext, handedOffBy: "Mia")
check(handoffRequest.contains("The user wrote: find the invoice") && handoffRequest.contains("Mia: Handing to Sam.") && handoffRequest.hasSuffix("Mia handed this to you: find it"),
      "a handoff carries the user's words, the teammates' lines and the ask")
check(BuddyGroupPolicy.turnContext(in: [message(.buddy(mia.id), "hi")], members: members).latestUserText == nil, "no user message yet: no latest text")

let leadInSplit = BuddyGroupPolicy.historyAndLeadIn(for: sam.id, in: transcript, members: members)
check(leadInSplit.history.map(\.role) == [.user, .assistant] && leadInSplit.leadIn == "User: ok something light",
      "history ends on the buddy's own turn; what came after is the lead-in")
check(BuddyGroupPolicy.runRequestText(requestText: "now?", context: BuddyGroupPolicy.turnContext(in: [], members: members), handedOffBy: nil, leadIn: "Mia: hi") == "Earlier in the group:\nMia: hi\n\nnow?",
      "a lead-in goes in front of the request")

// MARK: - Transcript

var capped: [BuddyGroupMessage] = []
for index in 0..<(BuddyGroupPolicy.maximumStoredMessages + 5) { capped = BuddyGroupPolicy.appending(message(.user, "\(index)"), to: capped) }
check(capped.count == BuddyGroupPolicy.maximumStoredMessages && capped.last?.text == "204", "the transcript keeps the newest messages")
check(BuddyGroupPolicy.lastOwnerID(in: transcript) == sam.id, "the last owner is the last buddy who spoke")
let group = BuddyGroup(id: UUID(), name: "Trip", memberIDs: [mia.id, sam.id], leadID: mia.id, createdAt: Date(), isArchived: nil)
let decoded = try! JSONDecoder().decode([BuddyGroup].self, from: JSONEncoder().encode([group]))
check(decoded == [group], "a group survives the codec")
let messageRoundTrip = try! JSONDecoder().decode([BuddyGroupMessage].self, from: JSONEncoder().encode(transcript))
check(messageRoundTrip == transcript, "messages, including authors, survive the codec")
check(BuddyGroupPolicy.suggestedName(memberNames: ["Mia", "Sam", "Kit"]) == "Mia, Sam & Kit", "suggested name lists members")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
