//
//  MessagesAndContactsTests.swift
//  leanring-buddyTests
//
//  Proves the Siri-style "text mom i'm running late" path: the parser reads the
//  common spoken shapes and declines anything that isn't a message command;
//  contact matching picks the person meant (or says it can't tell); and a send
//  always reaches the confirmation card — naming the resolved person and
//  number — even with session auto-approve on.
//

import XCTest
@testable import Wisp

@MainActor
final class MessagesAndContactsTests: XCTestCase {

    // MARK: - Parser: recognised shapes

    private func onlyCandidate(_ transcript: String) -> MessageCommandCandidate? {
        guard let parsedCandidates = MessageCommandParser.candidates(from: transcript), parsedCandidates.count == 1 else { return nil }
        return parsedCandidates.first
    }

    func testSeparatorShapesGiveOneCertainCandidate() {
        XCTAssertEqual(
            onlyCandidate("Text mom saying I'm running late"),
            MessageCommandCandidate(recipient: "mom", messageText: "I'm running late", isRecipientBoundaryCertain: true)
        )
        XCTAssertEqual(
            onlyCandidate("send a message to Sarah Chen that dinner is at 8"),
            MessageCommandCandidate(recipient: "Sarah Chen", messageText: "dinner is at 8", isRecipientBoundaryCertain: true)
        )
        XCTAssertEqual(
            onlyCandidate("send dad a text saying call me back"),
            MessageCommandCandidate(recipient: "dad", messageText: "call me back", isRecipientBoundaryCertain: true)
        )
        XCTAssertEqual(
            onlyCandidate("tell my wife that I'll be home soon"),
            MessageCommandCandidate(recipient: "wife", messageText: "I'll be home soon", isRecipientBoundaryCertain: true)
        )
        XCTAssertEqual(
            onlyCandidate("hey wisp, can you text Alex saying that the build is green"),
            MessageCommandCandidate(recipient: "Alex", messageText: "the build is green", isRecipientBoundaryCertain: true)
        )
    }

    func testUnseparatedShapeOffersSplitsLongestNameFirst() {
        let parsedCandidates = MessageCommandParser.candidates(from: "text sarah chen see you soon")
        XCTAssertEqual(parsedCandidates?.map(\.recipient), ["sarah chen see", "sarah chen", "sarah"])
        XCTAssertEqual(parsedCandidates?.last?.messageText, "chen see you soon")
        XCTAssertEqual(parsedCandidates?.allSatisfy { !$0.isRecipientBoundaryCertain }, true)
    }

    func testMessageTextKeepsItsCaseAndPunctuation() {
        XCTAssertEqual(onlyCandidate("text mom saying Are you FREE tonight?")?.messageText, "Are you FREE tonight?")
    }

    // MARK: - Parser: declined

    func testNonMessageRequestsAreNotParsed() {
        XCTAssertNil(MessageCommandParser.candidates(from: "what's the weather"))
        XCTAssertNil(MessageCommandParser.candidates(from: "tell me a joke"))
        XCTAssertNil(MessageCommandParser.candidates(from: "text me saying hi"))
        XCTAssertNil(MessageCommandParser.candidates(from: "text size bigger please"))
        XCTAssertNil(MessageCommandParser.candidates(from: "message from mom"))
        XCTAssertNil(MessageCommandParser.candidates(from: "text"))
        XCTAssertNil(MessageCommandParser.candidates(from: "send a message to mom"))
        XCTAssertNil(MessageCommandParser.candidates(from: "read the text on screen"))
    }

    // MARK: - Contact matching

    private func contact(
        _ givenName: String,
        _ familyName: String = "",
        nickname: String = "",
        organizationName: String = "",
        phone: String? = "+1 555 000 0000",
        phoneLabel: String = "mobile"
    ) -> ContactRecord {
        ContactRecord(
            identifier: UUID().uuidString,
            givenName: givenName,
            familyName: familyName,
            nickname: nickname,
            organizationName: organizationName,
            phoneHandles: phone.map { [ContactHandle(kind: .phoneNumber, value: $0, label: phoneLabel)] } ?? [],
            emailHandles: []
        )
    }

