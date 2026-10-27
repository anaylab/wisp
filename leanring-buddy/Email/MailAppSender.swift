//
//  MailAppSender.swift
//  leanring-buddy
//
//  Hands a finished draft to the Mail app: either sends it from the user's
//  default Mail account, or opens it as a Mail compose window to keep working
//  on there. Only ever called from the email composer's own buttons — the user
//  pressing Send on a draft they could see and edit is the consent.
//
//  Like `MessagesAppSender`, the script is fixed and everything in the draft
//  (addresses, subject, body) arrives as Apple Event handler parameters, never
//  spliced into source, so nothing typed in an email can change what runs.
//

import Carbon
import Foundation

@MainActor
enum MailAppSender {

    enum SendError: LocalizedError {
        case automationNotAllowed
        case noMailAccount
        case mailDidNotSend
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .automationNotAllowed:
                return "Wisp isn't allowed to control Mail. Allow it in System Settings → Privacy & Security → Automation → Mail, or use Open in Gmail."
            case .noMailAccount:
                return "Mail has no email account set up on this Mac. Add one in Mail, or use Open in Gmail."
            case .mailDidNotSend:
                return "Mail didn't send it. Open it in Mail to see why."
            case .sendFailed(let reason):
                return "Mail couldn't send that: \(reason)"
            }
        }
    }

    /// Builds the message in Mail, adds each recipient, then sends it or shows
    /// it. Arguments are handler parameters, so the draft's text is inert.
    private static let mailScriptSource = """
    on wispcomposeemail(toAddresses, ccAddresses, subjectText, bodyText, shouldSendNow)
        tell application "Mail"
            if (count of accounts) is 0 then error "no mail account" number 4243
            set newMessage to make new outgoing message with properties {subject:subjectText, content:bodyText, visible:(not shouldSendNow)}
            tell newMessage
                repeat with recipientAddress in toAddresses
                    make new to recipient at end of to recipients with properties {address:(recipientAddress as text)}
                end repeat
                repeat with recipientAddress in ccAddresses
                    make new cc recipient at end of cc recipients with properties {address:(recipientAddress as text)}
                end repeat
            end tell
            if shouldSendNow then
                set didSend to send newMessage
                if didSend is false then error "mail did not send" number 4244
            else
                activate
            end if
        end tell
        return "ok"
    end wispcomposeemail
    """

    /// Sends the draft from Mail's default account. Blocks the main actor
    /// while Mail takes it (longer the first time, if Mail has to launch).
    static func send(_ draftFields: EmailDraftFields) throws {
        try run(draftFields, shouldSendNow: true)
    }

    /// Opens the draft as a Mail compose window, unsent.
    static func openInMail(_ draftFields: EmailDraftFields) throws {
        try run(draftFields, shouldSendNow: false)
    }

    private static func run(_ draftFields: EmailDraftFields, shouldSendNow: Bool) throws {
        guard let mailScript = NSAppleScript(source: mailScriptSource) else {
            throw SendError.sendFailed("the Mail script could not be prepared")
        }

        let handlerParameters = NSAppleEventDescriptor.list()
        handlerParameters.insert(addressListDescriptor(EmailAddressList.parse(draftFields.toField).addresses), at: 1)
        handlerParameters.insert(addressListDescriptor(EmailAddressList.parse(draftFields.ccField).addresses), at: 2)
        handlerParameters.insert(NSAppleEventDescriptor(string: draftFields.subject), at: 3)
        handlerParameters.insert(NSAppleEventDescriptor(string: draftFields.body), at: 4)
        handlerParameters.insert(NSAppleEventDescriptor(boolean: shouldSendNow), at: 5)

        let handlerCallEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        // AppleScript handler names are case-insensitive and stored lowercased.
        handlerCallEvent.setDescriptor(
            NSAppleEventDescriptor(string: "wispcomposeemail"),
            forKeyword: AEKeyword(keyASSubroutineName)
        )
        handlerCallEvent.setDescriptor(handlerParameters, forKeyword: AEKeyword(keyDirectObject))

        var scriptErrorInfo: NSDictionary?
        _ = mailScript.executeAppleEvent(handlerCallEvent, error: &scriptErrorInfo)

        if let scriptErrorInfo {
            let scriptErrorNumber = (scriptErrorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let scriptErrorMessage = (scriptErrorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            print("⚠️ Mail compose failed (\(scriptErrorNumber)): \(scriptErrorMessage)")
            switch scriptErrorNumber {
            case -1743: throw SendError.automationNotAllowed
            case 4243: throw SendError.noMailAccount
            case 4244: throw SendError.mailDidNotSend
            default: throw SendError.sendFailed(scriptErrorMessage)
            }
        }
    }

    private static func addressListDescriptor(_ addresses: [String]) -> NSAppleEventDescriptor {
        let addressList = NSAppleEventDescriptor.list()
        for (addressIndex, address) in addresses.enumerated() {
            addressList.insert(NSAppleEventDescriptor(string: address), at: addressIndex + 1)
        }
        return addressList
    }
}
