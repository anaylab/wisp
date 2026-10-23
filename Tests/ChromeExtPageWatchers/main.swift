//
//  Chrome page watchers suite (phase 08): the tab-or-screen decision, the
//  reload interval and number phrasing, the wire condition, reconciliation
//  with the extension's list, wording, site matching and time on a site.
//

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

// MARK: - Tab or screen

func route(_ transcript: String, inChrome: Bool = true, canRead: Bool = true) -> ChromePageWatchRoute? {
    guard let request = ScreenWatchRequestParser.request(from: transcript) else { return nil }
    return ChromePageWatchRouter.route(
        for: request,
        transcript: transcript,
        isChromeInFrontWithExtension: inChrome,
        canReadPagesInChrome: canRead
    )
}

check(route("tell me when this tab says Deployed") == .watchChromeTab(.textAppears("Deployed"), reloadEveryMinutes: nil), "in Chrome: the tab")
check(route("tell me when this tab says Deployed", inChrome: false) == .watchScreen(.textAppears("Deployed")), "another app in front: the screen")
check(route("tell me when this tab says Deployed", canRead: false) == .watchScreen(.textAppears("Deployed")), "no pages.read: the screen")
check(route("tell me when the screen stops changing") == nil || route("tell me when the screen stops changing") == .watchScreen(.screenTextSettles), "naming the screen keeps a screen watch")
check(route("tell me when the terminal shows build complete") == .watchScreen(.textAppears("build complete")), "the terminal is not a tab")
check(route("tell me when it's done") == .watchChromeTab(.screenTextSettles, reloadEveryMinutes: nil), "settling becomes the page settling")
check(route("stop watching") == .stopAllWatching, "stop is stop, wherever")
check(route("stop watching", inChrome: false) == .stopAllWatching, "stop outside Chrome")
check(route("what's on this tab") == nil, "not a watch at all")

let priceThreshold = ScreenWatchNumberThreshold(subjectText: "the price", nearText: "price", direction: .below, threshold: 80, thresholdText: "$80")
check(route("tell me when the price drops below $80") == .watchChromeTab(.numberCrosses(priceThreshold), reloadEveryMinutes: nil), "a price watch in Chrome")
check(
    route("check this page every 10 minutes and tell me when it says in stock") == .watchChromeTab(.textAppears("in stock"), reloadEveryMinutes: 10),
    "a reloading watch"
)

// MARK: - Reload intervals

check(ChromePageWatchRouter.reloadEveryMinutes(in: "check this page every 10 minutes") == 10, "every 10 minutes")
check(ChromePageWatchRouter.reloadEveryMinutes(in: "refresh it every hour and tell me") == 60, "every hour")
check(ChromePageWatchRouter.reloadEveryMinutes(in: "reload every half hour") == 30, "every half hour")
check(ChromePageWatchRouter.reloadEveryMinutes(in: "check every two hours") == 120, "every two hours")
check(ChromePageWatchRouter.reloadEveryMinutes(in: "check this page every minute") == 5, "at least 5 minutes")
check(ChromePageWatchRouter.reloadEveryMinutes(in: "keep refreshing this page and tell me when it says open") == 15, "a reload verb on the page, no interval: 15")
check(ChromePageWatchRouter.reloadEveryMinutes(in: "tell me when it says done every time") == nil, "no reload verb, no reload")
check(ChromePageWatchRouter.reloadEveryMinutes(in: "tell me when the build finishes") == nil, "nothing about reloading")

// MARK: - The wire condition

