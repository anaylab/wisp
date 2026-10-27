//
//  Email draft suite: spoken "draft an email…" requests, the model's reply
//  read back into fields, and the address rules checked before Send.
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

func request(_ transcript: String) -> EmailDraftRequest? {
    EmailDraftRequestParser.request(from: transcript)
}

// MARK: - Recognised requests

check(request("draft an email to sam about moving our meeting to friday")
      == EmailDraftRequest(recipientPhrase: "sam", hasContentToWrite: true, refersToScreen: false, isReply: false),
      "draft to sam about …")
check(request("Draft an email to Sam Chen saying I'll be late.")?.recipientPhrase == "Sam Chen", "two-word name, casing kept")
check(request("write me a quick email to my landlord about the broken heater")?.recipientPhrase == "my landlord", "adjective + possessive recipient")
check(request("hey wisp, can you draft an email")
      == EmailDraftRequest(recipientPhrase: nil, hasContentToWrite: false, refersToScreen: false, isReply: false),
      "bare draft opens blank")
check(request("draft an email to sam")
      == EmailDraftRequest(recipientPhrase: "sam", hasContentToWrite: false, refersToScreen: false, isReply: false),
      "recipient only opens blank to sam")
check(request("write an email to ask my professor for an extension")
      == EmailDraftRequest(recipientPhrase: nil, hasContentToWrite: true, refersToScreen: false, isReply: false),
      "to-purpose is not a recipient")
check(request("compose an email about the team offsite")?.hasContentToWrite == true, "topic without recipient")
check(request("send an email to sam@example.com saying thanks")?.recipientPhrase == "sam@example.com", "address recipient")
check(request("send sam an email about lunch")?.recipientPhrase == "sam", "send X an email")
check(request("email mom saying happy birthday")?.recipientPhrase == "mom", "email as verb with separator")
check(request("email sam")
      == EmailDraftRequest(recipientPhrase: "sam", hasContentToWrite: false, refersToScreen: false, isReply: false),
      "email X alone")
check(request("draft a follow-up email to the recruiter thanking them for the interview")?.recipientPhrase == "the recruiter", "follow-up adjective")
check(request("draft an email to sam on friday's plan")?.recipientPhrase == "sam", "'on' ends the name")

// Screen and reply shapes.
check(request("reply to this email saying i'll be there")
      == EmailDraftRequest(recipientPhrase: nil, hasContentToWrite: true, refersToScreen: true, isReply: true),
      "reply to this email")
check(request("draft a reply to this email")?.isReply == true, "draft a reply")
check(request("write a polite response to this message")?.isReply == true, "response to this message")
check(request("email this page to sam")
      == EmailDraftRequest(recipientPhrase: "sam", hasContentToWrite: true, refersToScreen: true, isReply: false),
      "email this page to sam")
check(request("draft an email to sam summarizing this article")?.refersToScreen == true, "summarizing this → screen")
check(request("draft an email to sam about this weekend")?.refersToScreen == false, "this weekend is not the screen")
check(request("draft an email to sam about what's on my screen")?.refersToScreen == true, "on my screen")

// MARK: - Not email requests

check(request("what's in my email") == nil, "question about email")
check(request("email from sam") == nil, "email as a noun")
check(request("email address for sam") == nil, "email address")
check(request("how do i write an email") == nil, "how-to question")
check(request("write a summary of this email") == nil, "summary of an email")
check(request("send the email") == nil, "send the email is not a new draft")
check(request("email sam the notes from today's meeting") == nil, "no clear name boundary → model")
check(request("emails") == nil, "plural noun")
check(request("text sam saying hi") == nil, "a text is not an email")

// MARK: - Recipient splitting

let (splitName, splitTopic) = EmailDraftRequestParser.splitRecipient(fromTextAfterTo: "sarah jane about the trip")
check(splitName == "sarah jane" && splitTopic == "about the trip", "split name/topic")
let (noName, wholeTopic) = EmailDraftRequestParser.splitRecipient(fromTextAfterTo: "the landlord the heater is broken again")
check(noName == nil && wholeTopic == "the landlord the heater is broken again", "too long a name → no recipient")
check(EmailDraftRequestParser.splitRecipient(fromTextAfterTo: "them about it").recipientPhrase == nil, "them is nobody to look up")

// MARK: - To the user themself

check(request("draft an email to me about lunch")?.isAddressedToUser == true, "draft an email to me")
check(request("draft an email to me about lunch")?.hasContentToWrite == true, "to me about lunch has content")
check(request("send me an email about lunch")?.isAddressedToUser == true, "send me an email")
check(request("email me about the dentist")?.isAddressedToUser == true, "email me about …")
check(request("email myself saying buy milk")?.isAddressedToUser == true, "email myself")
check(request("write me an email to my landlord about the heater")?.recipientPhrase == "my landlord", "write me an email is for me, not to me")
check(request("write me an email about the trip")?.isAddressedToUser == false, "write me an email has no recipient")
check(request("draft an email to sam about lunch")?.isAddressedToUser == false, "sam is not the user")
check(EmailDraftPrompt.userMessage(request: "x", recipientDisplayName: "Anay Parwal", isAddressedToUser: true, screenText: nil).contains("note to self"), "self prompt line")

// MARK: - Model reply parsing

