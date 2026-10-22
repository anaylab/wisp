//
//  Download concierge suite (Chrome extension phase 07): the payload, rule
//  matching, the rules file, suggested names and templates, collision-safe
//  names, and the refusals.
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

let home = "/Users/someone"
let utc = TimeZone(identifier: "UTC")!
let filedAt = Date(timeIntervalSince1970: 1_792_065_600) // 2026-10-15 12:00 UTC

func file(
    _ fileName: String,
    folder: String = "/Users/someone/Downloads",
    mime: String = "",
    page: String? = "https://arxiv.org/abs/2401.12345",
    title: String = "",
    dangerous: Bool = false
) -> DownloadedFile {
    DownloadedFile(
        downloadID: 1,
        filePath: folder + "/" + fileName,
        mimeType: mime,
        sourcePageURL: page.flatMap(URL.init(string:)),
        pageTitle: title,
        isDangerous: dangerous
    )
}

func payload(_ json: String) -> ChromeDownloadItem? {
    try? JSONDecoder().decode(ChromeDownloadItem.self, from: Data(json.utf8))
}

// MARK: - Payload

if let item = payload(#"{"id":7,"filename":"/Users/someone/Downloads/2401.12345v2.pdf","mime":"application/pdf","fileSize":12345,"state":"complete","danger":"safe","dangerous":false,"exists":true,"url":"https://arxiv.org/pdf/2401.12345v2","finalUrl":"https://arxiv.org/pdf/2401.12345v2","referrer":"https://arxiv.org/abs/2401.12345","sourcePageUrl":"https://www.arxiv.org/abs/2401.12345","pageTitle":"[2401.12345] Attention"}"#) {
    let downloaded = DownloadedFile(downloadItem: item)
    checkEqual(downloaded.downloadID, 7, "payload id")
    checkEqual(downloaded.fileName, "2401.12345v2.pdf", "file name from the absolute path")
    checkEqual(downloaded.fileExtension, "pdf", "extension")
    checkEqual(downloaded.sourceHost, "arxiv.org", "host loses www.")
    check(downloaded.isPDF, "a pdf")
    check(!downloaded.isDangerous, "safe")
} else {
    check(false, "the event payload decodes")
}

