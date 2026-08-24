//
//  FastCommandRouter.swift
//  leanring-buddy
//
//  Handles the handful of requests that need no model at all.
//
//  "Open Safari" and "mute" are not questions. Routing them through a 7B vision
//  model costs a second of generation to produce a sentence nobody needed, and
//  on a cold model several seconds more, to do something NSWorkspace does in
//  about ten milliseconds. Recognising them up front is the difference between
//  Wisp feeling like an assistant and feeling like a chat window.
//
//  Deliberately deterministic. A second resident model to classify requests
//  would cost gigabytes on a machine that has none spare, and this job does not
//  need one: the commands worth fast-pathing are a small, closed set with rigid
//  phrasing.
//
//  The design bias throughout is toward *not* matching. A miss costs the user
//  one ordinary model round-trip, which is the behaviour they had anyway. A
//  false positive silently launches something they did not ask for, or worse,
//  answers a real question with "opened Mail". So every pattern requires an
//  explicit verb, and app names are matched against what is actually installed
//  rather than guessed at.
//

import AppKit
import Foundation

@MainActor
enum FastCommandRouter {
    /// What a matched command did, and what to say about it.
    struct Outcome {
        /// Short, spoken. These replace a model answer, so they have to sound
        /// like Wisp rather than like a shell.
        let spokenConfirmation: String
    }

    /// Attempts to handle `transcript` without the model.
    ///
    /// Returns nil for anything not recognised with high confidence, which is
    /// the overwhelming majority of input.
    static func handle(_ transcript: String) -> Outcome? {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))

        guard !normalized.isEmpty else { return nil }

        if let outcome = handleAudioCommand(normalized) { return outcome }
        if let outcome = handleAppLaunch(normalized) { return outcome }
        return nil
    }

    // MARK: - Audio

    private static func handleAudioCommand(_ text: String) -> Outcome? {
        // Whole-utterance matches only. "mute" inside "how do I mute this
        // meeting" is a question about muting, not an instruction to mute.
        switch text {
        case "mute", "mute it", "mute the volume", "be quiet", "silence":
            setMuted(true)
            return Outcome(spokenConfirmation: "muted.")

        case "unmute", "unmute it", "sound on":
            setMuted(false)
            return Outcome(spokenConfirmation: "unmuted.")

        case "volume up", "turn it up", "louder", "turn the volume up":
            adjustVolume(by: 12)
            return Outcome(spokenConfirmation: "turned it up.")

        case "volume down", "turn it down", "quieter", "turn the volume down":
            adjustVolume(by: -12)
            return Outcome(spokenConfirmation: "turned it down.")

        default:
            return nil
        }
    }

    private static func setMuted(_ muted: Bool) {
        runAppleScript("set volume \(muted ? "with" : "without") output muted")
    }

    private static func adjustVolume(by delta: Int) {
        // Read-modify-write rather than a relative command, because AppleScript
        // has no relative form and clamping has to happen somewhere.
        guard let current = Int(runAppleScript("output volume of (get volume settings)") ?? "") else { return }
        let target = max(0, min(100, current + delta))
        runAppleScript("set volume output volume \(target)")
    }

    // MARK: - Launching apps

    /// Verbs that unambiguously mean "launch", paired with nothing else.
    private static let launchPrefixes = ["open ", "launch ", "start ", "go to "]

    private static func handleAppLaunch(_ text: String) -> Outcome? {
        guard let prefix = launchPrefixes.first(where: { text.hasPrefix($0) }) else { return nil }

        var name = String(text.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        // "open up chrome", "open the terminal"
        for filler in ["up ", "the ", "my "] where name.hasPrefix(filler) {
            name = String(name.dropFirst(filler.count))
        }
        guard !name.isEmpty, name.count <= 40 else { return nil }

        // A request with a verb after the noun is a task, not a launch:
        // "open safari and search for x" belongs to the agent, not here.
        let taskIndicators = [" and ", " then ", " to ", " so ", " because "]
        guard !taskIndicators.contains(where: { name.contains($0) }) else { return nil }

        guard let url = applicationURL(matching: name) else { return nil }

        let displayName = url.deletingPathExtension().lastPathComponent
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return Outcome(spokenConfirmation: "opening \(displayName).")
    }

    /// Resolves a spoken app name against what is actually installed.
    ///
    /// Matching real applications is what makes the strict-verb rule safe: if
    /// the noun is not an installed app, this returns nil and the request falls
    /// through to the model, so "open the pod bay doors" is answered rather
    /// than acted on.
    private static func applicationURL(matching spokenName: String) -> URL? {
        let candidates = [spokenName, spokenName.replacingOccurrences(of: " ", with: "")]

        for candidate in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                return url
            }
        }

        // CoreServices holds Finder and friends, which people ask for by name
        // as readily as anything in /Applications.
        let searchDirectories = ["/Applications", "/System/Applications",
                                 "/System/Applications/Utilities", "/Applications/Utilities",
                                 "/System/Library/CoreServices"]

        var wordMatch: URL?
        for directory in searchDirectories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let bareName = String(entry.dropLast(4)).lowercased()
                let url = URL(fileURLWithPath: directory).appendingPathComponent(entry)

                if bareName == spokenName || bareName.replacingOccurrences(of: " ", with: "") == spokenName {
                    return url
                }

                // People say "chrome", not "google chrome". Matching a whole
                // word inside the real name covers that without the looseness
                // of a substring match, which would let "mail" select
                // "Mailbox". Exact matches above always win.
                if wordMatch == nil, bareName.split(separator: " ").contains(where: { $0 == spokenName }) {
                    wordMatch = url
                }
            }
        }
        return wordMatch
    }

    // MARK: - AppleScript

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            print("⚠️ Fast command AppleScript failed: \(error)")
            return nil
        }
        return result?.stringValue
    }
}
