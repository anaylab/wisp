//
//  ContactsDirectory.swift
//  leanring-buddy
//
//  Finds the person the user means — "mom", "alex", "sarah chen" — in their
//  Contacts, on this Mac, so a message can be addressed the way Siri does it.
//
//  Two halves. `ContactMatcher` is pure: given plain contact records and what
//  the user said, it decides who is meant, or that it can't tell. That is the
//  part worth testing, and it needs no Contacts database to test. The
//  `ContactsDirectory` wrapper owns the `CNContactStore` read: permission,
//  fetching, and turning `CNContact`s into those plain records.
//
//  Read-only and local. Contacts are read through the Contacts framework on
//  this Mac and never leave it; nothing here writes to the address book.
//

import AppKit
import Contacts
import Foundation

/// One way to reach a contact: a phone number or an email address.
struct ContactHandle: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case phoneNumber
        case emailAddress
    }

    let kind: Kind
    /// The number or address exactly as stored, which is what Messages is given.
    let value: String
    /// "mobile", "iPhone", "home" — already localized and lowercased; empty
    /// when the card has no label.
    let label: String

    /// Mobile numbers are the ones that can receive a text, so they are
    /// preferred when a contact has several.
    var isMobilePhoneNumber: Bool {
        kind == .phoneNumber && (label.contains("mobile") || label.contains("iphone") || label.contains("cell"))
    }
}

/// A contact reduced to what matching and messaging need.
struct ContactRecord: Equatable, Sendable {
    let identifier: String
    let givenName: String
    let familyName: String
    let nickname: String
    let organizationName: String
    let phoneHandles: [ContactHandle]
    let emailHandles: [ContactHandle]

    /// "Ada Lovelace", or the nickname / company when the card has no name.
    var displayName: String {
        let fullName = [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !fullName.isEmpty { return fullName }
        if !nickname.isEmpty { return nickname }
        return organizationName
    }

    /// The handle a message goes to: a mobile number first, then any number,
    /// then an email address (iMessage works with an Apple ID email). Nil when
    /// the card has no way to be messaged at all.
    var preferredMessagingHandle: ContactHandle? {
        if let mobilePhoneHandle = phoneHandles.first(where: \.isMobilePhoneNumber) { return mobilePhoneHandle }
        if let anyPhoneHandle = phoneHandles.first { return anyPhoneHandle }
        return emailHandles.first
    }
}

/// Decides which contact a spoken name refers to. Pure and deterministic.
enum ContactMatcher {

    /// What a name resolved to.
    enum Resolution: Equatable {
        case matched(ContactRecord)
        /// Several contacts fit equally well — "alex" with two Alexes. The user
        /// is asked which; guessing would message the wrong person.
        case ambiguous([ContactRecord])
        case noMatch
    }

    /// How well a contact fits, best first. Only the best tier that has any
    /// contacts in it counts, so an exact "Alex" beats an "Alexandra" prefix.
    enum MatchStrength: Int, Comparable {
        /// The whole query is the contact's full name or nickname ("mom" when
        /// the card is literally named Mom), or their relation on the user's
        /// own card ("mom" → whoever the Me card lists as mother).
        case exactFullNameOrNickname = 0
        /// The first name alone ("ada" → Ada Lovelace).
        case exactGivenName = 1
        /// The last name or the company alone.
        case exactFamilyOrOrganizationName = 2
        /// Every word of the query starts a word of the name ("ada love").
        case wordPrefixes = 3

        static func < (lhs: MatchStrength, rhs: MatchStrength) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Spoken relation words and the Contacts relation labels they mean.
    /// Matched against the user's own card, so "text mom" works for someone
    /// whose mother is saved under her real name.
    static let relationWordsToContactRelationLabels: [String: [String]] = [
        "mom": ["mother"], "mum": ["mother"], "mother": ["mother"], "mommy": ["mother"], "mama": ["mother"],
        "dad": ["father"], "father": ["father"], "daddy": ["father"], "papa": ["father"],
        "wife": ["spouse", "wife"], "husband": ["spouse", "husband"],
        "partner": ["partner", "spouse"],
        "sister": ["sister"], "brother": ["brother"],
        "son": ["son", "child"], "daughter": ["daughter", "child"],
        "boyfriend": ["partner"], "girlfriend": ["partner"],
    ]

