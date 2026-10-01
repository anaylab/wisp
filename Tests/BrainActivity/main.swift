//
//  Brain activity-feed suite: what is never recorded, how URLs are cleaned,
//  how samples become spans and day files, and how a day becomes the compact
//  summary the page writer sees.
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

func checkEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ description: String) {
    checkCount += 1
    if actual != expected {
        failureCount += 1
        print("FAIL: \(description)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

var testCalendar = Calendar(identifier: .gregorian)
testCalendar.timeZone = TimeZone(identifier: "Europe/London")!

func date(_ dayKey: String, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    let dayStart = BrainActivityDayKey.date(fromDayKey: dayKey, calendar: testCalendar)!
    return testCalendar.date(byAdding: DateComponents(hour: hour, minute: minute, second: second), to: dayStart)!
}

func sample(
    at sampleDate: Date,
    app applicationName: String = "Figma",
    bundle bundleIdentifier: String = "com.figma.Desktop",
    title windowTitle: String? = "Atlas spec",
    url: String? = nil,
    domain: String? = nil
) -> BrainActivitySample {
    BrainActivitySample(
        date: sampleDate, applicationName: applicationName, bundleIdentifier: bundleIdentifier,
        windowTitle: windowTitle, url: url, domain: domain, screenText: nil
    )
}

func span(
    _ startDate: Date, minutes: Double,
    app applicationName: String, bundle bundleIdentifier: String,
    title windowTitle: String?, domain: String? = nil
) -> BrainActivitySpan {
    BrainActivitySpan(
        startDate: startDate, endDate: startDate.addingTimeInterval(minutes * 60),
        applicationName: applicationName, bundleIdentifier: bundleIdentifier,
        windowTitle: windowTitle, domain: domain, url: nil, screenText: nil,
        sampleCount: Int(minutes)
    )
}

// MARK: - App exclusions

let ownBundleIdentifier = "com.gluepixel.wisp"
func isAppExcluded(_ bundleIdentifier: String, user: [String] = []) -> Bool {
    BrainActivityExclusionPolicy.isApplicationExcluded(
        bundleIdentifier: bundleIdentifier, ownBundleIdentifier: ownBundleIdentifier, userExcludedBundleIdentifiers: user
    )
}
check(isAppExcluded(ownBundleIdentifier), "Wisp itself is excluded")
check(isAppExcluded("com.1password.1password"), "1Password excluded")
check(isAppExcluded("com.agilebits.onepassword8-beta"), "a 1Password variant is excluded by word")
check(isAppExcluded("com.bitwarden.desktop"), "Bitwarden excluded")
check(isAppExcluded("com.apple.keychainaccess"), "Keychain Access excluded")
check(isAppExcluded("com.apple.Passwords"), "Passwords.app excluded")
check(isAppExcluded("com.lastpass.LastPass"), "LastPass excluded")
check(isAppExcluded("com.dashlane.Dashlane"), "Dashlane excluded")
check(isAppExcluded("com.apple.loginwindow"), "loginwindow excluded")
check(isAppExcluded("com.apple.ScreenSaver.Engine"), "ScreenSaverEngine excluded")
check(isAppExcluded("com.apple.systempreferences"), "System Settings excluded")
check(!isAppExcluded("com.figma.Desktop"), "Figma is recorded")
check(!isAppExcluded("com.microsoft.VSCode"), "VS Code is recorded")
check(isAppExcluded("com.tinyspeck.slackmacgap", user: [" com.tinyspeck.SlackMacGap "]), "user list, case/space-insensitive")

// MARK: - Domain exclusions

func isSiteExcluded(_ host: String, user: [String] = []) -> Bool {
    BrainActivityExclusionPolicy.isDomainExcluded(host: host, userExcludedDomains: user)
}
check(isSiteExcluded("chase.com"), "chase.com excluded")
check(isSiteExcluded("secure.chase.com"), "subdomain of an excluded domain excluded")
check(isSiteExcluded("www.paypal.com"), "www. is ignored")
check(isSiteExcluded("mychart.org"), "health portal excluded")
check(isSiteExcluded("pornhub.com"), "adult site excluded")
check(isSiteExcluded("firstlocalbank.com"), "a host label containing 'bank' excluded")
check(isSiteExcluded("accounts.google.com"), "account sign-in page excluded")
check(!isSiteExcluded("notchase.com"), "suffix match needs a dot boundary")
check(!isSiteExcluded("github.com"), "github.com recorded")
check(!isSiteExcluded("docs.google.com"), "docs.google.com recorded (only accounts.google.com is excluded)")
check(isSiteExcluded("app.acme-hr.com", user: ["https://www.Acme-HR.com/login"]), "user domain normalised from a pasted URL")
check(isSiteExcluded("intranet.example.org", user: ["*.example.org"]), "wildcard user domain")
checkEqual(BrainActivityExclusionPolicy.normalizedDomain("HTTP://WWW.Example.COM:8080/path?q=1"), "example.com", "domain normalisation")

// MARK: - URL cleaning

let cleaned = BrainActivityExclusionPolicy.sanitizedURL("https://user:secret@Docs.Google.com/document/d/abc/edit?usp=sharing&token=XYZ#heading=h.1")
checkEqual(cleaned?.url, "https://docs.google.com/document/d/abc/edit", "query, fragment and credentials stripped")
checkEqual(cleaned?.domain, "docs.google.com", "domain of cleaned URL")
checkEqual(BrainActivityExclusionPolicy.sanitizedURL("https://www.github.com/anaylab/clicky")?.domain, "github.com", "www stripped from domain")
check(BrainActivityExclusionPolicy.sanitizedURL("chrome://settings") == nil, "chrome:// not recorded")
check(BrainActivityExclusionPolicy.sanitizedURL("file:///Users/me/secret.pdf") == nil, "file: not recorded")
check(BrainActivityExclusionPolicy.sanitizedURL("about:blank") == nil, "about:blank not recorded")

// MARK: - Screen text cap

let longText = String(repeating: "word ", count: 200)
let cappedText = BrainActivityExclusionPolicy.cappedScreenText(longText)
check((cappedText?.count ?? 0) <= BrainActivityExclusionPolicy.maximumScreenTextCharacters, "screen text capped at 300 chars")
checkEqual(BrainActivityExclusionPolicy.cappedScreenText("  a\n\n b  "), "a b", "screen text whitespace collapsed")
check(BrainActivityExclusionPolicy.cappedScreenText(" \n ") == nil, "empty screen text is nil")

// MARK: - Browser reply parsing

checkEqual(BrainActivitySampler.parseBrowserFrontTabReply("WISP-INCOGNITO"), .privateWindow, "incognito marker")
checkEqual(BrainActivitySampler.parseBrowserFrontTabReply("https://github.com/x\nx: repo"), .page(url: "https://github.com/x", title: "x: repo"), "URL + title")
checkEqual(BrainActivitySampler.parseBrowserFrontTabReply("chrome://newtab/\nNew Tab"), .unavailable, "non-http page unavailable")

// MARK: - Span merging

let dayKey = "2026-09-29"
var spans: [BrainActivitySpan] = []
spans = BrainActivitySpanMerger.appending(sample(at: date(dayKey, 9, 0)), to: spans, sampleIntervalSeconds: 60)
spans = BrainActivitySpanMerger.appending(sample(at: date(dayKey, 9, 1, 3)), to: spans, sampleIntervalSeconds: 60)
spans = BrainActivitySpanMerger.appending(sample(at: date(dayKey, 9, 2, 1)), to: spans, sampleIntervalSeconds: 60)
checkEqual(spans.count, 1, "identical consecutive samples merge into one span")
checkEqual(spans.first?.sampleCount, 3, "merged span counts its samples")
checkEqual(spans.first?.endDate, date(dayKey, 9, 3, 1), "span ends one interval after its last sample")

spans = BrainActivitySpanMerger.appending(sample(at: date(dayKey, 9, 3, 0), title: "Atlas flows"), to: spans, sampleIntervalSeconds: 60)
checkEqual(spans.count, 2, "a different window title starts a new span")
checkEqual(spans[0].endDate, date(dayKey, 9, 3, 0), "previous span clipped where the next begins")

spans = BrainActivitySpanMerger.appending(sample(at: date(dayKey, 9, 30), title: "Atlas flows"), to: spans, sampleIntervalSeconds: 60)
checkEqual(spans.count, 3, "an identical sample after a long gap (user away) starts a new span")

spans = BrainActivitySpanMerger.appending(
    sample(at: date(dayKey, 9, 31), app: "Google Chrome", bundle: "com.google.Chrome", title: "Issues", url: "https://github.com/a/b/issues", domain: "github.com"),
    to: spans, sampleIntervalSeconds: 60
)
spans = BrainActivitySpanMerger.appending(
    sample(at: date(dayKey, 9, 32), app: "Google Chrome", bundle: "com.google.Chrome", title: "Issues", url: "https://github.com/a/b/pulls", domain: "github.com"),
    to: spans, sampleIntervalSeconds: 60
)
checkEqual(spans.count, 5, "same title but a different URL is a different span")

// MARK: - Day keys and retention

checkEqual(BrainActivityDayKey.dayKey(for: date(dayKey, 23, 59), calendar: testCalendar), dayKey, "day key of a late-evening time")
checkEqual(BrainActivityDayKey.dayKey(fromFileName: "2026-09-29.json"), "2026-09-29", "json file name → day key")
checkEqual(BrainActivityDayKey.dayKey(fromFileName: "2026-09-29.md"), "2026-09-29", "md file name → day key")
check(BrainActivityDayKey.dayKey(fromFileName: "notes.md") == nil, "unrelated file ignored")
check(BrainActivityDayKey.dayKey(fromFileName: "2026-09-29.txt") == nil, "other extension ignored")
let retentionNow = date("2026-09-29", 12, 0)
check(BrainActivityDayKey.isExpired(dayKey: "2026-08-29", now: retentionNow, retentionDays: 30, calendar: testCalendar), "31 days old expires")
check(!BrainActivityDayKey.isExpired(dayKey: "2026-08-30", now: retentionNow, retentionDays: 30, calendar: testCalendar), "30 days old is kept")

// MARK: - Markdown and files

let dayLog = BrainActivityDayLog(dayKey: dayKey, spans: spans)
let markdown = BrainActivityLogMarkdown.render(dayLog, calendar: testCalendar)
check(markdown.hasPrefix("# Activity 2026-09-29"), "markdown heading")
check(markdown.contains("- 09:00–09:03 · Figma · Atlas spec"), "markdown span line")
check(markdown.contains("<https://github.com/a/b/issues>"), "markdown carries the cleaned URL")

let temporaryFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("brain-activity-tests-\(UUID().uuidString)", isDirectory: true)
let logFiles = BrainActivityLogFiles(activityFolderURL: temporaryFolderURL)
logFiles.save(dayLog)
logFiles.save(BrainActivityDayLog(dayKey: "2026-07-01", spans: []))
try? "keep me".write(to: temporaryFolderURL.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
checkEqual(logFiles.load(dayKey: dayKey), dayLog, "day log round-trips through JSON")
checkEqual(logFiles.recordedDayKeys(), ["2026-07-01", dayKey], "recorded day keys, oldest first")
let jsonPermissions = (try? FileManager.default.attributesOfItem(atPath: logFiles.jsonFileURL(forDayKey: dayKey).path))?[.posixPermissions] as? Int
checkEqual(jsonPermissions, 0o600, "log files are owner-only")
logFiles.deleteFiles(olderThanDays: 30, now: date("2026-09-29", 12, 0))
checkEqual(logFiles.recordedDayKeys(), [dayKey], "retention deletes old days only")
logFiles.deleteAllFiles()
checkEqual(logFiles.recordedDayKeys(), [], "delete all removes every day")
check(FileManager.default.fileExists(atPath: temporaryFolderURL.appendingPathComponent("README.txt").path), "delete all leaves unrelated files")
try? FileManager.default.removeItem(at: temporaryFolderURL)

// MARK: - Work item naming

func workItem(_ title: String?, app: String, bundle: String, domain: String? = nil) -> String? {
    BrainActivityWorkItemNamer.workItemName(windowTitle: title, applicationName: app, bundleIdentifier: bundle, domain: domain)
}
checkEqual(workItem("BrainStore.swift — clicky — Visual Studio Code", app: "Code", bundle: "com.microsoft.VSCode"), "clicky", "VS Code: project, not file")
checkEqual(workItem("● BrainStore.swift — clicky", app: "Cursor", bundle: "com.todesktop.230313mzl4w4u92"), "clicky", "Cursor with unsaved marker")
checkEqual(workItem("clicky — BrainStore.swift", app: "Xcode", bundle: "com.apple.dt.Xcode"), "clicky", "Xcode: project first")
checkEqual(workItem("Atlas spec – Figma", app: "Google Chrome", bundle: "com.google.Chrome", domain: "figma.com"), "Atlas spec", "site name suffix stripped")
checkEqual(workItem("(3) Atlas launch plan - Google Docs", app: "Google Chrome", bundle: "com.google.Chrome", domain: "docs.google.com"), "Atlas launch plan", "notification count and Google Docs stripped")
checkEqual(workItem("Atlas spec", app: "Figma", bundle: "com.figma.Desktop"), "Atlas spec", "plain document title")
checkEqual(workItem("quarterly-report.pdf", app: "Preview", bundle: "com.apple.Preview"), "quarterly-report", "file extension stripped")
checkEqual(workItem("Atlas v2.0 plan", app: "Notes", bundle: "com.apple.Notes"), "Atlas v2.0 plan", "a dotted title with spaces keeps its dot")
checkEqual(workItem("Proposal — Edited", app: "Pages", bundle: "com.apple.iWork.Pages"), "Proposal", "'— Edited' stripped")
check(workItem("New Tab - Google Chrome", app: "Google Chrome", bundle: "com.google.Chrome") == nil, "New Tab is not a work item")
check(workItem("Slack", app: "Slack", bundle: "com.tinyspeck.slackmacgap") == nil, "just the app's name is not a work item")
check(workItem("YouTube", app: "Google Chrome", bundle: "com.google.Chrome", domain: "youtube.com") == nil, "just the site name is not a work item")
check(workItem(nil, app: "Finder", bundle: "com.apple.finder") == nil, "no title, no work item")
checkEqual(BrainActivityWorkItemNamer.registrableLabel(ofDomain: "news.bbc.co.uk"), "bbc", "registrable label with a two-part suffix")

// MARK: - Summary

let summaryDayLog = BrainActivityDayLog(dayKey: dayKey, spans: [
    span(date(dayKey, 9, 0), minutes: 70, app: "Figma", bundle: "com.figma.Desktop", title: "Atlas spec"),
    span(date(dayKey, 10, 10), minutes: 50, app: "Google Chrome", bundle: "com.google.Chrome", title: "Atlas spec – Figma", domain: "figma.com"),
    span(date(dayKey, 11, 0), minutes: 45, app: "Code", bundle: "com.microsoft.VSCode", title: "main.swift — clicky — Visual Studio Code"),
    span(date(dayKey, 11, 45), minutes: 30, app: "Code", bundle: "com.microsoft.VSCode", title: "BrainStore.swift — clicky"),
    span(date(dayKey, 12, 15), minutes: 4, app: "Google Chrome", bundle: "com.google.Chrome", title: "Cats - YouTube", domain: "youtube.com"),
    span(date(dayKey, 12, 19), minutes: 20, app: "Slack", bundle: "com.tinyspeck.slackmacgap", title: "Slack"),
])
let daySummary = BrainActivitySummaryBuilder.summarize(summaryDayLog)
checkEqual(daySummary.totalDuration, 219 * 60, "total duration sums spans")
checkEqual(daySummary.workItems.first?.label, "Atlas spec", "top work item clusters across Figma and Chrome")
checkEqual(daySummary.workItems.first?.duration, 120 * 60, "clustered work item time")
checkEqual(daySummary.workItems.first?.detail, "Figma, Google Chrome", "work item lists its apps")
checkEqual(daySummary.workItems.dropFirst().first?.label, "clicky", "second work item is the VS Code project")
checkEqual(daySummary.workItems.dropFirst().first?.duration, 75 * 60, "project time spans files")
checkEqual(daySummary.applications.map(\.label), ["Code", "Figma", "Google Chrome", "Slack"], "apps by time")
checkEqual(daySummary.sites.map(\.label), ["figma.com", "youtube.com"], "sites by time")
checkEqual(daySummary.displayRows(limitPerKind: 1).map(\.kind), [.workItem, .application, .site], "display rows: work items, apps, sites")

// MARK: - Durations

checkEqual(BrainActivityDurationFormatter.approximateText(for: 120 * 60), "~2h", "2 hours")
checkEqual(BrainActivityDurationFormatter.approximateText(for: 92 * 60), "~1h 30m", "rounded to 5 minutes")
checkEqual(BrainActivityDurationFormatter.approximateText(for: 23 * 60), "~25m", "minutes only")
checkEqual(BrainActivityDurationFormatter.approximateText(for: 60), "<5m", "under five minutes")

// MARK: - Digest text

let compactSummary = BrainActivityDigestText.compactSummary(of: daySummary) ?? ""
check(compactSummary.contains("Date: 2026-09-29"), "digest names the day")
check(compactSummary.contains("- ~2h on \"Atlas spec\" (in Figma, Google Chrome)"), "digest line for the top work item")
check(compactSummary.contains("~1h 15m on \"clicky\""), "digest line for the project")
check(!compactSummary.contains("Cats"), "trivial browsing (4 min) doesn't reach the model")
check(!compactSummary.contains("youtube.com"), "a short site visit doesn't reach the model")
check(!compactSummary.contains("https://"), "no URLs in the digest")
let quietDay = BrainActivitySummaryBuilder.summarize(BrainActivityDayLog(dayKey: dayKey, spans: [
    span(date(dayKey, 9, 0), minutes: 8, app: "Figma", bundle: "com.figma.Desktop", title: "Atlas spec")
]))
check(BrainActivityDigestText.compactSummary(of: quietDay) == nil, "a near-empty day isn't digested")
check(BrainActivityDigestText.extraInstructions(forDayKey: dayKey).contains("## Timeline"), "instructions ask for Timeline bullets")

// MARK: - Digest schedule

let recordedDayKeys = ["2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29"]
checkEqual(
    BrainActivityDigestSchedule.dayKeysDueForDigest(now: date("2026-09-29", 10, 0), recordedDayKeys: recordedDayKeys, digestedDayKeys: ["2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28"], calendar: testCalendar),
    [],
    "today isn't due before 18:00"
)
checkEqual(
    BrainActivityDigestSchedule.dayKeysDueForDigest(now: date("2026-09-29", 18, 1), recordedDayKeys: recordedDayKeys, digestedDayKeys: ["2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28"], calendar: testCalendar),
    ["2026-09-29"],
    "today is due after 18:00"
)
checkEqual(
    BrainActivityDigestSchedule.dayKeysDueForDigest(now: date("2026-09-29", 9, 0), recordedDayKeys: recordedDayKeys, digestedDayKeys: ["2026-09-24", "2026-09-25", "2026-09-26"], calendar: testCalendar),
    ["2026-09-27", "2026-09-28"],
    "missed earlier days are caught up the next morning"
)
checkEqual(
    BrainActivityDigestSchedule.dayKeysDueForDigest(now: date("2026-09-29", 19, 0), recordedDayKeys: recordedDayKeys, digestedDayKeys: [], calendar: testCalendar),
    ["2026-09-27", "2026-09-28", "2026-09-29"],
    "catch-up is capped at the 3 most recent days"
)

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
