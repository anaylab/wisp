//
//  CodingAgentTerminalJumper.swift
//  leanring-buddy
//
//  "Jump to terminal": brings the window a coding agent is running in to the
//  front — the exact iTerm session or Terminal.app tab when the relay
//  captured enough to find it, the project's window in VS Code or Cursor, or
//  at least the terminal app.
//
//  iTerm and Terminal are reached with AppleScript (Automation permission,
//  asked by macOS the first time). The session id and tty are passed as
//  handler parameters, never spliced into the script source.
//

import AppKit
import Carbon
import Foundation

enum CodingAgentTerminalJumper {
    /// Bundle identifiers for the `TERM_PROGRAM` values terminals set.
    private static let bundleIdentifierByTerminalProgram: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "kitty": "net.kovidgoyal.kitty",
        "Hyper": "co.zeit.hyper",
        "Tabby": "org.tabby",
    ]

    /// Tried in order when the session didn't say which terminal it's in.
    private static let fallbackTerminalBundleIdentifiers = [
        "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.apple.Terminal",
    ]

    private static let visualStudioCodeBundleIdentifier = "com.microsoft.VSCode"

    /// Returns false when nothing could be brought forward.
    @discardableResult
    static func jump(to session: CodingAgentSession) -> Bool {
        let terminalContext = session.terminalContext

        // An editor's integrated terminal: open the project folder in that
        // editor, which focuses the window that already has it open. Cursor,
        // Windsurf and friends report TERM_PROGRAM=vscode too; the host app's
        // bundle id tells them apart.
        if terminalContext.terminalProgram.lowercased() == "vscode" {
            let editorBundleIdentifier = terminalContext.hostApplicationBundleIdentifier.isEmpty
                ? visualStudioCodeBundleIdentifier
                : terminalContext.hostApplicationBundleIdentifier
            if openProjectFolder(session.workingDirectoryPath, inApplicationWithBundleIdentifier: editorBundleIdentifier) {
                return true
            }
        }

        if terminalContext.terminalProgram == "iTerm.app",
           let iTermUniqueSessionID = iTermUniqueSessionID(from: terminalContext.iTermSessionIdentifier),
           runAppleScriptHandler(source: iTermSelectSessionScript, handlerName: "selectsession", argument: iTermUniqueSessionID) {
            return true
        }

        if terminalContext.terminalProgram == "Apple_Terminal",
           !terminalContext.terminalDevicePath.isEmpty,
           runAppleScriptHandler(source: terminalSelectTabScript, handlerName: "selecttab", argument: terminalContext.terminalDevicePath) {
            return true
        }

        if let bundleIdentifier = bundleIdentifierByTerminalProgram[terminalContext.terminalProgram],
           activateRunningApplication(withBundleIdentifier: bundleIdentifier) {
            return true
        }
        if !terminalContext.hostApplicationBundleIdentifier.isEmpty,
           activateRunningApplication(withBundleIdentifier: terminalContext.hostApplicationBundleIdentifier) {
            return true
        }
        return fallbackTerminalBundleIdentifiers.contains { activateRunningApplication(withBundleIdentifier: $0) }
    }

    /// Whether the app the session runs in is the frontmost app — the user is
    /// already watching it, so the notch needn't announce it.
    static func isSessionHostFrontmost(_ session: CodingAgentSession) -> Bool {
        guard let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        let terminalContext = session.terminalContext
        if !terminalContext.hostApplicationBundleIdentifier.isEmpty {
            return terminalContext.hostApplicationBundleIdentifier == frontmostBundleIdentifier
        }
        if terminalContext.terminalProgram.lowercased() == "vscode" {
            return frontmostBundleIdentifier == visualStudioCodeBundleIdentifier
        }
        return bundleIdentifierByTerminalProgram[terminalContext.terminalProgram] == frontmostBundleIdentifier
    }

    /// "w0t1p0:6E1F…" → "6E1F…", the id iTerm's AppleScript `unique id` uses.
    static func iTermUniqueSessionID(from iTermSessionIdentifier: String) -> String? {
        guard let separatorIndex = iTermSessionIdentifier.firstIndex(of: ":") else { return nil }
        let uniqueSessionID = String(iTermSessionIdentifier[iTermSessionIdentifier.index(after: separatorIndex)...])
        return uniqueSessionID.isEmpty ? nil : uniqueSessionID
    }

    private static func activateRunningApplication(withBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }
        return runningApplication.activate()
    }

    private static func openProjectFolder(_ folderPath: String, inApplicationWithBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        guard !folderPath.isEmpty else {
            return activateRunningApplication(withBundleIdentifier: bundleIdentifier)
        }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: folderPath, isDirectory: true)],
            withApplicationAt: applicationURL,
            configuration: openConfiguration
        )
        return true
    }

    // MARK: - AppleScript

    private static let iTermSelectSessionScript = """
    on selectsession(targetSessionID)
        tell application "iTerm2"
            repeat with candidateWindow in windows
                repeat with candidateTab in tabs of candidateWindow
                    repeat with candidateSession in sessions of candidateTab
                        if unique id of candidateSession is targetSessionID then
                            select candidateWindow
                            tell candidateTab to select
                            tell candidateSession to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
    end selectsession
    """

    private static let terminalSelectTabScript = """
    on selecttab(targetTTY)
        tell application "Terminal"
            repeat with candidateWindow in windows
                repeat with candidateTab in tabs of candidateWindow
                    if tty of candidateTab is targetTTY then
                        set selected of candidateTab to true
                        set index of candidateWindow to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
    end selecttab
    """

    /// Calls a one-argument handler in `source` and returns its boolean result.
    /// The argument travels as an Apple Event parameter, so nothing the agent
    /// reported can change what the script does.
    private static func runAppleScriptHandler(source: String, handlerName: String, argument: String) -> Bool {
        guard let appleScript = NSAppleScript(source: source) else { return false }
        var compileError: NSDictionary?
        guard appleScript.compileAndReturnError(&compileError) else { return false }

        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(NSAppleEventDescriptor(string: argument), at: 1)

        let handlerEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        handlerEvent.setDescriptor(NSAppleEventDescriptor(string: handlerName), forKeyword: AEKeyword(keyASSubroutineName))
        handlerEvent.setDescriptor(parameters, forKeyword: AEKeyword(keyDirectObject))

        var executionError: NSDictionary?
        let resultDescriptor = appleScript.executeAppleEvent(handlerEvent, error: &executionError)
        if let executionError {
            print("⚠️ Coding agents: jump script failed: \(executionError)")
            return false
        }
        return resultDescriptor.booleanValue
    }
}