    /// Finds who `spokenName` refers to among `contacts`.
    ///
    /// - Parameters:
    ///   - weakestAcceptedStrength: The loosest match allowed. A name the user
    ///     clearly separated from their message may match by word prefixes; a
    ///     name guessed from "text mom i'm late" (where the name's end is
    ///     unknown) must match exactly, or "mom i'm" would find someone.
    ///   - relatedContactNamesByRelationLabel: The user's own card's relations,
    ///     lowercased label → the related person's name as stored.
    static func resolve(
        spokenName: String,
        among contacts: [ContactRecord],
        weakestAcceptedStrength: MatchStrength = .wordPrefixes,
        relatedContactNamesByRelationLabel: [String: String] = [:]
    ) -> Resolution {
        let normalizedQuery = normalizedName(spokenName)
        guard !normalizedQuery.isEmpty else { return .noMatch }

        // "mom" → the name the Me card gives for mother, which is then matched
        // as a full name. Tried before ordinary matching, since a relation is
        // the most specific thing the user could have meant.
        if let relationLabels = relationWordsToContactRelationLabels[normalizedQuery] {
            // The spoken word itself too: a relation saved with a custom label
            // ("mom") is stored as that label, not as "mother".
            for relationLabel in relationLabels + [normalizedQuery] {
                guard let relatedPersonName = relatedContactNamesByRelationLabel[relationLabel] else { continue }
                let relatedPersonResolution = resolve(
                    spokenName: relatedPersonName,
                    among: contacts,
                    weakestAcceptedStrength: .exactFullNameOrNickname
                )
                if case .matched = relatedPersonResolution { return relatedPersonResolution }
            }
        }

        var contactsByStrength: [MatchStrength: [ContactRecord]] = [:]
        for contact in contacts {
            guard let strength = matchStrength(of: contact, forNormalizedQuery: normalizedQuery),
                  strength <= weakestAcceptedStrength else { continue }
            contactsByStrength[strength, default: []].append(contact)
        }

        guard let bestStrength = contactsByStrength.keys.min(),
              let bestContacts = contactsByStrength[bestStrength] else {
            return .noMatch
        }
        // The same person saved twice (a duplicate card, or one per synced
        // account) is one person, not a choice to put to the user.
        let distinctBestContacts = mergingCardsWithTheSameName(bestContacts)
        if distinctBestContacts.count == 1, let onlyContact = distinctBestContacts.first {
            return .matched(onlyContact)
        }
        return .ambiguous(distinctBestContacts)
    }

    /// How well one contact fits the query, or nil when it doesn't.
    static func matchStrength(of contact: ContactRecord, forNormalizedQuery normalizedQuery: String) -> MatchStrength? {
        let normalizedGivenName = normalizedName(contact.givenName)
        let normalizedFamilyName = normalizedName(contact.familyName)
        let normalizedFullName = normalizedName("\(contact.givenName) \(contact.familyName)")
        let normalizedNickname = normalizedName(contact.nickname)
        let normalizedOrganizationName = normalizedName(contact.organizationName)

        if normalizedQuery == normalizedFullName || (!normalizedNickname.isEmpty && normalizedQuery == normalizedNickname) {
            return .exactFullNameOrNickname
        }
        if !normalizedGivenName.isEmpty && normalizedQuery == normalizedGivenName {
            return .exactGivenName
        }
        if (!normalizedFamilyName.isEmpty && normalizedQuery == normalizedFamilyName)
            || (!normalizedOrganizationName.isEmpty && normalizedQuery == normalizedOrganizationName) {
            return .exactFamilyOrOrganizationName
        }

        // "ada love" → Ada Lovelace: each query word starts the name word in
        // the same position. Order matters so "love ada" doesn't count.
        let queryWords = normalizedQuery.split(separator: " ").map(String.init)
        for candidateName in [normalizedFullName, normalizedNickname, normalizedOrganizationName] where !candidateName.isEmpty {
            let candidateNameWords = candidateName.split(separator: " ").map(String.init)
            guard queryWords.count <= candidateNameWords.count else { continue }
            let everyQueryWordStartsItsNameWord = zip(queryWords, candidateNameWords).allSatisfy { queryWord, candidateNameWord in
                candidateNameWord.hasPrefix(queryWord)
            }
            // A single letter is too little to go on ("a" would match half the book).
            if everyQueryWordStartsItsNameWord && normalizedQuery.count >= 2 {
                return .wordPrefixes
            }
        }
        return nil
    }

