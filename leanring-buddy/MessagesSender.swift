//
//  MessagesSender.swift
//  leanring-buddy
//
//  Sends an iMessage (or a text, through iPhone relay) from the user's own
//  Messages app — "text mom i'm running late", the way Siri does it.
//
//  Two steps, and consent sits between them. `MessageRecipientResolver` turns
//  what the user said into one concrete person and handle ("Mom" → Jane Doe,
//  +1 555 010 9999) *before* anything is asked, so the confirmation card shows
//  exactly who the message goes to, not the word the user happened to say.
//  Only after the user allows it does `MessagesAppSender` hand it to Messages.
//
//  The send itself is AppleScript, the only public way to drive Messages. The
//  recipient and text are passed to a handler as Apple Event parameters rather
//  than spliced into the script's source, so nothing in a message — quotes,
//  backslashes, a line that looks like AppleScript — can change what runs.
//

import Carbon
import Foundation

/// A message ready to send: who it goes to, by which handle, and what it says.
struct ResolvedOutgoingMessage: Equatable {
    let recipientDisplayName: String
    let recipientHandle: ContactHandle
    let messageText: String
    /// The Contacts card it came from, for its photo on the confirmation
    /// panel. Nil when the user gave a number or address outright.
    var recipientContactIdentifier: String? = nil
}

/// Turns a spoken recipient into one person and handle.
@MainActor
enum MessageRecipientResolver {

    enum Resolution: Equatable {
        case resolved(ResolvedOutgoingMessage)
        /// Why it can't be sent yet, phrased for the user ("i found two alexes…").
        case cannotSend(String)
        /// Every reading was a guessed split and none named a contact — "text
        /// size bigger" is not a message, so the request should go to the model.
        case notAMessageCommand
    }

    /// Resolves the first candidate whose recipient is someone in Contacts (or
    /// a number/address given outright).
    ///
    /// Candidates come longest recipient first when the command gave no clear
    /// boundary between name and message ("text sarah chen see you soon"), so
    /// "sarah chen" is tried before "sarah". Those guessed splits must match a
    /// name exactly; a recipient the user set off clearly ("text sarah saying
    /// …") may match more loosely.
    static func resolve(candidates: [MessageCommandCandidate]) async -> Resolution {
        var firstUnresolvedReply: String?
        var sawCertainCandidate = false

        for candidate in candidates {
            let trimmedMessageText = candidate.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMessageText.isEmpty else { continue }
            if candidate.isRecipientBoundaryCertain { sawCertainCandidate = true }

            if let directHandle = DirectMessagingHandleParser.handle(from: candidate.recipient) {
                return .resolved(ResolvedOutgoingMessage(
                    recipientDisplayName: directHandle.value,
                    recipientHandle: directHandle,
                    messageText: trimmedMessageText
                ))
            }

            let contactResolution: ContactMatcher.Resolution
            do {
                contactResolution = try await ContactsDirectory.shared.resolve(
                    spokenName: candidate.recipient,
                    weakestAcceptedStrength: candidate.isRecipientBoundaryCertain ? .wordPrefixes : .exactFamilyOrOrganizationName
                )
            } catch {
                return .cannotSend(error.localizedDescription)
            }

            switch contactResolution {
            case .matched(let contact):
                guard let messagingHandle = contact.preferredMessagingHandle else {
                    return .cannotSend("\(contact.displayName) has no phone number or email in your contacts, so i can't message them.")
                }
                return .resolved(ResolvedOutgoingMessage(
                    recipientDisplayName: contact.displayName,
                    recipientHandle: messagingHandle,
                    messageText: trimmedMessageText,
                    recipientContactIdentifier: contact.identifier
                ))

            case .ambiguous(let matchingContacts):
                // An ambiguous name stops here rather than trying a shorter
                // split: "alex" matching two people is the answer to give.
                let listedNames = matchingContacts.prefix(4).map(\.displayName).joined(separator: ", ")
                return .cannotSend("i found more than one \(candidate.recipient) — \(listedNames). say the full name and i'll send it.")

            case .noMatch:
                if candidate.isRecipientBoundaryCertain && firstUnresolvedReply == nil {
                    firstUnresolvedReply = "i couldn't find \(candidate.recipient) in your contacts."
                }
            }
        }
        guard sawCertainCandidate else { return .notAMessageCommand }
        return .cannotSend(firstUnresolvedReply ?? "i need who to send it to and what to say.")
    }
}