    func testExactFirstNameBeatsPrefixMatch() {
        let ada = contact("Ada", "Lovelace", phone: "+1 555 111 1111")
        let adam = contact("Adam", "Smith", phone: "+1 555 222 2222")
        XCTAssertEqual(ContactMatcher.resolve(spokenName: "ada", among: [ada, adam]), .matched(ada))
    }

    func testTwoPeopleWithTheSameNameAreAmbiguous() {
        let alexChen = contact("Alex", "Chen", phone: "+1 555 111 1111")
        let alexRivera = contact("Alex", "Rivera", phone: "+1 555 222 2222")
        guard case .ambiguous(let matchingContacts) = ContactMatcher.resolve(spokenName: "Alex", among: [alexChen, alexRivera]) else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(Set(matchingContacts.map(\.displayName)), ["Alex Chen", "Alex Rivera"])
        XCTAssertEqual(ContactMatcher.resolve(spokenName: "alex rivera", among: [alexChen, alexRivera]), .matched(alexRivera))
    }

    func testDuplicateCardsForOnePersonAreNotAmbiguous() {
        let firstCard = contact("Sam", "Lee", phone: "+1 555 333 3333")
        let duplicateCard = contact("Sam", "Lee", phone: "+1 555 333 3333")
        guard case .matched = ContactMatcher.resolve(spokenName: "sam", among: [firstCard, duplicateCard]) else {
            return XCTFail("a duplicate card should resolve to one person")
        }
    }

    func testSameNamedCardsWithDifferentHandlesAreOnePerson() {
        let cardWithMobile = contact("Avi", "Parwal", phone: "+1 (555) 010-9999", phoneLabel: "mobile")
        let cardWithSameNumberWrittenDifferently = contact("Avi", "Parwal", phone: "5550109999", phoneLabel: "home")
        let emailOnlyCard = ContactRecord(
            identifier: "email-card", givenName: "Avi", familyName: "Parwal", nickname: "", organizationName: "",
            phoneHandles: [], emailHandles: [ContactHandle(kind: .emailAddress, value: "avi@example.com", label: "")]
        )
        let otherAvi = contact("Avi", "Shah", phone: "+1 555 777 7777")

        guard case .matched(let mergedAvi) = ContactMatcher.resolve(
            spokenName: "Avi Parwal",
            among: [emailOnlyCard, cardWithSameNumberWrittenDifferently, cardWithMobile, otherAvi]
        ) else {
            return XCTFail("same-named cards should be one person")
        }
        XCTAssertEqual(mergedAvi.preferredMessagingHandle?.value, "5550109999")
        XCTAssertEqual(mergedAvi.phoneHandles.count, 1, "the same number written two ways is one number")
        XCTAssertEqual(mergedAvi.emailHandles.map(\.value), ["avi@example.com"])
        XCTAssertEqual(mergedAvi.identifier, cardWithSameNumberWrittenDifferently.identifier)

        // Different people still get asked about, by name.
        guard case .ambiguous(let matchingContacts) = ContactMatcher.resolve(
            spokenName: "avi",
            among: [cardWithMobile, emailOnlyCard, otherAvi]
        ) else {
            return XCTFail("two different Avis should be ambiguous")
        }
        XCTAssertEqual(Set(matchingContacts.map(\.displayName)), ["Avi Parwal", "Avi Shah"])
    }

    func testNicknameAccentsAndRelationsResolve() {
        let mom = contact("Jane", "Doe", phone: "+1 555 444 4444")
        let jose = contact("José", "O'Neil")
        let cardNamedMom = contact("", nickname: "Mom")
        XCTAssertEqual(ContactMatcher.resolve(spokenName: "jose oneil", among: [mom, jose]), .matched(jose))
        XCTAssertEqual(ContactMatcher.resolve(spokenName: "mom", among: [cardNamedMom, jose]), .matched(cardNamedMom))
        XCTAssertEqual(
            ContactMatcher.resolve(spokenName: "mom", among: [mom, jose], relatedContactNamesByRelationLabel: ["mother": "Jane Doe"]),
            .matched(mom)
        )
    }

