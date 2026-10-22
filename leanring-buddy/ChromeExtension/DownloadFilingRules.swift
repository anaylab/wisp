//
//  DownloadFilingRules.swift
//  leanring-buddy
//
//  The pure side of the download concierge (Chrome extension phase 07): what a
//  finished download is, the user's filing rules in `~/.wisp/download-rules.json`,
//  which rule a download matches, the name Wisp suggests, collision-safe names
//  (" 2", " 3"), and the refusals (a download Chrome flagged as dangerous, or a
//  path outside the user's home).
//
//  Nothing here touches the disk or the extension: the folder check and the
//  "is this name taken" question come in as values and closures, so
//  `Tests/ChromeExtDownloads` can cover every rule. `DownloadConcierge` does
//  the moving, only after the user said yes (or marked the rule "always").
//
//  The page title and file name come from the web, so they are untrusted. They
//  only ever become part of a file name, after `sanitizedFileNameComponent`
//  has taken out path separators, control characters and leading dots.
//

import Foundation

// MARK: - A download, as the extension reports it

/// One download in the shape the extension's `getDownloads` and
/// `download.*` events send (contracts.md §1, phase 07 payloads).
nonisolated struct ChromeDownloadItem: Decodable, Sendable, Equatable {
    let id: Int
    /// Chrome's absolute path on disk.
    let filename: String
    let mime: String?
    let fileSize: Double?
    let state: String?
    let error: String?
    let danger: String?
    let dangerous: Bool?
    let exists: Bool?
    let url: String?
    let finalUrl: String?
    let referrer: String?
    /// The page the download came from (referrer, or the tab showing the file).
    let sourcePageUrl: String?
    /// That page's title when a tab still shows it; untrusted page content.
    let pageTitle: String?
    let truncated: Bool?
}

/// `getDownloads`' reply.
nonisolated struct ChromeDownloadsListResult: Decodable, Sendable {
    let downloads: [ChromeDownloadItem]
    let truncated: Bool?
}

/// What Wisp knows about a finished download, read once from the payload.
nonisolated struct DownloadedFile: Equatable, Sendable {
    let downloadID: Int
    let filePath: String
    let mimeType: String
    let sourcePageURL: URL?
    let pageTitle: String
    let isDangerous: Bool

    init(downloadID: Int, filePath: String, mimeType: String, sourcePageURL: URL?, pageTitle: String, isDangerous: Bool) {
        self.downloadID = downloadID
        self.filePath = filePath
        self.mimeType = mimeType.lowercased()
        self.sourcePageURL = sourcePageURL
        self.pageTitle = pageTitle
        self.isDangerous = isDangerous
    }

    init(downloadItem: ChromeDownloadItem) {
        // The extension already decided `dangerous`; an older payload without it
        // is judged the same way (anything but "safe" was flagged).
        let isFlaggedByChrome = downloadItem.dangerous
            ?? !["", "safe"].contains((downloadItem.danger ?? "").lowercased())
        let sourcePageText = [downloadItem.sourcePageUrl, downloadItem.referrer]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        self.init(
            downloadID: downloadItem.id,
            filePath: downloadItem.filename,
            mimeType: downloadItem.mime ?? "",
            sourcePageURL: URL(string: sourcePageText),
            pageTitle: downloadItem.pageTitle ?? "",
            isDangerous: isFlaggedByChrome
        )
    }

    var fileName: String { (filePath as NSString).lastPathComponent }
    var folderPath: String { (filePath as NSString).deletingLastPathComponent }
    /// Lowercased, without the dot; "" when the file has none.
    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }

    /// "arxiv.org" for "https://www.arxiv.org/abs/…", nil when there's no web page.
    var sourceHost: String? {
        guard let sourcePageURL,
              let scheme = sourcePageURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = sourcePageURL.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif",
    ]

    var isPDF: Bool { fileExtension == "pdf" || mimeType == "application/pdf" }
    var isImage: Bool { mimeType.hasPrefix("image/") || Self.imageFileExtensions.contains(fileExtension) }
}

// MARK: - Rules