/// Hands a message to the Messages app.
@MainActor
enum MessagesAppSender {

    enum SendError: LocalizedError {
        case automationNotAllowed
        case messagesNotSetUp
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .automationNotAllowed:
                return "i'm not allowed to control Messages — allow Wisp under System Settings → Privacy & Security → Automation → Messages."
            case .messagesNotSetUp:
                return "Messages isn't signed in to iMessage or text messaging on this Mac, so i couldn't send it."
            case .sendFailed(let reason):
                return "Messages couldn't send that: \(reason)"
            }
        }
    }

    /// How the message went out.
    enum DeliveryService: String {
        case iMessage = "imessage"
        case textMessage = "sms"
    }

    /// Tries iMessage first and falls back to SMS (which only works with
    /// iPhone text-message forwarding on). Arguments arrive as handler
    /// parameters — never part of the source — so message text is inert.
    private static let sendMessageScriptSource = """
    on sendwispmessage(targetHandle, messageText)
        tell application "Messages"
            try
                set iMessageAccount to 1st account whose service type = iMessage
                send messageText to participant targetHandle of iMessageAccount
                return "imessage"
            on error iMessageErrorText number iMessageErrorNumber
                if iMessageErrorNumber is -1743 then error iMessageErrorText number iMessageErrorNumber
                try
                    set textMessageAccount to 1st account whose service type = SMS
                    send messageText to participant targetHandle of textMessageAccount
                    return "sms"
                on error textMessageErrorText number textMessageErrorNumber
                    if textMessageErrorNumber is -1743 then error textMessageErrorText number textMessageErrorNumber
                    error "no messaging account" number 4242
                end try
            end try
        end tell
    end sendwispmessage
    """

    /// Sends `messageText` to `recipientHandle`. Runs AppleScript, so it blocks
    /// the main actor briefly — about as long as Messages takes to accept it.
    @discardableResult
    static func send(messageText: String, to recipientHandle: ContactHandle) throws -> DeliveryService {
        guard let sendMessageScript = NSAppleScript(source: sendMessageScriptSource) else {
            throw SendError.sendFailed("the send script could not be prepared")
        }

        let handlerParameters = NSAppleEventDescriptor.list()
        handlerParameters.insert(NSAppleEventDescriptor(string: recipientHandle.value), at: 1)
        handlerParameters.insert(NSAppleEventDescriptor(string: messageText), at: 2)

        let handlerCallEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        // AppleScript handler names are case-insensitive and stored lowercased.
        handlerCallEvent.setDescriptor(
            NSAppleEventDescriptor(string: "sendwispmessage"),
            forKeyword: AEKeyword(keyASSubroutineName)
        )
        handlerCallEvent.setDescriptor(handlerParameters, forKeyword: AEKeyword(keyDirectObject))

        var scriptErrorInfo: NSDictionary?
        // Declared non-null but nil on failure, hence the explicit optional.
        let scriptResult: NSAppleEventDescriptor? = sendMessageScript.executeAppleEvent(handlerCallEvent, error: &scriptErrorInfo)

        if let scriptErrorInfo {
            let scriptErrorNumber = (scriptErrorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let scriptErrorMessage = (scriptErrorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            print("⚠️ Messages send failed (\(scriptErrorNumber)): \(scriptErrorMessage)")
            switch scriptErrorNumber {
            case -1743: throw SendError.automationNotAllowed
            case 4242: throw SendError.messagesNotSetUp
            default: throw SendError.sendFailed(scriptErrorMessage)
            }
        }
        return DeliveryService(rawValue: scriptResult?.stringValue ?? "") ?? .iMessage
    }
}
