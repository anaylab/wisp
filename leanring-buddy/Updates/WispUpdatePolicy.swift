//
//  WispUpdatePolicy.swift
//  leanring-buddy
//
//  The rules behind automatic updates, kept apart from Sparkle so they can be tested without it:
//  whether this copy of Wisp may update itself at all, and how its version reads in Settings.
//
//  The important rule is the first one. Only `scripts/release.sh` puts the public signing key into
//  the app (`WISP_SPARKLE_PUBLIC_ED_KEY`), so a copy built in Xcode has none and never updates. If it
//  did, a developer's copy, signed "Apple Development", would replace itself with a release signed
//  "Developer ID" and lose its Accessibility, Screen Recording and Microphone grants, because macOS
//  ties those to the signature.
//

import Foundation

/// Why this copy of Wisp doesn't update itself.
nonisolated enum WispUpdateUnavailableReason: Equatable {
    /// Built from source: no public key, so no update could be verified.
    case builtFromSource
    /// A demo session changes nothing on its own, and that includes replacing the app.
    case demoMode
    /// Run straight from the disk image, or from the read-only copy macOS makes of an app that was
    /// never moved out of Downloads. Sparkle can't replace it there.
    case notInstalled

    var explanation: String {
        switch self {
        case .builtFromSource:
            return "This copy was built from source, so it doesn't update itself."
        case .demoMode:
            return "Updates are off in demo mode."
        case .notInstalled:
            return "Move Wisp to your Applications folder and open it from there to get updates."
        }
    }
}

nonisolated enum WispUpdateAvailability: Equatable {
    case available
    case unavailable(WispUpdateUnavailableReason)
}

nonisolated enum WispUpdatePolicy {
    /// An EdDSA (ed25519) public key is 32 bytes.
    private static let publicEDKeyByteCount = 32

    static func availability(
        publicEDKey: String?,
        feedURLString: String?,
        isDemoMode: Bool,
        bundlePath: String
    ) -> WispUpdateAvailability {
        guard isUsablePublicEDKey(publicEDKey), isUsableFeedURL(feedURLString) else {
            return .unavailable(.builtFromSource)
        }
        if isDemoMode {
            return .unavailable(.demoMode)
        }
        if isRunningFromNonInstalledLocation(bundlePath: bundlePath) {
            return .unavailable(.notInstalled)
        }
        return .available
    }

    /// False for a missing key, and for an unexpanded `$(...)`, which is what a plist keeps when a
    /// build setting was never substituted. Sparkle shows an alert and refuses to start on a key it
    /// can't read, so it mustn't be started with one.
    static func isUsablePublicEDKey(_ publicEDKey: String?) -> Bool {
        guard let publicEDKey,
              let keyBytes = Data(base64Encoded: publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return keyBytes.count == publicEDKeyByteCount
    }

    /// Updates are only ever fetched over https.
    static func isUsableFeedURL(_ feedURLString: String?) -> Bool {
        guard let feedURLString, let feedURL = URL(string: feedURLString) else { return false }
        return feedURL.scheme == "https" && feedURL.host != nil
    }

    static func isRunningFromNonInstalledLocation(bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }

    /// "Wisp 0.3 beta (build 12)". Everything before 1.0 is the public beta.
    static func versionDescription(shortVersion: String?, buildNumber: String?) -> String {
        guard let shortVersion, !shortVersion.isEmpty else { return "Wisp" }
        let isBeta = shortVersion.split(separator: ".").first == "0"
        let versionText = isBeta ? "\(shortVersion) beta" : shortVersion
        guard let buildNumber, !buildNumber.isEmpty else { return "Wisp \(versionText)" }
        return "Wisp \(versionText) (build \(buildNumber))"
    }

    /// The menu bar item that opens an update Wisp has found or already downloaded.
    static func installMenuTitle(pendingVersion: String) -> String {
        "Update to Wisp \(pendingVersion)…"
    }

    /// One notification per version, however many days the update waits, and none during a call.
    static func shouldNotifyAboutPendingUpdate(
        pendingVersion: String,
        lastNotifiedVersion: String?,
        isQuietModeActive: Bool
    ) -> Bool {
        !isQuietModeActive && pendingVersion != lastNotifiedVersion
    }
}