    /// Lowercased, accents folded, punctuation dropped, single-spaced — so
    /// "José O'Neil" and "jose oneil" are the same name.
    static func normalizedName(_ rawName: String) -> String {
        let foldedName = rawName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let lettersDigitsAndSpaces = foldedName.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) { return String(scalar) }
            if CharacterSet.whitespaces.contains(scalar) || scalar == "-" { return " " }
            return ""
        }.joined()
        return lettersDigitsAndSpaces
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Folds cards that share a full name into one person, pooling their
    /// numbers and emails.
    ///
    /// Duplicate cards rarely agree exactly: one has "+1 (555) 010-9999", the
    /// other "5550109999", or only an email. Asking "which Avi Parwal?" between
    /// two cards that read identically is a question the user can't answer, so
    /// same-named cards are merged instead. Two genuinely different people with
    /// the same full name are rare, and the confirmation card shows the exact
    /// number before anything sends, so a wrong pick is still caught there.
    static func mergingCardsWithTheSameName(_ contacts: [ContactRecord]) -> [ContactRecord] {
        var mergedContactsInOrder: [ContactRecord] = []
        var mergedContactIndexByName: [String: Int] = [:]

        for contact in contacts {
            let normalizedDisplayName = normalizedName(contact.displayName)
            guard let existingIndex = mergedContactIndexByName[normalizedDisplayName] else {
                mergedContactIndexByName[normalizedDisplayName] = mergedContactsInOrder.count
                mergedContactsInOrder.append(contact)
                continue
            }
            mergedContactsInOrder[existingIndex] = mergedContact(mergedContactsInOrder[existingIndex], with: contact)
        }
        return mergedContactsInOrder
    }

    private static func mergedContact(_ firstCard: ContactRecord, with secondCard: ContactRecord) -> ContactRecord {
        let pooledPhoneHandles = handlesWithoutDuplicates(firstCard.phoneHandles + secondCard.phoneHandles)
        let pooledEmailHandles = handlesWithoutDuplicates(firstCard.emailHandles + secondCard.emailHandles)
        let pooledContact = ContactRecord(
            identifier: firstCard.identifier,
            givenName: firstCard.givenName,
            familyName: firstCard.familyName,
            nickname: firstCard.nickname.isEmpty ? secondCard.nickname : firstCard.nickname,
            organizationName: firstCard.organizationName.isEmpty ? secondCard.organizationName : firstCard.organizationName,
            phoneHandles: pooledPhoneHandles,
            emailHandles: pooledEmailHandles
        )
        // Keep the id of the card the message will actually go to, so the
        // confirmation panel shows that card's photo.
        let chosenHandleValue = pooledContact.preferredMessagingHandle?.value
        let cardOwningChosenHandle = (secondCard.phoneHandles + secondCard.emailHandles)
            .contains { $0.value == chosenHandleValue } ? secondCard : firstCard
        return ContactRecord(
            identifier: cardOwningChosenHandle.identifier,
            givenName: pooledContact.givenName,
            familyName: pooledContact.familyName,
            nickname: pooledContact.nickname,
            organizationName: pooledContact.organizationName,
            phoneHandles: pooledContact.phoneHandles,
            emailHandles: pooledContact.emailHandles
        )
    }

    /// Drops handles that are the same number or address written differently —
    /// phone numbers compared on their last ten digits, emails case-insensitively.
    private static func handlesWithoutDuplicates(_ handles: [ContactHandle]) -> [ContactHandle] {
        var seenHandleKeys = Set<String>()
        return handles.filter { handle in
            let handleKey: String
            switch handle.kind {
            case .phoneNumber: handleKey = String(handle.value.filter(\.isNumber).suffix(10))
            case .emailAddress: handleKey = handle.value.lowercased()
            }
            return seenHandleKeys.insert(handleKey).inserted
        }
    }
}

/// Whether a spoken recipient is already a phone number or email address, in
/// which case no contact lookup is needed.
enum DirectMessagingHandleParser {
    /// "+1 555 010 9999", "(555) 010-9999" → the number; an email → itself.
    static func handle(from spokenRecipient: String) -> ContactHandle? {
        let trimmedRecipient = spokenRecipient.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedRecipient.range(of: #"^[^\s@]+@[^\s@]+\.[a-z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return ContactHandle(kind: .emailAddress, value: trimmedRecipient, label: "")
        }

        let allowedPhoneCharacters = CharacterSet(charactersIn: "0123456789+-() .")
        guard !trimmedRecipient.isEmpty,
              trimmedRecipient.unicodeScalars.allSatisfy({ allowedPhoneCharacters.contains($0) }) else { return nil }
        let digitCount = trimmedRecipient.filter(\.isNumber).count
        // Short codes and real numbers are 5–15 digits; fewer is not a number.
        guard (5...15).contains(digitCount) else { return nil }
        return ContactHandle(kind: .phoneNumber, value: trimmedRecipient, label: "")
    }
}

/// Reads the user's Contacts on this Mac.
@MainActor
final class ContactsDirectory {
    static let shared = ContactsDirectory()

