//
//  MediaPlayback.swift
//  leanring-buddy
//
//  Plays, pauses and skips music in Apple Music or Spotify. Before this existed
//  Wisp could only *read* what was playing (NowPlayingDataProvider), so "play
//  some music" had no tool to reach for and the model could only talk about it.
//
//  Two entry points share one executor: `FastCommandRouter` for rigid phrases
//  ("pause", "next song") that need no model, and the `control_music` agent
//  tool for everything with a parameter ("play Radiohead").
//

import AppKit
import Foundation

enum MediaPlaybackAction: String, CaseIterable {
    case play
    case pause
    case next
    case previous
}

@MainActor
enum MediaPlayback {
    private static let musicBundleIdentifier = "com.apple.Music"
    private static let spotifyBundleIdentifier = "com.spotify.client"

    private enum MediaApp {
        case music
        case spotify

        var applicationName: String {
            switch self {
            case .music: return "Music"
            case .spotify: return "Spotify"
            }
        }
    }

    /// Performs the action and returns a short sentence saying what really
    /// happened, including failures, so the caller never claims success it
    /// didn't get.
    static func perform(_ action: MediaPlaybackAction, searchQuery: String? = nil) -> String {
        let trimmedSearchQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = preferredApp()

        switch action {
        case .pause:
            return runTransportCommand("pause", on: app, successText: "paused.")
        case .next:
            return runTransportCommand("next track", on: app, successText: "skipped to the next song.")
        case .previous:
            return runTransportCommand("previous track", on: app, successText: "back to the previous song.")
        case .play:
            if trimmedSearchQuery.isEmpty {
                return runTransportCommand("play", on: app, successText: "playing.")
            }
            return play(searchQuery: trimmedSearchQuery, on: app)
        }
    }

    // MARK: - Choosing the app

