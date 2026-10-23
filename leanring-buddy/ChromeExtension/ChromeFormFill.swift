//
//  ChromeFormFill.swift
//  leanring-buddy
//
//  The form helper (phase 12): "fill this form" in Chrome. Wisp reads the
//  form's fields through the extension (labels and kinds, never values),
//  proposes values from the user's own sources — the Me card and the brain's
//  me page (memory.md while the brain is off) — and shows them on one editable
//  confirmation card. Only after Allow does the extension type them in. It
//  never submits: the user presses the page's own button.
//
//  The safety story, end to end:
//   * the content script refuses secret fields and hidden trap fields itself,
//     and `FormFillRefusal` refuses them again here, before the card;
//   * the model never writes a value. The tool's input preparation ignores
//     the model's arguments (beyond which tab) and builds the input from the
//     form and the user's sources; a model may only map leftover labels to key
//     names (`FormFieldLabelMappingPrompt`), seeing labels, never values;
//   * `fill_form` is on `ToolCallSafety.alwaysAskBareToolNames`, so the card
//     shows even under session auto-approve, and the edits it allows are only
//     the proposed values (`FormFillCards.editableFields`);
//   * the fill is refused if the tab moved to another page since Wisp looked.
//
//  The pure rules are in FormFillPlanner.swift and FormFillCards.swift.
//

import Contacts
import Foundation

@MainActor
enum ChromeFormFill {

    /// Reading a form waits a little longer than a page-text read: the scripts
    /// may need injecting first.
    static let describeTimeoutSeconds: Double = 12
    static let fillTimeoutSeconds: Double = 15

    // MARK: - The tool

