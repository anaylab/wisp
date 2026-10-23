//
//  Other Chromium browsers suite (phase 13): naming a connected browser, the
//  key one connection per browser profile is kept under, which connected
//  browser Wisp talks to, how the controller and in-page pointing choices
//  treat a browser in front that isn't that one, `hello.instanceId`, and a
//  live check that the owner of a loopback socket is found.
//

import Darwin
import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

// MARK: - Catalog

check(ChromiumBrowserCatalog.displayName(bundleIdentifier: "com.google.Chrome.canary", applicationName: "Google Chrome Canary", helloBrowserName: "Google Chrome") == "Chrome Canary",
      "Canary is named Canary although it says Google Chrome")
check(ChromiumBrowserCatalog.displayName(bundleIdentifier: "company.thebrowser.Browser", applicationName: "Arc", helloBrowserName: "Chromium") == "Arc",
      "Arc is named from its bundle, not its Chromium brand")
check(ChromiumBrowserCatalog.displayName(bundleIdentifier: "com.example.NewBrowser", applicationName: "New Browser", helloBrowserName: "Chromium") == "New Browser",
      "an unknown browser keeps its own app name")
check(ChromiumBrowserCatalog.displayName(bundleIdentifier: nil, applicationName: nil, helloBrowserName: "Microsoft Edge") == "Microsoft Edge",
      "no owner found: the extension's brand stands in")
check(ChromiumBrowserCatalog.displayName(bundleIdentifier: nil, applicationName: nil, helloBrowserName: "  ") == "Chrome",
      "nothing at all: Chrome")

check(ChromiumBrowserCatalog.isChromiumBrowser(bundleIdentifier: "com.brave.Browser"), "Brave is Chromium")
check(ChromiumBrowserCatalog.isChromiumBrowser(bundleIdentifier: "com.microsoft.edgemac.Canary"), "an Edge channel is Chromium")
check(ChromiumBrowserCatalog.isChromiumBrowser(bundleIdentifier: "com.vivaldi.Vivaldi"), "Vivaldi is Chromium")
check(!ChromiumBrowserCatalog.isChromiumBrowser(bundleIdentifier: "com.apple.Safari"), "Safari isn't")
check(!ChromiumBrowserCatalog.isChromiumBrowser(bundleIdentifier: "org.mozilla.firefox"), "Firefox isn't")

check(ChromiumBrowserCatalog.browserID(bundleIdentifier: "com.google.Chrome", helloBrowserName: "Google Chrome", instanceID: nil) == "com.google.Chrome",
      "key is the bundle identifier")
check(ChromiumBrowserCatalog.browserID(bundleIdentifier: "com.google.Chrome", helloBrowserName: "Google Chrome", instanceID: "a1")
      != ChromiumBrowserCatalog.browserID(bundleIdentifier: "com.google.Chrome", helloBrowserName: "Google Chrome", instanceID: "b2"),
      "two profiles of one browser get two keys, so they don't replace each other")
check(ChromiumBrowserCatalog.browserID(bundleIdentifier: nil, helloBrowserName: " Microsoft Edge ", instanceID: nil) == "name:microsoft edge",
      "no owner: the brand name is the key")

check(ChromiumBrowserCatalog.helloBrowserName("Google Chrome", plausiblyBelongsTo: "com.google.Chrome"), "the Chrome brand vouches for Chrome")
check(!ChromiumBrowserCatalog.helloBrowserName("Google Chrome", plausiblyBelongsTo: "com.google.Chrome.canary"), "…but not for Canary, which says the same")
check(ChromiumBrowserCatalog.helloBrowserName("Microsoft Edge", plausiblyBelongsTo: "com.microsoft.edgemac"), "Edge's brand vouches for Edge")
check(!ChromiumBrowserCatalog.helloBrowserName("Chromium", plausiblyBelongsTo: "company.thebrowser.Browser"), "Arc can't be recognised by name")
check(!ChromiumBrowserCatalog.helloBrowserName("Google Chrome", plausiblyBelongsTo: "com.microsoft.edgemac"), "Chrome's brand isn't Edge")

// MARK: - Routing

func summary(_ browserID: String, bundle: String?, hello: String = "Google Chrome", order: Int) -> ChromiumBrowserConnectionSummary {
    ChromiumBrowserConnectionSummary(browserID: browserID, bundleIdentifier: bundle, helloBrowserName: hello, connectionOrder: order)
}

let chrome = summary("com.google.Chrome", bundle: "com.google.Chrome", order: 1)
let edge = summary("com.microsoft.edgemac", bundle: "com.microsoft.edgemac", hello: "Microsoft Edge", order: 2)
let arc = summary("company.thebrowser.Browser", bundle: "company.thebrowser.Browser", hello: "Chromium", order: 3)