let plainReply = """
Subject: Moving Friday's meeting

Hi Sam,

Could we move Friday's meeting to Monday?

Thanks,
Anay
"""
let parsedPlain = EmailDraftReplyParser.parse(modelReply: plainReply)
check(parsedPlain?.subject == "Moving Friday's meeting", "subject read")
check(parsedPlain?.body.hasPrefix("Hi Sam,") == true && parsedPlain?.body.hasSuffix("Anay") == true, "body read")
check(parsedPlain?.toAddress == nil, "no To")

let preambleReply = """
Here's a draft:
**Subject:** Quick question
Body: Hi,

Are you free?
"""
let parsedPreamble = EmailDraftReplyParser.parse(modelReply: preambleReply)
check(parsedPreamble?.subject == "Quick question", "bold subject after a preamble")
check(parsedPreamble?.body == "Hi,\n\nAre you free?", "Body: label stripped")

let replyWithTo = """
To: Lee Park <lee@example.com>
Cc: boss@example.com
Subject: Re: Dinner
Hi Lee, see you there. [SAY: done]
"""
let parsedReplyWithTo = EmailDraftReplyParser.parse(modelReply: replyWithTo)
check(parsedReplyWithTo?.toAddress == "lee@example.com", "To address read")
check(parsedReplyWithTo?.subject == "Re: Dinner", "Re subject")
check(parsedReplyWithTo?.body == "Hi Lee, see you there.", "Cc ignored, tags stripped")

let fencedReply = "```\nSubject: Hi\n\nHello there\n```"
check(EmailDraftReplyParser.parse(modelReply: fencedReply)?.body == "Hello there", "code fence stripped")
check(EmailDraftReplyParser.parse(modelReply: "No subject, just the body.")?.body == "No subject, just the body.", "no headers → whole body")
check(EmailDraftReplyParser.parse(modelReply: "Subject: Empty\n\n") == nil, "empty body → nil")

// MARK: - Address fields

let mixedList = EmailAddressList.parse("Sam Chen <sam@example.com>, lee@example.org; mailto:pat@example.co.uk")
check(mixedList.addresses == ["sam@example.com", "lee@example.org", "pat@example.co.uk"], "mixed address list")
check(mixedList.invalidEntries.isEmpty, "no invalid entries")
check(EmailAddressList.parse("sam, lee@example.org").invalidEntries == ["sam"], "bare name is invalid")
check(EmailAddressList.fieldEntry(displayName: "Sam Chen", address: "sam@example.com") == "Sam Chen <sam@example.com>", "field entry")
check(EmailAddressList.fieldEntry(displayName: "sam@example.com", address: "sam@example.com") == "sam@example.com", "address-only entry")
check(EmailAddressList.fieldEntry(displayName: "Chen, Sam", address: "s@x.io") == "Chen Sam <s@x.io>", "comma removed from name")

check(EmailAddressList.problemBeforeSending(EmailDraftFields(toField: "", body: "hi")) == "Add who it's to.", "needs a recipient")
check(EmailAddressList.problemBeforeSending(EmailDraftFields(toField: "sam", body: "hi")) == "“sam” isn't an email address.", "invalid recipient named")
check(EmailAddressList.problemBeforeSending(EmailDraftFields(toField: "s@x.io", ccField: "nope", body: "hi")) == "“nope” isn't an email address.", "invalid cc named")
check(EmailAddressList.problemBeforeSending(EmailDraftFields(toField: "s@x.io", body: "  ")) == "The email is empty.", "empty body")
check(EmailAddressList.problemBeforeSending(EmailDraftFields(toField: "s@x.io", body: "hi")) == nil, "ready to send")

// MARK: - Prompt and links

let systemPrompt = EmailDraftPrompt.systemPrompt(senderFirstName: "Anay", isReply: true)
check(systemPrompt.contains("Sign off with the user's first name: Anay."), "sign-off name")
check(systemPrompt.contains("never guess an address"), "reply To rule")
check(!EmailDraftPrompt.systemPrompt(senderFirstName: nil, isReply: false).contains("Re:"), "no reply rule for a new email")

let userMessage = EmailDraftPrompt.userMessage(request: "draft an email", recipientDisplayName: "Sam Chen", screenText: String(repeating: "x", count: 5000))
check(userMessage.contains("It is to: Sam Chen"), "recipient named")
check(userMessage.contains("<<<") && userMessage.contains(">>>"), "screen text fenced")
check(!userMessage.contains(String(repeating: "x", count: 4001)), "screen text capped")

let gmailURL = EmailComposeLinks.gmailComposeURL(for: EmailDraftFields(toField: "Sam <sam@example.com>", subject: "Hi & bye", body: "Line 1\nLine 2"))
check(gmailURL?.host == "mail.google.com", "gmail host")
let gmailQuery = URLComponents(url: gmailURL!, resolvingAgainstBaseURL: false)?.queryItems ?? []
check(gmailQuery.first { $0.name == "to" }?.value == "sam@example.com", "gmail to is the bare address")
check(gmailQuery.first { $0.name == "su" }?.value == "Hi & bye", "gmail subject kept")
check(EmailComposeLinks.plainText(for: EmailDraftFields(subject: "S", body: "B")) == "Subject: S\n\nB", "copy text")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