    static let toolDefinition = BuddyToolDefinition(
        name: FormFillToolNames.fillForm,
        description: "Fill the form on the Chrome page the user is looking at (sign-up, application, contact form) with their own details — name, email, phone, school, address, short bio — from their Me card and what Wisp remembers about them. Wisp proposes the values itself; never pass any. It never fills passwords, payment details, ids, codes or security questions, shows every value for the user to check and edit first, and never submits.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "tab_id": .object([
                    "type": .string("integer"),
                    "description": .string("A tab id from chrome_list_tabs. Leave out for the tab the user is looking at.")
                ])
            ])
        ]),
        // Types into a page the user then submits; recoverable (nothing is sent),
        // so it asks once — and `ToolCallSafety` makes sure it always asks.
        metadata: .writing(.localMachine)
    )

    // MARK: - Spoken route

    /// "fill this form": the same tool, so the same card and the same rules.
    static func performSpokenFill() async -> (replyText: String, didSucceed: Bool) {
        let outcome = await AgentToolRegistry.shared.invoke(name: FormFillToolNames.fillForm, input: .object([:]))
        return (outcome.content, !outcome.isError && !outcome.wasDeclined)
    }

    // MARK: - Before the card

    /// The model's `{tab_id?}` → the prepared input the card shows, or the
    /// reason there's nothing to fill. Only `tab_id` is read from the model.
    static func prepareInput(_ modelInput: JSONValue) async -> AgentToolRegistry.ToolInputPreparation {
        var requestedTabID: Int?
        if case .object(let arguments) = modelInput, case .number(let numericTabID)? = arguments["tab_id"] {
            requestedTabID = Int(exactly: numericTabID)
        }

        let formDescription: FormDescription
        do {
            formDescription = try await ChromeSiteHelpers.sendRequest(
                method: "describeForm",
                parameters: DescribeFormParameters(tabId: requestedTabID),
                resultType: FormDescription.self,
                timeoutSeconds: describeTimeoutSeconds
            )
        } catch {
            return .finished(error.localizedDescription)
        }
        guard !formDescription.fields.isEmpty else {
            return .finished("i don't see a form on this page.")
        }

        let profile = await readProfile()
        guard !profile.isEmpty else {
            return .finished("i don't know your details yet — fill in your Me card in Contacts, or tell me things like \"remember my school is …\", then ask again.")
        }

        var modelMappedKeys: [String: FormProfileKey] = [:]
        let leftoverFields = FormFillPlanner.leftoverFields(in: formDescription.fields, profile: profile)
        let deterministicPlan = FormFillPlanner.plan(fields: formDescription.fields, profile: profile)
        let usedKeys = Set(deterministicPlan.proposals.map(\.key))
        let unusedKnownKeys = profile.knownKeys.filter { !usedKeys.contains($0) }
        if !leftoverFields.isEmpty && !unusedKnownKeys.isEmpty {
            modelMappedKeys = await mapLeftoverLabelsWithModel(leftoverFields: leftoverFields, availableKeys: unusedKnownKeys)
        }
        let plan = modelMappedKeys.isEmpty
            ? deterministicPlan
            : FormFillPlanner.plan(fields: formDescription.fields, profile: profile, modelMappedKeys: modelMappedKeys)

        guard !plan.proposals.isEmpty else {
            return .finished(FormFillReplyText.nothingToFill(plan: plan))
        }
        return .ready(FormFillCards.preparedToolInput(
            plan: plan,
            tabID: formDescription.tabId,
            pageURL: formDescription.url,
            formLabel: formDescription.formLabel
        ))
    }

    /// Me card first, then the brain's me page (or memory.md with the brain off).
    static func readProfile() async -> FormProfile {
        let meCard = await readMeCard()
        let memoryStore = MemoryStore.shared
        memoryStore.reloadIfFileChanged()
        let mePageSummary = BrainPreferences.shared.isBrainEnabled ? BrainStore.shared.mePage?.summary : nil
        return FormProfile.build(meCard: meCard, mePageFacts: memoryStore.facts, mePageSummary: mePageSummary)
    }

    /// The user's own contact card, or nil without one or without access.
    /// Asks for Contacts access the first time: the user just asked Wisp to
    /// fill in their details, and the card is where they keep them.
    private static func readMeCard() async -> FormMeCardDetails? {
        let contactStore = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            break
        case .notDetermined:
            guard (try? await contactStore.requestAccess(for: .contacts)) == true else { return nil }
        default:
            return nil
        }
        return await Task.detached(priority: .userInitiated) { () -> FormMeCardDetails? in
            let meCardKeys: [CNKeyDescriptor] = [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
                CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey,
            ].map { $0 as CNKeyDescriptor }
            guard let meContact = try? contactStore.unifiedMeContactWithKeys(toFetch: meCardKeys) else { return nil }
            var details = FormMeCardDetails()
            details.givenName = meContact.givenName
            details.familyName = meContact.familyName
            details.organizationName = meContact.organizationName
            details.jobTitle = meContact.jobTitle
            details.emailAddresses = meContact.emailAddresses.map { $0.value as String }
            details.phoneNumbers = meContact.phoneNumbers.map { $0.value.stringValue }
            details.websites = meContact.urlAddresses.map { $0.value as String }
            // Home first, then whatever address there is.
            let postalAddresses = meContact.postalAddresses
            let chosenAddress = (postalAddresses.first { $0.label == CNLabelHome } ?? postalAddresses.first)?.value
            if let chosenAddress {
                details.street = chosenAddress.street
                details.city = chosenAddress.city
                details.region = chosenAddress.state
                details.postalCode = chosenAddress.postalCode
                details.country = chosenAddress.country
            }
            return details
        }.value
    }

    /// One text-only call: labels in, key names out. Never a value.
    private static func mapLeftoverLabelsWithModel(
        leftoverFields: [FormFieldDescription],
        availableKeys: [FormProfileKey]
    ) async -> [String: FormProfileKey] {
        let mappingRequest = ModelRequest(
            systemPrompt: FormFieldLabelMappingPrompt.systemPrompt,
            messages: [BuddyChatMessage(
                role: .user,
                text: FormFieldLabelMappingPrompt.userMessage(leftoverFields: leftoverFields, availableKeys: availableKeys)
            )],
            maxOutputTokens: 300,
            temperature: 0
        )
        let modelProvider = ModelProviderFactory.make()
        let mappingTurn = try? await ModelAccessGate.shared.withAccess(priority: .interactive) {
            try await modelProvider.completeTurn(mappingRequest)
        }
        return FormFieldLabelMappingPrompt.parse(
            reply: mappingTurn?.text ?? "", leftoverFields: leftoverFields, availableKeys: availableKeys
        )
    }

    // MARK: - After Allow

    /// Types the allowed (possibly edited) values in, and says what happened.
    static func fill(preparedInput: JSONValue) async throws -> String {
        guard case .object(let inputFields) = preparedInput,
              case .number(let numericTabID)? = inputFields["tab_id"], let tabID = Int(exactly: numericTabID),
              case .string(let pageURL)? = inputFields["page_url"] else {
            return "i lost track of which form that was — ask me again."
        }
        // Refused again by label, whatever the card held: the last lock.
        let proposedFields = FormFillCards.proposedFields(in: preparedInput).filter { proposedField in
            FormFillRefusal.reason(forDescribingText: proposedField.label) == nil
        }
        guard !proposedFields.isEmpty else { return "there was nothing left to fill." }

        let fillReply = try await ChromeSiteHelpers.sendRequest(
            method: "fillFormFields",
            parameters: FillFormFieldsParameters(
                tabId: tabID,
                expectedUrl: pageURL,
                values: proposedFields.map { FillFormFieldsParameters.Value(elementId: $0.elementID, value: $0.value) }
            ),
            resultType: FillFormFieldsReply.self,
            timeoutSeconds: fillTimeoutSeconds
        )
        let labelsByElementID = Dictionary(uniqueKeysWithValues: zip(
            proposedFields.map(\.elementID), FormFillCards.cardLabels(for: proposedFields)
        ))
        let statusesByLabel = fillReply.results.compactMap { result -> (String, String)? in
            guard let label = labelsByElementID[result.elementId] else { return nil }
            return (label, result.status)
        }
        var fieldsForTheUser: [String] = []
        if case .array(let forTheUserValues)? = inputFields["for_the_user"] {
            fieldsForTheUser = forTheUserValues.compactMap { value in
                if case .string(let label) = value { return label }
                return nil
            }
        }
        return FormFillReplyText.afterFilling(statusesByLabel: statusesByLabel, fieldsForTheUser: fieldsForTheUser)
    }

    // MARK: - Wire shapes

    private struct DescribeFormParameters: Encodable {
        let tabId: Int?
    }

    private struct FillFormFieldsParameters: Encodable {
        struct Value: Encodable {
            let elementId: String
            let value: String
        }
        let tabId: Int
        let expectedUrl: String
        let values: [Value]
    }

    private struct FillFormFieldsReply: Decodable {
        struct Result: Decodable {
            let elementId: String
            let status: String
        }
        let results: [Result]
        let filledCount: Int
    }
}

extension AgentToolRegistry {

    /// Always registered: without the extension or its page permission the
    /// reply says how to fix it.
    func registerChromeFormFillTools() {
        register(
            ChromeFormFill.toolDefinition,
            preparingInputWith: { modelInput in
                await ChromeFormFill.prepareInput(modelInput)
            }
        ) { preparedInput in
            try await ChromeFormFill.fill(preparedInput: preparedInput)
        }
    }
}