func route(_ browsers: [ChromiumBrowserConnectionSummary], front: String?, current: String? = nil, held: Bool = false) -> String? {
    ChromiumBrowserRouting.activeBrowserID(ChromiumBrowserRoutingInputs(
        connectedBrowsers: browsers, frontmostBundleIdentifier: front, currentActiveBrowserID: current, isActiveBrowserHeld: held
    ))
}

check(route([], front: "com.google.Chrome") == nil, "nothing connected → no active browser")
check(route([edge], front: "com.google.Chrome") == edge.browserID, "one browser → that one, whatever is in front")
check(route([chrome, edge], front: "com.microsoft.edgemac") == edge.browserID, "Edge in front → Edge")
check(route([chrome, edge, arc], front: "company.thebrowser.Browser", current: chrome.browserID) == arc.browserID, "Arc in front → Arc")
check(route([chrome, edge], front: "com.apple.dt.Xcode", current: edge.browserID) == edge.browserID,
      "Xcode in front → the browser the user was last in stays")
check(route([edge, chrome], front: "com.apple.dt.Xcode") == chrome.browserID, "ambiguous, nothing chosen yet → Chrome")
check(route([edge, arc], front: nil) == edge.browserID, "ambiguous, no Chrome → the one that connected first")
check(route([chrome, edge], front: "com.microsoft.edgemac", current: chrome.browserID, held: true) == chrome.browserID,
      "Chrome held by work in flight → stays Chrome even with Edge in front")
check(route([edge], front: "com.microsoft.edgemac", current: chrome.browserID, held: true) == edge.browserID,
      "a held browser that disconnected doesn't stay active")
check(route([chrome, edge], front: "com.google.Chrome.canary", current: edge.browserID) == edge.browserID,
      "Canary in front without the extension → the current browser stays")

let chromeByName = summary("name:google chrome", bundle: nil, order: 1)
check(route([chromeByName, edge], front: "com.google.Chrome", current: edge.browserID) == chromeByName.browserID,
      "an unidentified Chrome connection still matches Chrome in front by its brand")

let chromeProfileOne = summary("com.google.Chrome#one", bundle: "com.google.Chrome", order: 4)
let chromeProfileTwo = summary("com.google.Chrome#two", bundle: "com.google.Chrome", order: 5)
check(route([chromeProfileOne, chromeProfileTwo, edge], front: "com.google.Chrome", current: chromeProfileTwo.browserID) == chromeProfileTwo.browserID,
      "two Chrome profiles: the active one stays while Chrome is in front")
check(route([chromeProfileTwo, chromeProfileOne, edge], front: "com.google.Chrome", current: edge.browserID) == chromeProfileOne.browserID,
      "two Chrome profiles, coming from Edge: the one that connected first")

// MARK: - Controller choice with two browsers

func choose(front: BrowserControllerSelectionInputs.FrontmostApplication, activeIsFront: Bool, appleScriptCanDrive: Bool) -> BrowserControllerKind {
    BrowserControllerSelector.choose(BrowserControllerSelectionInputs(
        isExtensionConnected: true, extensionCanReadPages: true, frontmostApplication: front,
        activeExtensionBrowserIsFrontmost: activeIsFront, appleScriptCanDriveFrontmostBrowser: appleScriptCanDrive
    )).kind
}

check(choose(front: .chromiumBrowser, activeIsFront: true, appleScriptCanDrive: false) == .chromeExtension, "Edge in front with the extension → extension")
check(choose(front: .chromiumBrowser, activeIsFront: false, appleScriptCanDrive: true) == .appleScript,
      "Chrome in front, extension only in Edge → AppleScript drives Chrome where the user is")
check(choose(front: .chromiumBrowser, activeIsFront: false, appleScriptCanDrive: false) == .chromeExtension,
      "Vivaldi in front without the extension → the connected browser's extension does it")
check(choose(front: .other, activeIsFront: false, appleScriptCanDrive: false) == .chromeExtension,
      "no browser in front → the active browser's extension")
check(choose(front: .safari, activeIsFront: false, appleScriptCanDrive: true) == .appleScript, "Safari in front → AppleScript, as before")

check(BrowserControllerSelectionInputs.FrontmostApplication(bundleIdentifier: "com.vivaldi.Vivaldi") == .chromiumBrowser, "Vivaldi is a Chromium browser in front")
check(BrowserControllerSelectionInputs.FrontmostApplication(bundleIdentifier: "com.operasoftware.Opera") == .chromiumBrowser, "Opera is a Chromium browser in front")