    func testGuessedSplitRequiresAnExactName() {
        let sarahChen = contact("Sarah", "Chen")
        XCTAssertEqual(
            ContactMatcher.resolve(spokenName: "sar", among: [sarahChen], weakestAcceptedStrength: .exactFamilyOrOrganizationName),
            .noMatch
        )
        XCTAssertEqual(ContactMatcher.resolve(spokenName: "sar", among: [sarahChen]), .matched(sarahChen))
    }

    func testPreferredHandleIsMobileThenPhoneThenEmail() {
        let multiHandleContact = ContactRecord(
            identifier: "1", givenName: "Kim", familyName: "", nickname: "", organizationName: "",
            phoneHandles: [
                ContactHandle(kind: .phoneNumber, value: "+1 555 000 0001", label: "home"),
                ContactHandle(kind: .phoneNumber, value: "+1 555 000 0002", label: "iphone"),
            ],
            emailHandles: [ContactHandle(kind: .emailAddress, value: "kim@example.com", label: "work")]
        )
        XCTAssertEqual(multiHandleContact.preferredMessagingHandle?.value, "+1 555 000 0002")

        let emailOnlyContact = ContactRecord(
            identifier: "2", givenName: "Lou", familyName: "", nickname: "", organizationName: "",
            phoneHandles: [],
            emailHandles: [ContactHandle(kind: .emailAddress, value: "lou@example.com", label: "")]
        )
        XCTAssertEqual(emailOnlyContact.preferredMessagingHandle?.value, "lou@example.com")
    }

    func testDirectHandlesSkipTheContactLookup() {
        XCTAssertEqual(DirectMessagingHandleParser.handle(from: "+1 (555) 010-9999")?.kind, .phoneNumber)
        XCTAssertEqual(DirectMessagingHandleParser.handle(from: "ada@example.com")?.kind, .emailAddress)
        XCTAssertNil(DirectMessagingHandleParser.handle(from: "mom"))
        XCTAssertNil(DirectMessagingHandleParser.handle(from: "911"))
    }

    // MARK: - Consent

    private let preparedSendInput: JSONValue = .object([
        "to": .string("Jane Doe"),
        "handle": .string("+1 555 444 4444"),
        "message": .string("running late"),
    ])

    func testSendAlwaysAsksEvenWithSessionAutoApprove() {
        XCTAssertTrue(ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: MessagingToolNames.sendIMessage,
            toolInput: preparedSendInput,
            agentWorkingDirectoryPath: "/tmp"
        ))
        XCTAssertFalse(ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: MessagingToolNames.findContact,
            toolInput: .object(["name": .string("mom")]),
            agentWorkingDirectoryPath: "/tmp"
        ))
    }

    func testConfirmationCardNamesThePersonNumberAndMessage() {
        let confirmationCard = ToolConfirmationCardBuilder.confirmationCard(
            forToolNamed: MessagingToolNames.sendIMessage,
            toolInput: preparedSendInput,
            agentWorkingDirectoryPath: nil
        )
        guard case .header(let headerTitle, _, _)? = confirmationCard?.blocks.first else { return XCTFail("no header") }
        XCTAssertEqual(headerTitle, "New Message")

        var pairsByKey: [String: String] = [:]
        var listRowTexts: [String] = []
        for block in confirmationCard?.blocks ?? [] {
            if case .keyValue(let pairs) = block { for pair in pairs { pairsByKey[pair.key] = pair.value } }
            if case .list(let rows) = block { listRowTexts += rows.map(\.text) }
        }
        XCTAssertEqual(pairsByKey["To"], "Jane Doe")
        XCTAssertEqual(pairsByKey["Number"], "+1 555 444 4444")
        XCTAssertEqual(listRowTexts, ["running late"])
    }

    func testMessagingScopeRoutesTextRequestsToMessagingTools() {
        XCTAssertEqual(AgentToolScope.forRequest("text mom that i'm late"), .messaging)
        XCTAssertEqual(AgentToolScope.forRequest("send a message to sam"), .messaging)
        XCTAssertTrue(AgentToolScope.messaging.includes(toolNamed: MessagingToolNames.sendIMessage))
        XCTAssertFalse(AgentToolScope.general.includes(toolNamed: MessagingToolNames.sendIMessage))
    }
}