/// One filing rule. Every criterion that is filled in must match (and at least
/// one must be): extensions, MIME types (`image/*` allowed), source hosts (a
/// host matches its subdomains) and words in the file name. The first rule that
/// matches wins. `always` is the user's "do this without asking" mark.
nonisolated struct DownloadFilingRule: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var fileExtensions: [String]
    var mimeTypes: [String]
    var sourceHosts: [String]
    var filenameWords: [String]
    /// "~/Documents/Papers". Must end up inside the user's home.
    var destinationFolder: String
    /// "{date} {site} {title}", or nil to use the suggested name.
    var renameTemplate: String?
    var always: Bool
    var addToBrain: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        fileExtensions: [String] = [],
        mimeTypes: [String] = [],
        sourceHosts: [String] = [],
        filenameWords: [String] = [],
        destinationFolder: String,
        renameTemplate: String? = nil,
        always: Bool = false,
        addToBrain: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fileExtensions = fileExtensions
        self.mimeTypes = mimeTypes
        self.sourceHosts = sourceHosts
        self.filenameWords = filenameWords
        self.destinationFolder = destinationFolder
        self.renameTemplate = renameTemplate
        self.always = always
        self.addToBrain = addToBrain
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, fileExtensions, mimeTypes, sourceHosts, filenameWords
        case destinationFolder, renameTemplate, always, addToBrain
    }

    /// Lenient: the file is written by hand, so anything left out takes its
    /// default. Only `destinationFolder` is required.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        name = decodedName.isEmpty ? "Unnamed rule" : decodedName
        // A hand-written rule often has no id. Deriving one from the name keeps
        // it the same on every read, so "always" can be saved back onto it.
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "name:\(name)"
        fileExtensions = try container.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
        mimeTypes = try container.decodeIfPresent([String].self, forKey: .mimeTypes) ?? []
        sourceHosts = try container.decodeIfPresent([String].self, forKey: .sourceHosts) ?? []
        filenameWords = try container.decodeIfPresent([String].self, forKey: .filenameWords) ?? []
        destinationFolder = try container.decode(String.self, forKey: .destinationFolder)
        renameTemplate = try container.decodeIfPresent(String.self, forKey: .renameTemplate)
        always = try container.decodeIfPresent(Bool.self, forKey: .always) ?? false
        addToBrain = try container.decodeIfPresent(Bool.self, forKey: .addToBrain) ?? false
    }

    var hasAnyCriterion: Bool {
        !(fileExtensions.isEmpty && mimeTypes.isEmpty && sourceHosts.isEmpty && filenameWords.isEmpty)
    }
}