check(ChromePageWatchWireCondition(.textAppears("Deployed")) == ChromePageWatchWireCondition(kind: "textAppears", text: "Deployed"), "text appears on the wire")
check(ChromePageWatchWireCondition(.screenTextSettles).kind == "pageSettlesAfterChange", "settles on the wire")
let priceWire = ChromePageWatchWireCondition(.numberCrosses(priceThreshold))
check(priceWire == ChromePageWatchWireCondition(kind: "numberCrosses", nearText: "price", direction: "below", threshold: 80), "number on the wire")
do {
    let encodedPriceWire = String(data: try JSONEncoder().encode(priceWire), encoding: .utf8) ?? ""
    check(!encodedPriceWire.contains("selector") && !encodedPriceWire.contains("\"text\""), "absent fields aren't sent: \(encodedPriceWire)")
} catch {
    check(false, "the wire condition encodes")
}
check(ChromePageWatchWireCondition(kind: "textDisappears", text: "Uploading").screenWatchCondition == .textDisappears("Uploading"), "back from the wire")
if case .numberCrosses(let adoptedThreshold)? = priceWire.screenWatchCondition {
    check(adoptedThreshold.thresholdText == "80" && adoptedThreshold.direction == .below, "an adopted number watch reads plainly")
} else {
    check(false, "a number condition comes back from the wire")
}
check(ChromePageWatchWireCondition(kind: "eval").screenWatchCondition == nil, "unknown kinds are dropped")
check(ChromePageWatchWireCondition.displayText(forThreshold: 79.99) == "79.99", "decimal threshold text")

// MARK: - Decoding the extension's list

let listJSON = """
{"watches":[{"watchId":"w2","tabId":8,"windowId":1,"url":"https://shop.example.com/p","title":"Headphones","label":"","condition":{"kind":"numberCrosses","nearText":"price","direction":"below","threshold":80},"reloadEveryMinutes":10,"ownsTab":true,"startedAt":1760000000000,"expiresAt":1760086400000}],
 "recentlyEnded":[{"watchId":"w1","reason":"matched","matchedText":"Deployed v2","endedAt":1760000500000,"label":""}]}
"""
do {
    let decodedList = try JSONDecoder().decode(ChromePageWatchList.self, from: Data(listJSON.utf8))
    check(decodedList.watches.first?.ownsTab == true && decodedList.watches.first?.reloadEveryMinutes == 10, "the list decodes")

    let knownDeployWatch = ActiveChromePageWatch(
        id: "w1", condition: .textAppears("Deployed"), tabID: 7, tabTitle: "Run #42", pageURL: "https://github.com/acme/app/actions/runs/42",
        reloadEveryMinutes: nil, startDate: Date(timeIntervalSince1970: 1_759_999_000)
    )
    let knownGoneWatch = ActiveChromePageWatch(
        id: "w9", condition: .screenTextSettles, tabID: 3, tabTitle: "", pageURL: "https://example.com/export",
        reloadEveryMinutes: nil, startDate: Date(timeIntervalSince1970: 1_759_999_100)
    )
    let knownPriceWatch = ActiveChromePageWatch(
        id: "w2", condition: .numberCrosses(priceThreshold), tabID: 8, tabTitle: "Headphones", pageURL: "https://shop.example.com/p",
        reloadEveryMinutes: 10, startDate: Date(timeIntervalSince1970: 1_760_000_000)
    )
    let outcome = ChromePageWatchReconciliation.reconcile(
        knownWatches: [knownDeployWatch, knownGoneWatch, knownPriceWatch],
        extensionList: decodedList
    )
    check(outcome.activeWatches.map(\.id) == ["w2"], "only the extension's watches stay")
    check(outcome.activeWatches.first?.condition == .numberCrosses(priceThreshold), "Wisp's own wording is kept (\"$80\")")
    check(outcome.endedWatches.map(\.watch.id) == ["w1", "w9"], "the rest ended")
    check(outcome.endedWatches.first?.ending == .conditionMet(matchedText: "Deployed v2"), "an ending Wisp missed is read back")
    check(outcome.endedWatches.last?.ending == .lost, "a watch the extension forgot is lost")

    let adoptedOutcome = ChromePageWatchReconciliation.reconcile(knownWatches: [], extensionList: decodedList)
    check(adoptedOutcome.activeWatches.first?.tabDisplayName == "Headphones", "a watch from before Wisp restarted is adopted")
} catch {
    check(false, "the list decodes: \(error)")
}