if let oldPayload = payload(#"{"id":1,"filename":"/Users/someone/Downloads/x.exe","danger":"file","referrer":"https://bad.example/"}"#) {
    let downloaded = DownloadedFile(downloadItem: oldPayload)
    check(downloaded.isDangerous, "a payload without `dangerous` reads danger \"file\" as dangerous")
    checkEqual(downloaded.sourceHost, "bad.example", "the referrer stands in for the source page")
} else {
    check(false, "a minimal payload decodes")
}
check(payload(#"{"filename":"/x"}"#) == nil, "a payload without an id is refused")
check(file("a.png").isImage && file("a", mime: "image/webp").isImage, "images by extension or MIME")
check(file("a.pdf", page: "file:///Users/someone/a.html").sourceHost == nil, "a file: page has no host")

// MARK: - Matching

let papersRule = DownloadFilingRule(id: "papers", name: "Papers", fileExtensions: [".PDF"], sourceHosts: ["https://www.arxiv.org/"], destinationFolder: "~/Documents/Papers")
check(DownloadFilingRuleMatcher.matches(papersRule, file("x.pdf")), "extension + host match (normalised)")
check(DownloadFilingRuleMatcher.matches(papersRule, file("x.pdf", page: "https://export.arxiv.org/abs/1")), "a subdomain matches")
check(!DownloadFilingRuleMatcher.matches(papersRule, file("x.pdf", page: "https://notarxiv.org/abs/1")), "a look-alike host doesn't")
check(!DownloadFilingRuleMatcher.matches(papersRule, file("x.zip")), "every filled criterion must match")
check(!DownloadFilingRuleMatcher.matches(papersRule, file("x.pdf", page: nil)), "a host rule needs a source page")

let imagesRule = DownloadFilingRule(name: "Images", mimeTypes: ["image/*"], destinationFolder: "~/Pictures/Downloads")
check(DownloadFilingRuleMatcher.matches(imagesRule, file("a.png", mime: "image/png")), "image/* matches image/png")
check(!DownloadFilingRuleMatcher.matches(imagesRule, file("a.pdf", mime: "application/pdf")), "image/* doesn't match a pdf")
check(DownloadFilingRuleMatcher.mimeType("application/pdf", matches: "application/pdf"), "exact MIME")
check(!DownloadFilingRuleMatcher.mimeType("application/", matches: "image/png"), "prefix MIME")

let statementsRule = DownloadFilingRule(name: "Statements", filenameWords: ["bank statement", "invoice"], destinationFolder: "~/Documents/Money")
check(DownloadFilingRuleMatcher.matches(statementsRule, file("Bank_Statement-2026-09.pdf")), "words across underscores and hyphens")
check(DownloadFilingRuleMatcher.matches(statementsRule, file("INVOICE 42.pdf")), "any entry, any case")
check(!DownloadFilingRuleMatcher.matches(statementsRule, file("bankruptcy.pdf")), "whole words only")

let emptyRule = DownloadFilingRule(name: "Empty", destinationFolder: "~/Documents")
check(!DownloadFilingRuleMatcher.matches(emptyRule, file("x.pdf")), "a rule with no criteria matches nothing")
checkEqual(
    DownloadFilingRuleMatcher.firstMatchingRule(for: file("x.pdf"), in: [imagesRule, papersRule, statementsRule])?.id,
    "papers",
    "the first matching rule wins"
)

// MARK: - Rules file

let rulesJSON = #"""
{"version":1,"rules":[
  {"name":"Papers","fileExtensions":["pdf"],"sourceHosts":["arxiv.org"],"destinationFolder":"~/Documents/Papers","renameTemplate":"{title}","always":true},
  {"name":"No folder","fileExtensions":["zip"]},
  {"name":"Matches nothing","destinationFolder":"~/Documents"},
  {"name":"Escapes","fileExtensions":["dmg"],"destinationFolder":"~/../../Applications"},
  {"name":"Secrets","fileExtensions":["pem"],"destinationFolder":"~/.ssh"},
  {"name":"Library","fileExtensions":["plist"],"destinationFolder":"~/Library/Preferences"},
  {"name":"Relative","fileExtensions":["txt"],"destinationFolder":"Documents"},
  {"name":"Images","mimeTypes":["image/*"],"destinationFolder":"/Users/someone/Pictures"}
]}
"""#
let loadResult = DownloadFilingRuleFile.load(from: Data(rulesJSON.utf8), homeDirectoryPath: home)
checkEqual(loadResult.usableRules.map(\.name), ["Papers", "Images"], "only rules that can work are kept")
checkEqual(loadResult.problems.count, 6, "each dropped rule says why")
check(loadResult.usableRules.first?.always == true, "always is read")
check(loadResult.usableRules.last?.always == false && loadResult.usableRules.last?.addToBrain == false, "missing flags default to off")
checkEqual(DownloadFilingRuleFile.load(from: Data("nope".utf8), homeDirectoryPath: home).problems, ["download-rules.json isn't valid JSON"], "bad JSON")
checkEqual(DownloadFilingRuleFile.load(from: Data("{}".utf8), homeDirectoryPath: home).usableRules.count, 0, "an empty object is no rules")

if let starterData = try? DownloadFilingRuleFile.starterFile.encoded() {
    let reloaded = DownloadFilingRuleFile.load(from: starterData, homeDirectoryPath: home)
    checkEqual(reloaded.usableRules, DownloadFilingRuleFile.starterFile.rules, "the starter file round-trips")
    check(reloaded.usableRules.allSatisfy { !$0.always }, "the starter rule only offers")
} else {
    check(false, "the starter file encodes")
}

// Saving "always" back changes that one rule and nothing else.
let handWrittenRules = #"{"note":"mine","rules":[{"name":"Papers","fileExtensions":["pdf"],"destinationFolder":"~/Documents/Papers"},{"name":"Half-written"},{"id":"img","name":"Images","mimeTypes":["image/*"],"destinationFolder":"~/Pictures"}]}"#
let papersID = DownloadFilingRuleFile.load(from: Data(handWrittenRules.utf8), homeDirectoryPath: home).usableRules.first?.id ?? ""
checkEqual(papersID, "name:Papers", "a rule without an id gets a stable one from its name")
if let updatedData = DownloadFilingRuleFile.settingAlways(onRuleWithID: papersID, inFileData: Data(handWrittenRules.utf8)),
   let updatedObject = (try? JSONSerialization.jsonObject(with: updatedData)) as? [String: Any],
   let updatedRules = updatedObject["rules"] as? [[String: Any]] {
    check(updatedRules[0]["always"] as? Bool == true, "the rule is marked always")
    check(updatedRules[1]["always"] == nil && updatedRules[2]["always"] == nil, "no other rule changes")
    checkEqual(updatedRules.count, 3, "a half-written rule survives")
    checkEqual(updatedObject["note"] as? String, "mine", "unknown keys survive")
} else {
    check(false, "settingAlways rewrites the file")
}
check(DownloadFilingRuleFile.settingAlways(onRuleWithID: "img", inFileData: Data(handWrittenRules.utf8)) != nil, "an explicit id is found")
check(DownloadFilingRuleFile.settingAlways(onRuleWithID: "missing", inFileData: Data(handWrittenRules.utf8)) == nil, "an unknown rule changes nothing")

// MARK: - Suggested names

checkEqual(DownloadNameSuggester.cleanedFileStem(of: "Paper_final (1).pdf"), "Paper final", "Chrome's (1) and underscores go")
checkEqual(DownloadNameSuggester.cleanedFileStem(of: "my-paper+v2.pdf"), "my-paper v2", "hyphens stay, plus goes")
checkEqual(DownloadNameSuggester.cleanedFileStem(of: "Annual%20Report.pdf"), "Annual Report", "percent escapes are decoded")
checkEqual(DownloadNameSuggester.cleanedFileStem(of: "...hidden.txt"), "hidden", "no leading dots")
checkEqual(DownloadNameSuggester.cleanedFileStem(of: "___.zip"), "Download", "nothing left becomes Download")

checkEqual(DownloadNameSuggester.cleanedPageTitle("Attention Is All You Need | arXiv", sourceHost: "arxiv.org"), "Attention Is All You Need", "short site suffix dropped")
checkEqual(DownloadNameSuggester.cleanedPageTitle("Graphs - A Survey of Everything We Know", sourceHost: nil), "Graphs - A Survey of Everything We Know", "a long tail is part of the title")
checkEqual(DownloadNameSuggester.cleanedPageTitle("Physics: An Intro", sourceHost: nil), "Physics - An Intro", "a colon becomes a dash")
checkEqual(DownloadNameSuggester.cleanedPageTitle("../../etc/passwd", sourceHost: nil), "-..-etc-passwd", "path separators can't survive (dots inside one name are harmless)")
check(DownloadNameSuggester.cleanedPageTitle("Untitled", sourceHost: nil) == nil, "Untitled is meaningless")
check(DownloadNameSuggester.cleanedPageTitle("https://arxiv.org/pdf/1", sourceHost: nil) == nil, "a URL isn't a title")
check(DownloadNameSuggester.cleanedPageTitle("arxiv.org", sourceHost: "arxiv.org") == nil, "the bare host isn't a title")
check(DownloadNameSuggester.cleanedPageTitle("  ", sourceHost: nil) == nil, "blank isn't a title")
checkEqual(DownloadNameSuggester.sanitizedFileNameComponent("a\nb\u{0}c/d\\e"), "a b c-d-e", "control characters and separators")
check(DownloadNameSuggester.cappedAtWordBoundary(String(repeating: "word ", count: 50)).count <= DownloadNameSuggester.maximumBaseNameCharacters, "long names are capped")

let arxivPDF = file("2401.12345v2.pdf", mime: "application/pdf", title: "[2401.12345] Attention Is All You Need")
checkEqual(DownloadNameSuggester.suggestedBaseName(for: arxivPDF, renameTemplate: nil, filedAt: filedAt), "[2401.12345] Attention Is All You Need", "a PDF is named after its page")
let photo = file("IMG_0001.jpg", mime: "image/jpeg", title: "Sunset over the bay - Unsplash")
checkEqual(DownloadNameSuggester.suggestedBaseName(for: photo, renameTemplate: nil, filedAt: filedAt), "Sunset over the bay", "an image is named after its page")
let installer = file("Firefox 130.0.dmg", mime: "application/x-apple-diskimage", page: "https://mozilla.org/download", title: "Download Firefox for Mac")
checkEqual(DownloadNameSuggester.suggestedBaseName(for: installer, renameTemplate: nil, filedAt: filedAt), "Firefox 130.0", "a .dmg only gets its cleaned name")
let untitledPDF = file("report_v2 (3).pdf", mime: "application/pdf", title: "Untitled")
checkEqual(DownloadNameSuggester.suggestedBaseName(for: untitledPDF, renameTemplate: nil, filedAt: filedAt), "report v2", "a PDF with a useless title keeps its cleaned name")

checkEqual(DownloadNameSuggester.suggestedBaseName(for: arxivPDF, renameTemplate: "{date} {site} {title}", filedAt: filedAt, timeZone: utc), "2026-10-15 arxiv.org [2401.12345] Attention Is All You Need", "every placeholder")
checkEqual(DownloadNameSuggester.suggestedBaseName(for: file("x.pdf", page: nil), renameTemplate: "{site} - {title}", filedAt: filedAt), "x", "an empty site leaves no dangling dash")
checkEqual(DownloadNameSuggester.suggestedBaseName(for: installer, renameTemplate: "{title}", filedAt: filedAt), "Download Firefox for Mac", "a template uses the title for any file type")
checkEqual(DownloadNameSuggester.suggestedBaseName(for: installer, renameTemplate: "   ", filedAt: filedAt), "Firefox 130.0", "a blank template is no template")
checkEqual(DownloadNameSuggester.render(template: "{date}/{title}", title: "A", site: "", date: filedAt, timeZone: utc), "2026-10-15-A", "a slash in a template can't make a folder")
checkEqual(DownloadNameSuggester.suggestedBaseName(for: file("x.pdf", title: ""), renameTemplate: "{site}", filedAt: filedAt), "arxiv.org", "site alone")

checkEqual(DownloadNameSuggester.fileName(baseName: "Paper", fileExtension: "pdf"), "Paper.pdf", "extension added back")
checkEqual(DownloadNameSuggester.fileName(baseName: "README", fileExtension: ""), "README", "no extension, no dot")

// MARK: - Collisions

let takenNames: Set<String> = ["paper.pdf", "paper 2.pdf"]
checkEqual(DownloadCollisionNaming.availableFileName(baseName: "Fresh", fileExtension: "pdf") { takenNames.contains($0.lowercased()) }, "Fresh.pdf", "a free name is used as is")
checkEqual(DownloadCollisionNaming.availableFileName(baseName: "Paper", fileExtension: "pdf") { takenNames.contains($0.lowercased()) }, "Paper 3.pdf", "taken names count up from 2")
check(DownloadCollisionNaming.availableFileName(baseName: "Paper", fileExtension: "pdf") { _ in true } == nil, "nil when every name is taken")

// MARK: - Refusals

checkEqual(DownloadFilingSafety.expandedFolderPath("~/Documents/Papers/", homeDirectoryPath: home), "/Users/someone/Documents/Papers", "tilde expands, trailing slash goes")
checkEqual(DownloadFilingSafety.expandedFolderPath("~", homeDirectoryPath: home), home, "bare tilde is home")
check(DownloadFilingSafety.expandedFolderPath("Documents", homeDirectoryPath: home) == nil, "relative folders are refused")
checkEqual(DownloadFilingSafety.expandedFolderPath("~/a/../../../etc", homeDirectoryPath: home), "/etc", ".. is resolved before any check")

check(DownloadFilingSafety.destinationRefusal(destinationFolderPath: "/Users/someone/Documents", homeDirectoryPath: home) == nil, "a folder in home is fine")
check(DownloadFilingSafety.destinationRefusal(destinationFolderPath: "/private/tmp/does-not-exist-yet/Papers", homeDirectoryPath: "/private/tmp") == nil, "a folder that doesn't exist yet is still inside its parent (no /private stripping)")
checkEqual(DownloadFilingSafety.standardizedPath("/Users/someone//Documents/./a/../Papers/"), "/Users/someone/Documents/Papers", "pure path standardising")
checkEqual(DownloadFilingSafety.destinationRefusal(destinationFolderPath: "/etc", homeDirectoryPath: home), .destinationOutsideHome, "outside home")
checkEqual(DownloadFilingSafety.destinationRefusal(destinationFolderPath: "/Users/someoneelse/Documents", homeDirectoryPath: home), .destinationOutsideHome, "a sibling home with the same prefix")
checkEqual(DownloadFilingSafety.destinationRefusal(destinationFolderPath: "/Users/someone/Library/LaunchAgents", homeDirectoryPath: home), .destinationIsPrivateFolder, "Library")
checkEqual(DownloadFilingSafety.destinationRefusal(destinationFolderPath: "/Users/someone/Documents/.secret", homeDirectoryPath: home), .destinationIsPrivateFolder, "a hidden folder anywhere below home")

checkEqual(DownloadFilingSafety.sourceRefusal(for: file("x.exe", dangerous: true), homeDirectoryPath: home), .dangerousDownload, "dangerous downloads are refused")
checkEqual(DownloadFilingSafety.sourceRefusal(for: file("x.pdf", folder: "/Volumes/USB"), homeDirectoryPath: home), .fileOutsideHome, "a file outside home is refused")
check(DownloadFilingSafety.sourceRefusal(for: file("x.pdf"), homeDirectoryPath: home) == nil, "a normal download is fine")
check(!DownloadFilingRefusal.dangerousDownload.explanation.isEmpty, "refusals explain themselves")
checkEqual(DownloadFilingSafety.abbreviatedPath("/Users/someone/Documents/Papers", homeDirectoryPath: home), "~/Documents/Papers", "abbreviated for cards")
checkEqual(DownloadFilingSafety.abbreviatedPath("/Volumes/USB", homeDirectoryPath: home), "/Volumes/USB", "paths outside home stay absolute")

// MARK: - Plans

func plan(_ downloaded: DownloadedFile, rules: [DownloadFilingRule]) -> Result<DownloadFilingPlan, DownloadFilingRefusal> {
    DownloadFilingPlanner.plan(for: downloaded, rules: rules, homeDirectoryPath: home, filedAt: filedAt, timeZone: utc) { ["pdf", "md"].contains($0) }
}

if case .success(let papersPlan) = plan(arxivPDF, rules: [papersRule]) {
    checkEqual(papersPlan.destinationFolderPath, "/Users/someone/Documents/Papers", "a rule's folder")
    checkEqual(papersPlan.suggestedFileName, "[2401.12345] Attention Is All You Need.pdf", "suggested name keeps the extension")
    check(papersPlan.movesToAnotherFolder && papersPlan.renamesFile && papersPlan.changesSomething, "it moves and renames")
    check(papersPlan.canAddToBrain && !papersPlan.addsToBrainByDefault, "brain is possible but off unless the rule says so")
    check(!papersPlan.appliesWithoutAsking, "a rule not marked always asks")
} else {
    check(false, "the papers plan")
}

var alwaysPapersRule = papersRule
alwaysPapersRule.always = true
alwaysPapersRule.addToBrain = true
if case .success(let alwaysPlan) = plan(arxivPDF, rules: [alwaysPapersRule]) {
    check(alwaysPlan.appliesWithoutAsking, "an always rule applies without a card")
    check(alwaysPlan.addsToBrainByDefault, "and adds to the brain when it says so")
} else {
    check(false, "the always plan")
}

if case .success(let noRulePlan) = plan(installer, rules: [papersRule]) {
    check(noRulePlan.matchedRule == nil, "no rule for a dmg")
    checkEqual(noRulePlan.destinationFolderPath, "/Users/someone/Downloads", "without a rule it stays in its folder")
    check(!noRulePlan.changesSomething, "an already-clean dmg has nothing to file")
    check(!noRulePlan.canAddToBrain, "the brain can't read a dmg")
} else {
    check(false, "the dmg plan")
}

let escapingRule = DownloadFilingRule(name: "Escapes", fileExtensions: ["pdf"], destinationFolder: "/tmp")
if case .success(let escapingPlan) = plan(arxivPDF, rules: [escapingRule]) {
    check(escapingPlan.matchedRule == nil, "a rule filing outside home is skipped even if it slipped past loading")
} else {
    check(false, "the escaping-rule plan")
}

checkEqual(plan(file("bad.pdf", dangerous: true), rules: [papersRule]).failureValue, .dangerousDownload, "a dangerous download gets no plan")

checkEqual(DownloadFilingPlanner.requestedBaseName("My Paper.pdf", originalFileExtension: "pdf"), "My Paper", "a typed matching extension isn't doubled")
checkEqual(DownloadFilingPlanner.requestedBaseName("notes.txt", originalFileExtension: "pdf"), "notes.txt", "a different extension stays in the base name")
checkEqual(DownloadFilingPlanner.requestedBaseName("../x", originalFileExtension: "pdf"), "-x", "no climbing out")
check(DownloadFilingPlanner.requestedBaseName("  ", originalFileExtension: "pdf") == nil, "a blank name is nil")

extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