    enum DirectoryError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "i can't see your contacts — allow Wisp under System Settings → Privacy & Security → Contacts."
            }
        }
    }

    private let contactStore = CNContactStore()

    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    /// Asks for Contacts access the first time; afterwards answers from the
    /// recorded choice without prompting.
    func ensureAccess() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            let wasGranted = (try? await contactStore.requestAccess(for: .contacts)) ?? false
            if !wasGranted { throw DirectoryError.accessDenied }
        default:
            // Denied, restricted, or limited to a picked subset we can't search.
            throw DirectoryError.accessDenied
        }
    }

    /// The contact's photo thumbnail, for the message confirmation panel. Nil
    /// without access, for an unknown id, or when the card has no photo.
    /// Never prompts — by the time a send is confirmed, access was already asked.
    func thumbnailImage(forContactIdentifier contactIdentifier: String) async -> NSImage? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let contactStore = self.contactStore
        let thumbnailImageData = await Task.detached(priority: .userInitiated) { () -> Data? in
            let photoKeys: [CNKeyDescriptor] = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
            let photoContact = try? contactStore.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: photoKeys)
            return photoContact?.thumbnailImageData
        }.value
        guard let thumbnailImageData else { return nil }
        return NSImage(data: thumbnailImageData)
    }

    /// Who `spokenName` refers to. See `ContactMatcher.resolve`.
    func resolve(
        spokenName: String,
        weakestAcceptedStrength: ContactMatcher.MatchStrength = .wordPrefixes
    ) async throws -> ContactMatcher.Resolution {
        try await ensureAccess()
        let contactStore = self.contactStore
        // Enumerating the address book is synchronous and can take a moment on
        // a large one, so it runs off the main actor.
        let (allContacts, relatedNamesByLabel) = try await Task.detached(priority: .userInitiated) {
            (try Self.fetchAllContactRecords(from: contactStore), Self.fetchMeCardRelations(from: contactStore))
        }.value
        return ContactMatcher.resolve(
            spokenName: spokenName,
            among: allContacts,
            weakestAcceptedStrength: weakestAcceptedStrength,
            relatedContactNamesByRelationLabel: relatedNamesByLabel
        )
    }

    nonisolated private static func fetchAllContactRecords(from contactStore: CNContactStore) throws -> [ContactRecord] {
        var contactRecords: [ContactRecord] = []
        let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
        try contactStore.enumerateContacts(with: fetchRequest) { contact, _ in
            contactRecords.append(contactRecord(from: contact))
        }
        return contactRecords
    }

    /// The user's own card's relations ("mother" → "Jane Doe"), used to
    /// resolve "mom". Empty when there is no Me card or it lists none.
    nonisolated private static func fetchMeCardRelations(from contactStore: CNContactStore) -> [String: String] {
        let relationKeys: [CNKeyDescriptor] = [CNContactRelationsKey as CNKeyDescriptor]
        guard let meContact = try? contactStore.unifiedMeContactWithKeys(toFetch: relationKeys) else { return [:] }
        var relatedNamesByLabel: [String: String] = [:]
        for labeledRelation in meContact.contactRelations {
            guard let rawLabel = labeledRelation.label else { continue }
            let readableLabel = CNLabeledValue<CNContactRelation>.localizedString(forLabel: rawLabel).lowercased()
            relatedNamesByLabel[readableLabel] = labeledRelation.value.name
        }
        return relatedNamesByLabel
    }

    nonisolated private static func contactRecord(from contact: CNContact) -> ContactRecord {
        let phoneHandles = contact.phoneNumbers.map { labeledPhoneNumber in
            ContactHandle(
                kind: .phoneNumber,
                value: labeledPhoneNumber.value.stringValue,
                label: readableLabel(labeledPhoneNumber.label)
            )
        }
        let emailHandles = contact.emailAddresses.map { labeledEmailAddress in
            ContactHandle(
                kind: .emailAddress,
                value: labeledEmailAddress.value as String,
                label: readableLabel(labeledEmailAddress.label)
            )
        }
        return ContactRecord(
            identifier: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            nickname: contact.nickname,
            organizationName: contact.organizationName,
            phoneHandles: phoneHandles,
            emailHandles: emailHandles
        )
    }

    /// `_$!<Mobile>!$_` → "mobile".
    nonisolated private static func readableLabel(_ rawLabel: String?) -> String {
        guard let rawLabel else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: rawLabel).lowercased()
    }
}
