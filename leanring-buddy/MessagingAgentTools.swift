//
//  MessagingAgentTools.swift
//  leanring-buddy
//
//  The agent's Messages and Contacts tools: `send_imessage` and the read-only
//  `find_contact`.
//
//  `send_imessage` resolves the recipient before asking (the registry's input
//  preparation step), so the confirmation card names the real person and
//  number. It always asks — "send" is on `ToolCallSafety`'s always-irreversible
//  list, so session auto-approve never skips it — because a message sent in
//  the user's name cannot be taken back.
//

import Foundation

enum MessagingToolNames {
    static let sendIMessage = "send_imessage"
    static let findContact = "find_contact"
}

extension AgentToolRegistry {

    /// Registers `send_imessage` and `find_contact`.
    func registerMessagingTools() {
        register(
            BuddyToolDefinition(
                name: MessagingToolNames.sendIMessage,
                description: "Send an iMessage or text from the user's Messages app to someone in their Contacts (or a phone number/email). Use when the user asks to text or message someone. The user is always shown the message and asked before it sends.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "to": .object([
                            "type": .string("string"),
                            "description": .string("Who to send it to, as the user said it: a contact name like \"mom\" or \"sarah chen\", or a phone number or email.")
                        ]),
                        "message": .object([
                            "type": .string("string"),
                            "description": .string("The exact message text to send, written as the user would write it to that person.")
                        ])
                    ]),
                    "required": .array([.string("to"), .string("message")])
                ]),
                // Speaks in the user's name, beyond this Mac.
                metadata: ToolMetadata(readOnly: false, externalSideEffect: true, dataSource: .localMachine)
            ),
            preparingInputWith: { input in
                await Self.prepareSendIMessageInput(input)
            }
        ) { preparedInput in
            // Only the prepared fields are trusted: the handle comes from the
            // user's Contacts (or a number they said), never from the model.
            guard case .object(let preparedArguments) = preparedInput,
                  case .string(let recipientDisplayName)? = preparedArguments["to"],
                  case .string(let recipientHandleValue)? = preparedArguments["handle"],
                  case .string(let messageText)? = preparedArguments["message"] else {
                return "i couldn't work out who to send that to."
            }
            let recipientHandle = ContactHandle(
                kind: recipientHandleValue.contains("@") ? .emailAddress : .phoneNumber,
                value: recipientHandleValue,
                label: ""
            )
            let deliveryService = try MessagesAppSender.send(messageText: messageText, to: recipientHandle)
            let deliveryServiceName = deliveryService == .iMessage ? "imessage" : "text"
            return "sent to \(recipientDisplayName) by \(deliveryServiceName)."
        }

        register(
            BuddyToolDefinition(
                name: MessagingToolNames.findContact,
                description: "Look up someone in the user's Contacts by name and get their phone numbers and email addresses.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["name": .object([
                        "type": .string("string"),
                        "description": .string("The person's name, e.g. \"sarah\" or \"sarah chen\", or a relation like \"mom\".")
                    ])]),
                    "required": .array([.string("name")])
                ]),
                metadata: .reading(.localMachine)
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let spokenName)? = arguments["name"],
                  !spokenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "i need a name to look up."
            }
            switch try await ContactsDirectory.shared.resolve(spokenName: spokenName) {
            case .matched(let contact):
                return Self.contactSummaryLine(for: contact)
            case .ambiguous(let matchingContacts):
                return "several contacts match:\n" + matchingContacts.prefix(5).map(Self.contactSummaryLine(for:)).joined(separator: "\n")
            case .noMatch:
                return "no contact matches \"\(spokenName)\"."
            }
        }
    }

    /// `{to, message}` from the model → `{to: display name, handle, message}`,
    /// or the reason it can't be sent (no such contact, several of them).
    static func prepareSendIMessageInput(_ input: JSONValue) async -> ToolInputPreparation {
        guard case .object(let arguments) = input,
              case .string(let spokenRecipient)? = arguments["to"],
              case .string(let messageText)? = arguments["message"],
              !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .finished("i need who to send it to and what the message says.")
        }
        let recipientResolution = await MessageRecipientResolver.resolve(candidates: [
            MessageCommandCandidate(recipient: spokenRecipient, messageText: messageText, isRecipientBoundaryCertain: true)
        ])
        switch recipientResolution {
        case .resolved(let resolvedOutgoingMessage):
            return .ready(sendIMessageToolInput(for: resolvedOutgoingMessage))
        case .cannotSend(let reason):
            return .finished(reason)
        case .notAMessageCommand:
            return .finished("i couldn't find \(spokenRecipient) in the user's contacts.")
        }
    }

    /// The prepared input shape, shared with the direct "text mom …" route so
    /// both ask with the same card.
    static func sendIMessageToolInput(for resolvedOutgoingMessage: ResolvedOutgoingMessage) -> JSONValue {
        var preparedFields: [String: JSONValue] = [
            "to": .string(resolvedOutgoingMessage.recipientDisplayName),
            "handle": .string(resolvedOutgoingMessage.recipientHandle.value),
            "message": .string(resolvedOutgoingMessage.messageText),
        ]
        // Only ever set here, from the resolved contact — the preparer builds a
        // fresh object, so a model-written id never survives to the panel.
        if let recipientContactIdentifier = resolvedOutgoingMessage.recipientContactIdentifier {
            preparedFields["contact_id"] = .string(recipientContactIdentifier)
        }
        return .object(preparedFields)
    }

    private static func contactSummaryLine(for contact: ContactRecord) -> String {
        let handleDescriptions = (contact.phoneHandles + contact.emailHandles).prefix(4).map { contactHandle in
            contactHandle.label.isEmpty ? contactHandle.value : "\(contactHandle.label) \(contactHandle.value)"
        }
        guard !handleDescriptions.isEmpty else { return "\(contact.displayName) (no phone or email)" }
        return "\(contact.displayName): " + handleDescriptions.joined(separator: ", ")
    }
}
