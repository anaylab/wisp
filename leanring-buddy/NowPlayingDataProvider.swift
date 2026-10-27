//
//  NowPlayingDataProvider.swift
//  leanring-buddy
//
//  Reads what is currently playing in Music or Spotify on this Mac, for the
//  now-playing glance card. This is deliberately best-effort: macOS has no
//  supported system-wide "now playing" API for third parties (the private
//  MediaRemote framework was locked down around macOS 15.4), so Wisp asks the
//  two apps it can — Apple Music and Spotify — over AppleScript, and shows
//  nothing when neither is running or playing.
//
//  Because it talks to another app, the first read triggers the macOS
//  Automation ("control Music/Spotify") permission prompt; if the user declines,
//  the card simply reports nothing playing. It reads only the track metadata —
//  never anything else about those apps. This is a local read, so it is not
//  gated by the live-card-data network setting.
//

import AppKit
import Foundation

/// A flattened snapshot of the current track, safe to hand to the renderer.
struct NowPlayingSnapshot: Equatable {
    /// "Music" or "Spotify" — which app the track is playing in.
    let appName: String
    let title: String
    let artist: String?
    let album: String?
    let isPlaying: Bool
}

@MainActor
enum NowPlayingDataProvider {
    /// Bundle identifiers of the media apps Wisp can query, in preference order.
    private static let musicBundleIdentifier = "com.apple.Music"
    private static let spotifyBundleIdentifier = "com.spotify.client"

    /// Returns the current track from whichever supported app is running and has
    /// one, or nil when nothing is playing (or access was declined). AppleScript
    /// is executed on the main actor because Apple events want a run loop; the
    /// scripts are tiny.
    static func snapshot() -> NowPlayingSnapshot? {
        // Only query apps that are actually running, so we never launch Music or
        // Spotify just to ask what's playing.
        if isRunning(bundleIdentifier: musicBundleIdentifier),
           let snapshot = musicSnapshot() {
            return snapshot
        }
        if isRunning(bundleIdentifier: spotifyBundleIdentifier),
           let snapshot = spotifySnapshot() {
            return snapshot
        }
        return nil
    }

    private static func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    // MARK: - Per-app scripts

    private static func musicSnapshot() -> NowPlayingSnapshot? {
        // Guarded by `is running` so the tell never launches Music.
        let script = """
        tell application "Music"
            if it is running and player state is not stopped then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set playing to (player state is playing)
                return trackName & "\\n" & trackArtist & "\\n" & trackAlbum & "\\n" & playing
            end if
        end tell
        return ""
        """
        return snapshot(fromScript: script, appName: "Music")
    }

    private static func spotifySnapshot() -> NowPlayingSnapshot? {
        let script = """
        tell application "Spotify"
            if it is running and player state is not stopped then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set playing to (player state is playing)
                return trackName & "\\n" & trackArtist & "\\n" & trackAlbum & "\\n" & playing
            end if
        end tell
        return ""
        """
        return snapshot(fromScript: script, appName: "Spotify")
    }

    /// Runs one of the scripts and parses its four newline-separated fields
    /// (title, artist, album, "true"/"false"). An empty result — nothing playing
    /// or access declined — maps to nil.
    private static func snapshot(fromScript source: String, appName: String) -> NowPlayingSnapshot? {
        guard let appleScript = NSAppleScript(source: source) else { return nil }

        var executionError: NSDictionary?
        let output = appleScript.executeAndReturnError(&executionError)
        if executionError != nil { return nil }

        let combined = output.stringValue ?? ""
        let fields = combined.components(separatedBy: "\n")
        guard fields.count >= 4 else { return nil }

        let title = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let artist = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaying = fields[3].trimmingCharacters(in: .whitespacesAndNewlines) == "true"

        return NowPlayingSnapshot(
            appName: appName,
            title: title,
            artist: artist.isEmpty ? nil : artist,
            album: album.isEmpty ? nil : album,
            isPlaying: isPlaying
        )
    }
}