    /// The app that is already playing wins, then whichever is open, then Music
    /// (always installed). Never launches Spotify unasked.
    private static func preferredApp() -> MediaApp {
        let isSpotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleIdentifier).isEmpty
        let isMusicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleIdentifier).isEmpty

        if let snapshot = NowPlayingDataProvider.snapshot(), snapshot.isPlaying {
            return snapshot.appName == "Spotify" ? .spotify : .music
        }
        if isSpotifyRunning && !isMusicRunning { return .spotify }
        return .music
    }

    // MARK: - Commands

    private static func runTransportCommand(_ command: String, on app: MediaApp, successText: String) -> String {
        let script = "tell application \"\(app.applicationName)\" to \(command)"
        switch execute(script) {
        case .success:
            return successText
        case .failure(let failure):
            return failureText(for: failure, app: app)
        }
    }

    private static func play(searchQuery: String, on app: MediaApp) -> String {
        switch app {
        case .spotify:
            // Spotify's scripting dictionary cannot search, only play a URI it
            // already has. Opening its search page is the honest ceiling.
            let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
            guard let searchURL = URL(string: "spotify:search:\(encodedQuery)") else {
                return "i couldn't build a spotify search for that."
            }
            NSWorkspace.shared.open(searchURL)
            return "i opened spotify's search for \(searchQuery) — it can't start a specific song on its own, so tap the one you want."

        case .music:
            let escapedQuery = appleScriptStringLiteralContent(searchQuery)
            let script = """
            tell application "Music"
                set matchingTracks to (every track of library playlist 1 whose name contains "\(escapedQuery)" or artist contains "\(escapedQuery)" or album contains "\(escapedQuery)")
                if (count of matchingTracks) is 0 then return "no match"
                play (item 1 of matchingTracks)
                return name of (item 1 of matchingTracks) & " — " & artist of (item 1 of matchingTracks)
            end tell
            """
            switch execute(script) {
            case .success(let output):
                if output == "no match" {
                    return "i couldn't find \(searchQuery) in your music library."
                }
                return "playing \(output)."
            case .failure(let failure):
                return failureText(for: failure, app: app)
            }
        }
    }

    // MARK: - AppleScript

    private enum ScriptFailure {
        case automationDenied
        case other(String)
    }

    private enum ScriptResult {
        case success(String)
        case failure(ScriptFailure)
    }

    private static func execute(_ source: String) -> ScriptResult {
        guard let appleScript = NSAppleScript(source: source) else {
            return .failure(.other("the script didn't compile"))
        }
        var executionError: NSDictionary?
        let output = appleScript.executeAndReturnError(&executionError)
        if let executionError {
            let errorNumber = (executionError[NSAppleScript.errorNumber] as? Int) ?? 0
            let errorMessage = (executionError[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            // -1743: Automation permission for the target app was refused.
            if errorNumber == -1743 { return .failure(.automationDenied) }
            return .failure(.other(errorMessage))
        }
        return .success(output.stringValue ?? "")
    }

    private static func failureText(for failure: ScriptFailure, app: MediaApp) -> String {
        switch failure {
        case .automationDenied:
            return "macOS blocked wisp from controlling \(app.applicationName). turn it on in system settings, privacy and security, automation."
        case .other(let message):
            return "i couldn't control \(app.applicationName): \(message)"
        }
    }

    /// Makes text safe to place between the quotes of an AppleScript string.
    private static func appleScriptStringLiteralContent(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Spoken phrases

/// Whole-utterance media phrases. Anything with a song or artist in it goes to
/// the model and the `control_music` tool instead.
enum MediaPlaybackPhraseParser {
    static func action(fromNormalizedText text: String) -> MediaPlaybackAction? {
        switch text {
        case "play", "play music", "play some music", "play something", "resume", "resume music",
             "resume playing", "unpause", "start the music", "start music", "play the music":
            return .play
        case "pause", "pause music", "pause the music", "stop the music", "stop music", "stop playing":
            return .pause
        case "next", "next song", "next track", "skip", "skip song", "skip this song", "skip track",
             "skip this track", "play the next song", "play next song":
            return .next
        case "previous", "previous song", "previous track", "last song", "go back a song",
             "play the previous song", "play previous song":
            return .previous
        default:
            return nil
        }
    }

    /// Whether a request is about playing or controlling music, so the
    /// per-turn tool router offers `control_music` even when its description
    /// shares few words with the request ("play some frank ocean").
    static func requestIsAboutMusic(_ transcript: String) -> Bool {
        let lowercasedWords = Set(
            transcript.lowercased().split { !$0.isLetter }.map(String.init)
        )
        let musicWords: Set<String> = ["music", "song", "songs", "track", "tracks", "album",
                                       "playlist", "spotify", "pause", "resume", "skip"]
        if !lowercasedWords.isDisjoint(with: musicWords) { return true }
        return transcript.lowercased().hasPrefix("play ")
    }
}

// MARK: - Agent tool

extension AgentToolRegistry {
    func registerMediaPlaybackTools() {
        let actionRawValues = MediaPlaybackAction.allCases.map(\.rawValue)
        register(
            BuddyToolDefinition(
                name: "control_music",
                description: "Play, pause or skip music in Apple Music or Spotify. Use for any request to play music or a song or artist, pause, resume, or skip to the next or previous track. To play something specific, use action play with a query (song, artist or album name); it searches the user's Apple Music library.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object([
                            "type": .string("string"),
                            "enum": .array(actionRawValues.map { .string($0) }),
                            "description": .string("What to do.")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Song, artist or album to play. Only with action play; leave out to resume.")
                        ])
                    ]),
                    "required": .array([.string("action")])
                ]),
                metadata: .trivialAndReversible
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let rawAction)? = arguments["action"],
                  let action = MediaPlaybackAction(rawValue: rawAction.lowercased()) else {
                return "i need an action, one of: \(actionRawValues.joined(separator: ", "))."
            }
            var searchQuery: String?
            if case .string(let providedQuery)? = arguments["query"] { searchQuery = providedQuery }
            return await MainActor.run { MediaPlayback.perform(action, searchQuery: searchQuery) }
        }
    }
}