// MARK: - In-page pointing with two browsers

let pointingInOtherBrowser = ChromeInPagePointingPolicy.decision(for: ChromeInPagePointingInputs(
    frontmostApplication: .chromiumBrowser, isExtensionConnected: true, extensionCanReadPages: true,
    activeExtensionBrowserIsFrontmost: false
))
if case .useOverlay = pointingInOtherBrowser {
    check(true, "")
} else {
    check(false, "the extension is in another browser → the overlay, never another browser's page")
}
check(ChromeInPagePointingPolicy.decision(for: ChromeInPagePointingInputs(
    frontmostApplication: .chromiumBrowser, isExtensionConnected: true, extensionCanReadPages: true
)) == .tryInPage, "one browser, in front → in the page, as before")

// MARK: - hello.instanceId

check(ChromeExtensionIncomingMessage.parse(Data(#"{"type":"hello","extensionVersion":"2.0.0","browserName":"Brave","capabilities":["tabs"],"instanceId":"abc"}"#.utf8))
      == .hello(extensionVersion: "2.0.0", browserName: "Brave", capabilities: [.tabs], instanceID: "abc"),
      "hello carries the instance id")
check(ChromeExtensionIncomingMessage.parse(Data(#"{"type":"hello","extensionVersion":"1.1.0","browserName":"Chrome","capabilities":["tabs"]}"#.utf8))
      == .hello(extensionVersion: "1.1.0", browserName: "Chrome", capabilities: [.tabs], instanceID: nil),
      "an older hello has none")
let longInstanceID = String(repeating: "x", count: 500)
if case .hello(_, _, _, let parsedInstanceID)? = ChromeExtensionIncomingMessage.parse(Data(#"{"type":"hello","instanceId":"\#(longInstanceID)"}"#.utf8)) {
    check(parsedInstanceID?.count == ChromeExtensionIncomingMessage.maximumInstanceIDLength, "a long instance id is cut")
} else {
    check(false, "a hello with a long instance id still parses")
}

// MARK: - Live: the owner of a loopback socket

/// Listens on a free loopback port, lets `/usr/bin/nc` (a child of this test)
/// connect, and asks who owns the far end. The answer is whichever regular app
/// this test runs under (Terminal, Xcode, an agent's host app), so the check is
/// "found, and not found for a port nobody holds". Skipped when the test runs
/// under no regular app at all (an ssh session).
func liveOwnerCheck() async {
    let listeningSocket = socket(AF_INET, SOCK_STREAM, 0)
    guard listeningSocket >= 0 else { print("SKIP: live socket check (no socket)"); return }
    defer { close(listeningSocket) }
    var listeningAddress = sockaddr_in()
    listeningAddress.sin_family = sa_family_t(AF_INET)
    listeningAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
    listeningAddress.sin_port = 0
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let boundAndListening = withUnsafeMutablePointer(to: &listeningAddress) { addressPointer in
        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { genericPointer in
            bind(listeningSocket, genericPointer, addressLength) == 0
                && listen(listeningSocket, 1) == 0
                && getsockname(listeningSocket, genericPointer, &addressLength) == 0
        }
    }
    guard boundAndListening else { print("SKIP: live socket check (couldn't listen)"); return }
    let listeningPort = UInt16(bigEndian: listeningAddress.sin_port)

    let connectingProcess = Process()
    connectingProcess.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    connectingProcess.arguments = ["127.0.0.1", String(listeningPort)]
    connectingProcess.standardInput = Pipe()
    connectingProcess.standardOutput = FileHandle.nullDevice
    do { try connectingProcess.run() } catch { print("SKIP: live socket check (no nc)"); return }
    defer { connectingProcess.terminate() }

    var peerAddress = sockaddr_in()
    var peerAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let acceptedSocket = withUnsafeMutablePointer(to: &peerAddress) { addressPointer in
        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listeningSocket, $0, &peerAddressLength) }
    }
    guard acceptedSocket >= 0 else { print("SKIP: live socket check (nothing connected)"); return }
    defer { close(acceptedSocket) }
    let peerPort = UInt16(bigEndian: peerAddress.sin_port)

    let owner = await ChromeExtensionPeerProcess.owningApplication(peerPort: peerPort, listeningPort: listeningPort)
    if owner == nil {
        print("SKIP: live socket check (this test isn't running under a regular app)")
    } else {
        check(owner?.bundleIdentifier.isEmpty == false, "the owner of a live loopback socket is found")
    }
    let nobody = await ChromeExtensionPeerProcess.owningApplication(peerPort: 1, listeningPort: listeningPort)
    check(nobody == nil, "a port nobody holds has no owner")
}

await liveOwnerCheck()

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