// MARK: - Wording

let deployWatch = ActiveChromePageWatch(
    id: "w1", condition: .textAppears("completed"), tabID: 7, tabTitle: "Run #42 · GitHub Actions", pageURL: "https://www.github.com/acme",
    reloadEveryMinutes: nil, startDate: Date()
)
check(
    ChromePageWatchWording.endingMessage(for: deployWatch, ending: .conditionMet(matchedText: "Run completed in 3m")) == "“completed” is on Run #42 · GitHub Actions now: Run completed in 3m",
    "a match names the tab and the line"
)
check(ChromePageWatchWording.endingMessage(for: deployWatch, ending: .tabClosed).contains("the tab was closed"), "tab closed wording")
check(deployWatch.pageHost == "github.com", "host without www")
let untitledWatch = ActiveChromePageWatch(id: "w3", condition: .screenTextSettles, tabID: 2, tabTitle: " ", pageURL: "https://example.com/x", reloadEveryMinutes: nil, startDate: Date())
check(untitledWatch.tabDisplayName == "example.com", "an untitled tab is named by its host")
let reloadingWatch = ActiveChromePageWatch(id: "w4", condition: .textAppears("in stock"), tabID: 9, tabTitle: "Tickets", pageURL: "https://t.example", reloadEveryMinutes: 60, startDate: Date())
check(ChromePageWatchWording.startedReply(for: reloadingWatch).contains("every hour"), "reload reply says the interval")
check(ChromePageWatchWording.startedReply(for: deployWatch).contains("watching this tab"), "a tab watch says so")
let priceWatch = ActiveChromePageWatch(id: "w5", condition: .numberCrosses(priceThreshold), tabID: 9, tabTitle: "Headphones", pageURL: "https://s.example", reloadEveryMinutes: nil, startDate: Date())
check(
    ChromePageWatchWording.endingMessage(for: priceWatch, ending: .conditionMet(matchedText: "Price $79.99")) == "the price is below $80 on Headphones now: Price $79.99",
    "a price match"
)
check(ChromePageWatchEnding(extensionReason: "navigatedAway", matchedText: nil) == .navigatedAway, "reasons map")
check(ChromePageWatchEnding(extensionReason: "something new", matchedText: nil) == .lost, "unknown reasons are lost")

// MARK: - Sites

check(ChromeSiteMatching.siteHost(fromSpokenName: "YouTube") == "youtube.com", "a known site name")
check(ChromeSiteMatching.siteHost(fromSpokenName: "twitter") == "x.com", "twitter is x")
check(ChromeSiteMatching.siteHost(fromSpokenName: "www.bbc.co.uk") == "bbc.co.uk", "an address as said")
check(ChromeSiteMatching.siteHost(fromSpokenName: "my notes") == nil, "not a site")
check(ChromeSiteMatching.siteHost(fromSpokenName: "notion") == nil, "an unknown bare word isn't guessed")
check(ChromeSiteMatching.host(ofURL: "https://www.youtube.com/watch?v=1") == "youtube.com", "host of a URL")
check(ChromeSiteMatching.host(ofURL: "chrome://settings") == nil, "chrome pages have no site")
check(ChromeSiteMatching.host("m.youtube.com", isOnSite: "youtube.com"), "a subdomain is on the site")
check(ChromeSiteMatching.host("twitter.com", isOnSite: "x.com"), "an equivalent host")
check(!ChromeSiteMatching.host("notyoutube.com", isOnSite: "youtube.com"), "a lookalike isn't")
check(ChromeSiteMatching.displayName(forSiteHost: "reddit.com") == "Reddit", "display name")

// MARK: - Time on a site