/// `~/.wisp/download-rules.json`: `{"version": 1, "rules": [ … ]}`.
nonisolated struct DownloadFilingRuleFile: Codable, Equatable, Sendable {
    var version: Int
    var rules: [DownloadFilingRule]

    static let currentVersion = 1

    /// A rule that can't be read never takes the rest of the file down with it.
    private struct FailableRule: Decodable {
        let rule: DownloadFilingRule?
        init(from decoder: Decoder) throws {
            rule = try? DownloadFilingRule(from: decoder)
        }
    }

    private struct LenientFile: Decodable {
        let version: Int?
        let rules: [FailableRule]?
    }

    struct LoadResult: Equatable, Sendable {
        /// Rules Wisp will use, in file order.
        let usableRules: [DownloadFilingRule]
        /// Why each other rule is ignored, for the log and the Settings row.
        let problems: [String]
    }

    /// Reads the file and keeps only rules that can work: a criterion to match
    /// on, and a destination folder inside the home folder.
    static func load(from fileData: Data, homeDirectoryPath: String) -> LoadResult {
        guard let lenientFile = try? JSONDecoder().decode(LenientFile.self, from: fileData) else {
            return LoadResult(usableRules: [], problems: ["download-rules.json isn't valid JSON"])
        }
        var usableRules: [DownloadFilingRule] = []
        var problems: [String] = []
        for (ruleIndex, failableRule) in (lenientFile.rules ?? []).enumerated() {
            guard let rule = failableRule.rule else {
                problems.append("rule \(ruleIndex + 1) has no destinationFolder")
                continue
            }
            guard rule.hasAnyCriterion else {
                problems.append("\"\(rule.name)\" matches nothing: give it an extension, type, site or word")
                continue
            }
            guard let destinationFolderPath = DownloadFilingSafety.expandedFolderPath(rule.destinationFolder, homeDirectoryPath: homeDirectoryPath),
                  DownloadFilingSafety.destinationRefusal(destinationFolderPath: destinationFolderPath, homeDirectoryPath: homeDirectoryPath) == nil else {
                problems.append("\"\(rule.name)\" files outside your home folder, so it's ignored")
                continue
            }
            usableRules.append(rule)
        }
        return LoadResult(usableRules: usableRules, problems: problems)
    }

    /// The file with one rule's `always` set to true, changing nothing else:
    /// the file is edited by hand, so unknown keys and rules Wisp can't use yet
    /// (a half-written one) must survive. nil when the rule isn't in it.
    static func settingAlways(onRuleWithID ruleID: String, inFileData fileData: Data) -> Data? {
        guard var fileObject = (try? JSONSerialization.jsonObject(with: fileData)) as? [String: Any],
              var ruleObjects = fileObject["rules"] as? [[String: Any]] else { return nil }
        let matchingRuleIndex = ruleObjects.firstIndex { ruleObject in
            if let explicitID = ruleObject["id"] as? String { return explicitID == ruleID }
            let ruleName = (ruleObject["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed rule"
            return "name:\(ruleName)" == ruleID
        }
        guard let matchingRuleIndex else { return nil }
        ruleObjects[matchingRuleIndex]["always"] = true
        fileObject["rules"] = ruleObjects
        return try? JSONSerialization.data(withJSONObject: fileObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// What "Edit rules…" writes when there is no file yet: one example the
    /// user can change. It only ever *offers* (always is false).
    static let starterFile = DownloadFilingRuleFile(
        version: currentVersion,
        rules: [
            DownloadFilingRule(
                id: "papers",
                name: "Papers",
                fileExtensions: ["pdf"],
                sourceHosts: ["arxiv.org"],
                destinationFolder: "~/Documents/Papers",
                renameTemplate: "{title}",
                always: false,
                addToBrain: true
            )
        ]
    )
}

nonisolated enum DownloadFilingRuleMatcher {

    static func firstMatchingRule(for downloadedFile: DownloadedFile, in rules: [DownloadFilingRule]) -> DownloadFilingRule? {
        rules.first { rule in matches(rule, downloadedFile) }
    }

    static func matches(_ rule: DownloadFilingRule, _ downloadedFile: DownloadedFile) -> Bool {
        guard rule.hasAnyCriterion else { return false }
        if !rule.fileExtensions.isEmpty {
            let wantedExtensions = Set(rule.fileExtensions.map(normalizedExtension))
            guard wantedExtensions.contains(downloadedFile.fileExtension) else { return false }
        }
        if !rule.mimeTypes.isEmpty {
            guard rule.mimeTypes.contains(where: { mimeType($0, matches: downloadedFile.mimeType) }) else { return false }
        }
        if !rule.sourceHosts.isEmpty {
            guard let sourceHost = downloadedFile.sourceHost,
                  rule.sourceHosts.contains(where: { host(sourceHost, isOrIsUnder: normalizedHost($0)) }) else { return false }
        }
        if !rule.filenameWords.isEmpty {
            let fileNameWords = Set(words(in: (downloadedFile.fileName as NSString).deletingPathExtension))
            let anyEntryMatches = rule.filenameWords.contains { entry in
                let entryWords = words(in: entry)
                return !entryWords.isEmpty && entryWords.allSatisfy(fileNameWords.contains)
            }
            guard anyEntryMatches else { return false }
        }
        return true
    }

    /// ".PDF" → "pdf".
    static func normalizedExtension(_ rawExtension: String) -> String {
        var trimmed = rawExtension.trimmingCharacters(in: .whitespaces).lowercased()
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed
    }

    /// "https://www.ArXiv.org/" → "arxiv.org".
    static func normalizedHost(_ rawHost: String) -> String {
        var host = rawHost.trimmingCharacters(in: .whitespaces).lowercased()
        if let schemeRange = host.range(of: "://") { host = String(host[schemeRange.upperBound...]) }
        if let slashIndex = host.firstIndex(of: "/") { host = String(host[..<slashIndex]) }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    /// "export.arxiv.org" is under "arxiv.org"; "notarxiv.org" is not.
    static func host(_ host: String, isOrIsUnder ruleHost: String) -> Bool {
        guard !ruleHost.isEmpty else { return false }
        return host == ruleHost || host.hasSuffix("." + ruleHost)
    }

    /// "image/*" or "image/" match any image; anything else must be exact.
    static func mimeType(_ ruleMIMEType: String, matches downloadedMIMEType: String) -> Bool {
        let ruleType = ruleMIMEType.trimmingCharacters(in: .whitespaces).lowercased()
        guard !ruleType.isEmpty, !downloadedMIMEType.isEmpty else { return false }
        if ruleType.hasSuffix("/*") {
            return downloadedMIMEType.hasPrefix(String(ruleType.dropLast()))
        }
        if ruleType.hasSuffix("/") {
            return downloadedMIMEType.hasPrefix(ruleType)
        }
        return downloadedMIMEType == ruleType
    }

    /// Lowercased runs of letters and digits ("Bank_Statement-2026" → bank, statement, 2026).
    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Names

nonisolated enum DownloadNameSuggester {

    /// A name longer than this is cut at a word boundary. Well under the
    /// 255-byte file name limit even with an extension and " 999".
    static let maximumBaseNameCharacters = 100

    /// Titles that say nothing about the file.
    private static let meaninglessTitles: Set<String> = [
        "untitled", "new tab", "download", "downloads", "loading", "loading…", "loading...", "document", "image", "pdf",
    ]

    /// The suggestion with no rule: the page's title for a PDF or an image (a
    /// paper's "2401.12345v2.pdf" becomes its title), otherwise the cleaned file
    /// name — a .dmg or a .zip is only tidied, never renamed after its page.
    /// With a rule's template, the template filled in.
    static func suggestedBaseName(for downloadedFile: DownloadedFile, renameTemplate: String?, filedAt: Date, timeZone: TimeZone = .current) -> String {
        let cleanedFileStem = cleanedFileStem(of: downloadedFile.fileName)
        let usablePageTitle = cleanedPageTitle(downloadedFile.pageTitle, sourceHost: downloadedFile.sourceHost)

        if let renameTemplate, !renameTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            let renderedName = render(
                template: renameTemplate,
                title: usablePageTitle ?? cleanedFileStem,
                site: downloadedFile.sourceHost ?? "",
                date: filedAt,
                timeZone: timeZone
            )
            return renderedName.isEmpty ? cleanedFileStem : renderedName
        }

        if downloadedFile.isPDF || downloadedFile.isImage, let usablePageTitle {
            return usablePageTitle
        }
        return cleanedFileStem
    }

    /// Fills `{date}` (2026-10-22), `{site}` and `{title}`, then tidies the
    /// separators an empty placeholder leaves behind ("{site} - {title}" with
    /// no site is "Title", not "- Title").
    static func render(template: String, title: String, site: String, date: Date, timeZone: TimeZone = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let filledTemplate = template
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{site}", with: site)
            .replacingOccurrences(of: "{title}", with: title)
        let separatorCharacters = CharacterSet(charactersIn: " -_·|.,")
        var tidiedName = sanitizedFileNameComponent(filledTemplate)
        // " -  - " runs from empty placeholders in the middle collapse to one " - ".
        while let doubledSeparatorRange = tidiedName.range(of: "- -") {
            tidiedName.replaceSubrange(doubledSeparatorRange, with: "-")
        }
        return tidiedName.trimmingCharacters(in: separatorCharacters)
    }

    /// "Paper_final (1).pdf" → "Paper final". Chrome's " (1)" duplicate
    /// marker, underscores and plus signs go; case and hyphens stay.
    static func cleanedFileStem(of fileName: String) -> String {
        var fileStem = (fileName as NSString).deletingPathExtension
        if fileStem.contains("%"), let percentDecodedStem = fileStem.removingPercentEncoding {
            fileStem = percentDecodedStem
        }
        if let duplicateMarkerRange = fileStem.range(of: #"\s*\(\d{1,3}\)$"#, options: .regularExpression) {
            fileStem.removeSubrange(duplicateMarkerRange)
        }
        fileStem = fileStem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "+", with: " ")
        let cleanedStem = cappedAtWordBoundary(sanitizedFileNameComponent(fileStem))
        return cleanedStem.isEmpty ? "Download" : cleanedStem
    }

    /// A page title worth naming a file after, or nil. "Attention Is All You
    /// Need | arXiv" loses its short site suffix; URLs, the bare host and
    /// "Untitled" are refused.
    static func cleanedPageTitle(_ rawTitle: String, sourceHost: String?) -> String? {
        // A tab still loading shows its address as the title; that's no name.
        let lowercasedRawTitle = rawTitle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowercasedRawTitle.contains("://"), !lowercasedRawTitle.hasPrefix("www.") else { return nil }
        var title = sanitizedFileNameComponent(rawTitle)
        for suffixSeparator in [" | ", " - ", " — ", " – ", " · "] {
            guard let separatorRange = title.range(of: suffixSeparator, options: .backwards) else { continue }
            let leadingPart = String(title[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let trailingPart = String(title[separatorRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if trailingPart.count <= 30 && leadingPart.count >= 8 {
                title = leadingPart
                break
            }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        let lowercasedTitle = title.lowercased()
        guard title.rangeOfCharacter(from: .alphanumerics) != nil,
              !meaninglessTitles.contains(lowercasedTitle),
              lowercasedTitle != sourceHost else { return nil }
        return cappedAtWordBoundary(title)
    }

    /// Makes untrusted text safe as one file name component: no path
    /// separators, no colon (Finder shows it as "/"), no control characters or
    /// newlines, no leading dot (a hidden file) or tilde, whitespace collapsed.
    static func sanitizedFileNameComponent(_ text: String) -> String {
        // "Paper: A Study" reads better as "Paper - A Study" than "Paper- A Study".
        let textWithSpacedColons = text.replacingOccurrences(of: ": ", with: " - ")
        var safeScalars = String.UnicodeScalarView()
        for scalar in textWithSpacedColons.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                safeScalars.append(" ")
            } else if scalar == "/" || scalar == "\\" || scalar == ":" {
                safeScalars.append("-")
            } else {
                safeScalars.append(scalar)
            }
        }
        var safeText = String(safeScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        while let firstCharacter = safeText.first, firstCharacter == "." || firstCharacter == "~" || firstCharacter == " " {
            safeText.removeFirst()
        }
        return safeText.trimmingCharacters(in: .whitespaces)
    }

    static func cappedAtWordBoundary(_ text: String, maximumCharacters: Int = maximumBaseNameCharacters) -> String {
        guard text.count > maximumCharacters else { return text }
        let hardCut = String(text.prefix(maximumCharacters))
        if let lastSpaceIndex = hardCut.lastIndex(of: " "), hardCut.distance(from: hardCut.startIndex, to: lastSpaceIndex) >= maximumCharacters / 2 {
            return String(hardCut[..<lastSpaceIndex]).trimmingCharacters(in: .whitespaces)
        }
        return hardCut.trimmingCharacters(in: .whitespaces)
    }

    /// The base name plus the file's *original* extension. A rename never
    /// changes the extension, so a .dmg can't become a .pdf.
    static func fileName(baseName: String, fileExtension: String) -> String {
        fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)"
    }
}

nonisolated enum DownloadCollisionNaming {

    static let highestNumberTried = 999

    /// "Paper.pdf", or "Paper 2.pdf", "Paper 3.pdf"… — the first name
    /// `isNameTaken` says is free. nil if all 999 are taken.
    static func availableFileName(baseName: String, fileExtension: String, isNameTaken: (String) -> Bool) -> String? {
        let plainFileName = DownloadNameSuggester.fileName(baseName: baseName, fileExtension: fileExtension)
        if !isNameTaken(plainFileName) { return plainFileName }
        for copyNumber in 2...highestNumberTried {
            let numberedFileName = DownloadNameSuggester.fileName(baseName: "\(baseName) \(copyNumber)", fileExtension: fileExtension)
            if !isNameTaken(numberedFileName) { return numberedFileName }
        }
        return nil
    }
}

// MARK: - Refusals

nonisolated enum DownloadFilingRefusal: Error, Equatable, Sendable {
    case dangerousDownload
    case fileOutsideHome
    case destinationOutsideHome
    case destinationIsPrivateFolder
    case noFreeName

    /// In Wisp's voice: lowercase, plain, what happened.
    var explanation: String {
        switch self {
        case .dangerousDownload:
            return "chrome flagged this download as dangerous, so i won't rename or move it."
        case .fileOutsideHome:
            return "that download isn't in your home folder, so i'll leave it where it is."
        case .destinationOutsideHome:
            return "i only file downloads into folders inside your home folder."
        case .destinationIsPrivateFolder:
            return "i won't file downloads into Library or hidden folders."
        case .noFreeName:
            return "every name i tried in that folder is taken."
        }
    }
}

nonisolated enum DownloadFilingSafety {

    /// "~/Documents/Papers" → "/Users/me/Documents/Papers" (standardised, so a
    /// ".." can't climb out). A relative path is nil: it has no fixed meaning.
    static func expandedFolderPath(_ rawFolder: String, homeDirectoryPath: String) -> String? {
        let trimmedFolder = rawFolder.trimmingCharacters(in: .whitespaces)
        let absoluteFolder: String
        if trimmedFolder == "~" {
            absoluteFolder = homeDirectoryPath
        } else if trimmedFolder.hasPrefix("~/") {
            absoluteFolder = homeDirectoryPath + "/" + trimmedFolder.dropFirst(2)
        } else if trimmedFolder.hasPrefix("/") {
            absoluteFolder = trimmedFolder
        } else {
            return nil
        }
        return standardizedPath(absoluteFolder)
    }

    /// Resolves "." and ".." and drops repeated or trailing slashes, purely on
    /// the text. Not `NSString.standardizingPath`: that also strips "/private"
    /// from "/private/tmp/…", but only when the path exists, so a folder about
    /// to be created compared as outside its own (existing) parent.
    static func standardizedPath(_ path: String) -> String {
        var keptComponents: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !keptComponents.isEmpty { keptComponents.removeLast() }
                continue
            }
            keptComponents.append(component)
        }
        return "/" + keptComponents.joined(separator: "/")
    }

    static func isPath(_ path: String, insideOrEqualTo directoryPath: String) -> Bool {
        let standardizedChild = standardizedPath(path)
        let standardizedDirectory = standardizedPath(directoryPath)
        return standardizedChild == standardizedDirectory || standardizedChild.hasPrefix(standardizedDirectory + "/")
    }

    /// Why a download can't be filed at all, or nil.
    static func sourceRefusal(for downloadedFile: DownloadedFile, homeDirectoryPath: String) -> DownloadFilingRefusal? {
        if downloadedFile.isDangerous { return .dangerousDownload }
        guard isPath(downloadedFile.filePath, insideOrEqualTo: homeDirectoryPath),
              standardizedPath(downloadedFile.filePath) != standardizedPath(homeDirectoryPath) else {
            return .fileOutsideHome
        }
        return nil
    }

    /// Why a folder can't receive a download, or nil. Inside home only, and
    /// never `~/Library` or a hidden folder like `~/.ssh` (app data and
    /// secrets, not places a person files things).
    static func destinationRefusal(destinationFolderPath: String, homeDirectoryPath: String) -> DownloadFilingRefusal? {
        let standardizedDestination = standardizedPath(destinationFolderPath)
        let standardizedHome = standardizedPath(homeDirectoryPath)
        guard isPath(standardizedDestination, insideOrEqualTo: standardizedHome) else { return .destinationOutsideHome }
        let componentsBelowHome = standardizedDestination
            .dropFirst(standardizedHome.count)
            .split(separator: "/")
        if componentsBelowHome.first == "Library" || componentsBelowHome.contains(where: { $0.hasPrefix(".") }) {
            return .destinationIsPrivateFolder
        }
        return nil
    }

    /// "/Users/me/Documents/Papers" → "~/Documents/Papers", for cards.
    static func abbreviatedPath(_ path: String, homeDirectoryPath: String) -> String {
        let standardized = standardizedPath(path)
        let standardizedHome = standardizedPath(homeDirectoryPath)
        if standardized == standardizedHome { return "~" }
        if standardized.hasPrefix(standardizedHome + "/") {
            return "~" + standardized.dropFirst(standardizedHome.count)
        }
        return standardized
    }
}

// MARK: - The plan for one download

/// What Wisp would do with a download: where to, under what name, and
/// whether the brain can take it. The final name is decided at filing time,
/// when Wisp can ask the disk which names are free.
nonisolated struct DownloadFilingPlan: Equatable, Sendable {
    let downloadedFile: DownloadedFile
    let matchedRule: DownloadFilingRule?
    let destinationFolderPath: String
    let suggestedBaseName: String
    let canAddToBrain: Bool

    var suggestedFileName: String {
        DownloadNameSuggester.fileName(baseName: suggestedBaseName, fileExtension: downloadedFile.fileExtension)
    }

    var movesToAnotherFolder: Bool {
        DownloadFilingSafety.standardizedPath(destinationFolderPath) != DownloadFilingSafety.standardizedPath(downloadedFile.folderPath)
    }

    var renamesFile: Bool { suggestedFileName != downloadedFile.fileName }

    /// Nothing to offer filing for: same folder, same name.
    var changesSomething: Bool { movesToAnotherFolder || renamesFile }

    /// A rule the user marked "always" applies without a card.
    var appliesWithoutAsking: Bool { matchedRule?.always == true }

    var addsToBrainByDefault: Bool { canAddToBrain && matchedRule?.addToBrain == true }
}

nonisolated enum DownloadFilingPlanner {

    /// The plan for a finished download, or why there can't be one. A rule
    /// whose folder is refused is skipped as if it didn't match (the loader
    /// already drops those, so this is a second lock).
    static func plan(
        for downloadedFile: DownloadedFile,
        rules: [DownloadFilingRule],
        homeDirectoryPath: String,
        filedAt: Date,
        timeZone: TimeZone = .current,
        canBrainRead: (String) -> Bool
    ) -> Result<DownloadFilingPlan, DownloadFilingRefusal> {
        if let sourceRefusal = DownloadFilingSafety.sourceRefusal(for: downloadedFile, homeDirectoryPath: homeDirectoryPath) {
            return .failure(sourceRefusal)
        }

        let safeRules = rules.filter { rule in
            guard let folderPath = DownloadFilingSafety.expandedFolderPath(rule.destinationFolder, homeDirectoryPath: homeDirectoryPath) else { return false }
            return DownloadFilingSafety.destinationRefusal(destinationFolderPath: folderPath, homeDirectoryPath: homeDirectoryPath) == nil
        }
        let matchedRule = DownloadFilingRuleMatcher.firstMatchingRule(for: downloadedFile, in: safeRules)
        let destinationFolderPath = matchedRule
            .flatMap { DownloadFilingSafety.expandedFolderPath($0.destinationFolder, homeDirectoryPath: homeDirectoryPath) }
            ?? DownloadFilingSafety.standardizedPath(downloadedFile.folderPath)

        let suggestedBaseName = DownloadNameSuggester.suggestedBaseName(
            for: downloadedFile,
            renameTemplate: matchedRule?.renameTemplate,
            filedAt: filedAt,
            timeZone: timeZone
        )
        return .success(DownloadFilingPlan(
            downloadedFile: downloadedFile,
            matchedRule: matchedRule,
            destinationFolderPath: destinationFolderPath,
            suggestedBaseName: suggestedBaseName,
            canAddToBrain: canBrainRead(downloadedFile.fileExtension)
        ))
    }

    /// A name the user or the model asked for: sanitised, and given the file's
    /// own extension (a ".pdf" they typed on a PDF isn't doubled, and a
    /// different extension stays part of the base name rather than replacing it).
    static func requestedBaseName(_ requestedName: String, originalFileExtension: String) -> String? {
        var baseName = DownloadNameSuggester.sanitizedFileNameComponent(requestedName)
        let typedExtension = (baseName as NSString).pathExtension.lowercased()
        if !originalFileExtension.isEmpty && typedExtension == originalFileExtension {
            baseName = (baseName as NSString).deletingPathExtension
        }
        baseName = DownloadNameSuggester.cappedAtWordBoundary(baseName.trimmingCharacters(in: .whitespaces))
        return baseName.isEmpty ? nil : baseName
    }
}
