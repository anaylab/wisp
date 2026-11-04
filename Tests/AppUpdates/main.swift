import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

let realKey = Data(repeating: 7, count: 32).base64EncodedString()
let feed = "https://github.com/anaylab/wisp/releases/latest/download/appcast.xml"
let installed = "/Applications/Wisp.app"

func availability(
    key: String? = realKey,
    feedURL: String? = feed,
    demo: Bool = false,
    path: String = installed
) -> WispUpdateAvailability {
    WispUpdatePolicy.availability(publicEDKey: key, feedURLString: feedURL, isDemoMode: demo, bundlePath: path)
}

// A release build, installed, may update.
check(availability() == .available, "release build in /Applications should update")
check(availability(path: "/Users/someone/Applications/Wisp.app") == .available, "~/Applications is fine")

// A copy built in Xcode has no key, or an unexpanded one: it must never update, or it would replace
// itself with a differently signed release and lose its permissions.
check(availability(key: nil) == .unavailable(.builtFromSource), "no key")
check(availability(key: "") == .unavailable(.builtFromSource), "empty key: what Xcode's plist expansion leaves")
check(availability(key: "$(WISP_SPARKLE_PUBLIC_ED_KEY)") == .unavailable(.builtFromSource), "unexpanded key")
check(availability(key: "abc") == .unavailable(.builtFromSource), "not base64 of 32 bytes")
check(availability(key: Data(repeating: 7, count: 16).base64EncodedString()) == .unavailable(.builtFromSource), "wrong length")

// The feed must be https.
check(availability(feedURL: nil) == .unavailable(.builtFromSource), "no feed")
check(availability(feedURL: "http://example.com/appcast.xml") == .unavailable(.builtFromSource), "http feed refused")

// Demo mode and unmoved copies.
check(availability(demo: true) == .unavailable(.demoMode), "demo mode")
check(availability(key: nil, demo: true) == .unavailable(.builtFromSource), "a dev copy reads as a dev copy, demo or not")
check(availability(path: "/Volumes/Wisp/Wisp.app") == .unavailable(.notInstalled), "run from the disk image")
check(
    availability(path: "/private/var/folders/ab/T/AppTranslocation/1234/d/Wisp.app") == .unavailable(.notInstalled),
    "translocated copy from Downloads"
)

// Version wording: everything before 1.0 is the public beta.
check(
    WispUpdatePolicy.versionDescription(shortVersion: "0.3", buildNumber: "12") == "Wisp 0.3 beta (build 12)",
    "beta version"
)
check(
    WispUpdatePolicy.versionDescription(shortVersion: "1.0", buildNumber: "20") == "Wisp 1.0 (build 20)",
    "stable version"
)
check(
    WispUpdatePolicy.versionDescription(shortVersion: "10.2", buildNumber: nil) == "Wisp 10.2",
    "10.x isn't a beta, and no build number"
)
check(WispUpdatePolicy.versionDescription(shortVersion: nil, buildNumber: "3") == "Wisp", "no version")

// One notification per version, none during a call, and a call doesn't use up the one.
check(
    WispUpdatePolicy.shouldNotifyAboutPendingUpdate(pendingVersion: "0.2", lastNotifiedVersion: nil, isQuietModeActive: false),
    "first time"
)
check(
    !WispUpdatePolicy.shouldNotifyAboutPendingUpdate(pendingVersion: "0.2", lastNotifiedVersion: "0.2", isQuietModeActive: false),
    "same version again"
)
check(
    WispUpdatePolicy.shouldNotifyAboutPendingUpdate(pendingVersion: "0.3", lastNotifiedVersion: "0.2", isQuietModeActive: false),
    "newer version"
)
check(
    !WispUpdatePolicy.shouldNotifyAboutPendingUpdate(pendingVersion: "0.2", lastNotifiedVersion: nil, isQuietModeActive: true),
    "on a call"
)

if failures == 0 {
    print("AppUpdates: all checks passed")
} else {
    print("AppUpdates: \(failures) failed")
    exit(1)
}
