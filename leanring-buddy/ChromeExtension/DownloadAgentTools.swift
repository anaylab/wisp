//
//  DownloadAgentTools.swift
//  leanring-buddy
//
//  The download concierge's agent tools (Chrome extension phase 07):
//  `chrome_list_downloads` (read) and `chrome_file_download` (rename/move,
//  always asks). Named with the `chrome_` prefix so they join the browser
//  scope and the buddy Browser tool group like the tab tools.
//
//  `chrome_file_download` resolves the model's arguments into the concrete
//  from/to paths *before* the confirmation card (an input preparer, like
//  `send_imessage`), so the card shows exactly which file moves where. It is
//  on `ToolCallSafety.alwaysAskBareToolNames`: renaming or moving a download
//  gets a card even under session auto-approve (contracts.md §6).
//

import Foundation

enum ChromeDownloadToolNames {
    static let listDownloads = "chrome_list_downloads"
    static let fileDownload = "chrome_file_download"
}

enum ChromeDownloadToolDefinitions {
    static let maximumListedDownloads = 20

    static let listDownloads = BuddyToolDefinition(
        name: ChromeDownloadToolNames.listDownloads,
        description: "List the user's recent Chrome downloads, newest first, with each download's id, file name, site and size. Use before chrome_file_download.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
        metadata: .reading(.localMachine)
    )

    static let fileDownload = BuddyToolDefinition(
        name: ChromeDownloadToolNames.fileDownload,
        description: "Rename a Chrome download and/or move it into a folder in the user's home, by its id from chrome_list_downloads. Leave out new_name and folder to use the user's filing rule or the suggested name. Keeps the file's extension. Never for files Chrome flagged as dangerous.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "download_id": .object(["type": .string("integer"), "description": .string("A download id from chrome_list_downloads.")]),
                "new_name": .object(["type": .string("string"), "description": .string("The new file name, without a folder. The extension stays the same.")]),
                "folder": .object(["type": .string("string"), "description": .string("A folder inside the user's home, e.g. \"~/Documents/Papers\". Created if missing.")])
            ]),
            "required": .array([.string("download_id")])
        ]),
        metadata: .writing(.localMachine)
    )

    /// One line per download for `chrome_list_downloads`.
    static func downloadListDescription(for downloadItems: [ChromeDownloadItem]) -> String {
        guard !downloadItems.isEmpty else { return "chrome has no recent downloads." }
        let homeDirectoryPath = DownloadConcierge.homeDirectoryPath
        // File names and sites come from the web, so the list goes inside the
        // data fence like any page text (contracts.md §6).
        var descriptionLines: [String] = [ChromePageTextPrompt.dataFenceNote, "<<<"]
        for downloadItem in downloadItems.prefix(maximumListedDownloads) {
            let downloadedFile = DownloadedFile(downloadItem: downloadItem)
            var facts: [String] = []
            if let sourceHost = downloadedFile.sourceHost { facts.append("from \(sourceHost)") }
            if let fileSize = downloadItem.fileSize, fileSize > 0 {
                facts.append(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
            }
            let state = downloadItem.state ?? ""
            if !state.isEmpty && state != "complete" { facts.append(state) }
            if downloadItem.exists == false { facts.append("file deleted") }
            if downloadedFile.isDangerous { facts.append("flagged dangerous by chrome") }
            let folderText = DownloadFilingSafety.abbreviatedPath(downloadedFile.folderPath, homeDirectoryPath: homeDirectoryPath)
            let listedLine = "  id \(downloadItem.id): \(downloadedFile.fileName) in \(folderText) — \(facts.joined(separator: ", "))"
            descriptionLines.append(ChromeTabToolDefinitions.listedPageText(listedLine))
        }
        descriptionLines.append(">>>")
        return descriptionLines.joined(separator: "\n")
    }
}

extension AgentToolRegistry {

    /// Registers the download tools. Like the tab tools they are always
    /// registered; without the extension or the downloads permission each one
    /// says what to do.
    func registerChromeDownloadTools() {
        register(ChromeDownloadToolDefinitions.listDownloads) { _ in
            let downloadItems = try await Self.fetchRecentChromeDownloads(limit: ChromeDownloadToolDefinitions.maximumListedDownloads)
            return ChromeDownloadToolDefinitions.downloadListDescription(for: downloadItems)
        }

        register(
            ChromeDownloadToolDefinitions.fileDownload,
            preparingInputWith: { input in
                await Self.prepareFileDownloadInput(input)
            }
        ) { preparedInput in
            // Only the prepared fields run: the paths were worked out (and
            // checked) by Wisp before the user was asked, never typed by the model.
            guard case .object(let preparedArguments) = preparedInput,
                  case .number(let rawDownloadID)? = preparedArguments["download_id"],
                  let downloadID = Int(exactly: rawDownloadID),
                  case .string(let destinationFilePath)? = preparedArguments["to"] else {
                return "i couldn't work out which download to file."
            }
            // Re-read the download: it may have moved or been flagged since the card.
            guard let downloadItem = try await Self.fetchChromeDownload(withID: downloadID) else {
                return "that download isn't in chrome's list any more."
            }
            let downloadedFile = DownloadedFile(downloadItem: downloadItem)
            let filingRecord = try DownloadConcierge.shared.fileDownload(
                downloadedFile,
                intoFolderPath: (destinationFilePath as NSString).deletingLastPathComponent,
                baseName: ((destinationFilePath as NSString).lastPathComponent as NSString).deletingPathExtension
            )
            let homeDirectoryPath = DownloadConcierge.homeDirectoryPath
            return "filed \(downloadedFile.fileName) as \(DownloadFilingSafety.abbreviatedPath(filingRecord.filedFilePath, homeDirectoryPath: homeDirectoryPath))."
        }
    }