let startDate = Date(timeIntervalSince1970: 1_760_000_000)
func at(_ seconds: TimeInterval) -> Date { startDate.addingTimeInterval(seconds) }
let onReddit = ChromeBrowsingSample(activeHost: "www.reddit.com", isChromeFrontmost: true, isUserIdle: false)
let onYouTube = ChromeBrowsingSample(activeHost: "youtube.com", isChromeFrontmost: true, isUserIdle: false)
let inSlack = ChromeBrowsingSample(activeHost: "www.reddit.com", isChromeFrontmost: false, isUserIdle: false)
let idleOnReddit = ChromeBrowsingSample(activeHost: "reddit.com", isChromeFrontmost: true, isUserIdle: true)

do {
    var accumulator = ChromeTimeOnSiteAccumulator()
    for secondsIn in stride(from: 0.0, through: 600, by: 15) {
        accumulator.record(onReddit, at: at(secondsIn))
    }
    check(abs((accumulator.currentVisit(toSite: "reddit.com", now: at(600))?.secondsOnSite ?? 0) - 600) < 0.5, "ten minutes on reddit")

    // Slack in front for 5 minutes: paused, not reset.
    accumulator.record(inSlack, at: at(600))
    accumulator.record(onReddit, at: at(900))
    check(abs((accumulator.currentVisit(toSite: "reddit.com", now: at(900))?.secondsOnSite ?? 0) - 600) < 0.5, "time in another app doesn't count")
    // The time since the last sample counts when asked.
    check(abs((accumulator.currentVisit(toSite: "reddit.com", now: at(930))?.secondsOnSite ?? 0) - 630) < 0.5, "in-progress time counts")

    // Idle for 10 minutes: paused.
    accumulator.record(idleOnReddit, at: at(960))
    accumulator.record(onReddit, at: at(1560))
    check(abs((accumulator.currentVisit(toSite: "reddit.com", now: at(1560))?.secondsOnSite ?? 0) - 660) < 0.5, "idle time doesn't count")

    // Over to YouTube; reddit's visit is kept until the reset gap.
    accumulator.record(onYouTube, at: at(1560))
    accumulator.record(onYouTube, at: at(1620))
    check(abs((accumulator.currentVisit(toSite: "youtube.com", now: at(1620))?.secondsOnSite ?? 0) - 60) < 0.5, "youtube counts on its own")
    check(accumulator.currentVisit(toSite: "reddit.com", now: at(1620)) != nil, "reddit's visit is still open")
    check(accumulator.currentVisit(toSite: "reddit.com", now: at(1560 + ChromeTimeOnSiteAccumulator.visitResetGapSeconds + 1)) == nil, "a long break ends the visit")

    // A gap between samples (the Mac slept) credits at most 90 seconds…
    var sleepyAccumulator = ChromeTimeOnSiteAccumulator()
    sleepyAccumulator.record(onReddit, at: at(0))
    sleepyAccumulator.record(onReddit, at: at(300))
    check(abs((sleepyAccumulator.currentVisit(toSite: "reddit.com", now: at(300))?.secondsOnSite ?? 0) - ChromeTimeOnSiteAccumulator.maximumCreditedGapSeconds) < 0.5, "a short sleep isn't time on a site")
    // …and an hour asleep ends the visit.
    sleepyAccumulator.record(onReddit, at: at(3900))
    check((sleepyAccumulator.currentVisit(toSite: "reddit.com", now: at(3900))?.secondsOnSite ?? 0) < 0.5, "an hour asleep starts over")

    // Coming back after the reset gap starts a new visit.
    var returningAccumulator = ChromeTimeOnSiteAccumulator()
    returningAccumulator.record(onReddit, at: at(0))
    returningAccumulator.record(inSlack, at: at(60))
    returningAccumulator.record(onReddit, at: at(60 + 20 * 60))
    returningAccumulator.record(onReddit, at: at(60 + 20 * 60 + 30))
    let returningVisit = returningAccumulator.currentVisit(toSite: "reddit.com", now: at(60 + 20 * 60 + 30))
    check(abs((returningVisit?.secondsOnSite ?? 0) - 30) < 0.5 && returningVisit?.startedAt == at(60 + 20 * 60), "a new visit after a long break")
}

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