    /// The model's `download_id` / `new_name` / `folder` → `{download_id, from, to}`
    /// with real paths, or a reason it can't be done (nothing is asked then).
    private static func prepareFileDownloadInput(_ input: JSONValue) async -> ToolInputPreparation {
        guard case .object(let arguments) = input, let downloadID = integerArgument(arguments["download_id"]) else {
            return .finished("i need a download id from chrome_list_downloads.")
        }
        let downloadItem: ChromeDownloadItem
        do {
            guard let fetchedDownloadItem = try await fetchChromeDownload(withID: downloadID) else {
                return .finished("there's no download with id \(downloadID). call chrome_list_downloads for the current ids.")
            }
            downloadItem = fetchedDownloadItem
        } catch {
            return .finished(error.localizedDescription)
        }

        let downloadedFile = DownloadedFile(downloadItem: downloadItem)
        let homeDirectoryPath = DownloadConcierge.homeDirectoryPath
        guard FileManager.default.fileExists(atPath: downloadedFile.filePath) else {
            return .finished(DownloadConciergeError.fileIsGone.localizedDescription)
        }

        // Start from what the concierge would offer, then apply what was asked.
        let planResult = DownloadFilingPlanner.plan(
            for: downloadedFile,
            rules: DownloadConcierge.shared.loadRules(),
            homeDirectoryPath: homeDirectoryPath,
            filedAt: Date(),
            canBrainRead: { _ in false }
        )
        let plan: DownloadFilingPlan
        switch planResult {
        case .failure(let refusal):
            return .finished(refusal.explanation)
        case .success(let successfulPlan):
            plan = successfulPlan
        }

        var destinationFolderPath = plan.destinationFolderPath
        if case .string(let requestedFolder)? = arguments["folder"], !requestedFolder.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let expandedFolderPath = DownloadFilingSafety.expandedFolderPath(requestedFolder, homeDirectoryPath: homeDirectoryPath) else {
                return .finished("give the folder as a full path or one starting with ~/, e.g. ~/Documents/Papers.")
            }
            destinationFolderPath = expandedFolderPath
        }
        if let destinationRefusal = DownloadFilingSafety.destinationRefusal(
            destinationFolderPath: URL(fileURLWithPath: destinationFolderPath).resolvingSymlinksInPath().path,
            homeDirectoryPath: homeDirectoryPath
        ) {
            return .finished(destinationRefusal.explanation)
        }

        var baseName = plan.suggestedBaseName
        if case .string(let requestedName)? = arguments["new_name"], !requestedName.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let requestedBaseName = DownloadFilingPlanner.requestedBaseName(requestedName, originalFileExtension: downloadedFile.fileExtension) else {
                return .finished("that name has nothing usable in it.")
            }
            baseName = requestedBaseName
        }

        guard let destinationFilePath = DownloadConcierge.shared.destinationPath(
            forFileAtPath: downloadedFile.filePath,
            intoFolderPath: destinationFolderPath,
            baseName: baseName,
            fileExtension: downloadedFile.fileExtension
        ) else {
            return .finished(DownloadFilingRefusal.noFreeName.explanation)
        }
        guard destinationFilePath != URL(fileURLWithPath: downloadedFile.filePath).resolvingSymlinksInPath().path else {
            return .finished("\(downloadedFile.fileName) already has that name and folder.")
        }
        return .ready(.object([
            "download_id": .number(Double(downloadID)),
            "from": .string(DownloadFilingSafety.abbreviatedPath(downloadedFile.filePath, homeDirectoryPath: homeDirectoryPath)),
            "to": .string(destinationFilePath)
        ]))
    }

    private static func integerArgument(_ rawValue: JSONValue?) -> Int? {
        switch rawValue {
        case .number(let numericValue)?: return Int(exactly: numericValue)
        case .string(let textValue)?: return Int(textValue.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Fails with the plain-words reason when the extension isn't there or
    /// downloads aren't allowed, so the model can pass it on.
    private static func requireChromeDownloadsAccess() throws {
        let chromeExtensionBridge = ChromeExtensionBridge.shared
        guard chromeExtensionBridge.isExtensionConnected else {
            throw DownloadToolError.extensionNotConnected
        }
        guard chromeExtensionBridge.hasCapability(.downloads) else {
            throw DownloadToolError.downloadsNotAllowed
        }
    }

    private static func fetchRecentChromeDownloads(limit: Int) async throws -> [ChromeDownloadItem] {
        try requireChromeDownloadsAccess()
        let listResult = try await ChromeExtensionBridge.shared.sendRequest(
            method: "getDownloads",
            parameters: ["limit": limit],
            resultType: ChromeDownloadsListResult.self
        )
        return listResult.downloads
    }

    private static func fetchChromeDownload(withID downloadID: Int) async throws -> ChromeDownloadItem? {
        try requireChromeDownloadsAccess()
        let listResult = try await ChromeExtensionBridge.shared.sendRequest(
            method: "getDownloads",
            parameters: ["downloadId": downloadID],
            resultType: ChromeDownloadsListResult.self
        )
        return listResult.downloads.first { $0.id == downloadID }
    }
}

enum DownloadToolError: LocalizedError {
    case extensionNotConnected
    case downloadsNotAllowed

    var errorDescription: String? {
        switch self {
        case .extensionNotConnected:
            return "the wisp tabs chrome extension isn't connected. load it from chrome://extensions (settings → agent → chrome tabs says how)."
        case .downloadsNotAllowed:
            return "wisp can't see downloads yet. in settings → agent → chrome tabs, choose what wisp can do in chrome, then allow downloads."
        }
    }
}
