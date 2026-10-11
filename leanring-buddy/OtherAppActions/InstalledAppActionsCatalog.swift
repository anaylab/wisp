//
//  InstalledAppActionsCatalog.swift
//  leanring-buddy
//
//  What the installed apps can do through Shortcuts, read from each app's App
//  Intents metadata (`Contents/Resources/Metadata.appintents/extract.actionsdata`)
//  and parsed by `AppIntentsMetadataParser`. Titles are looked up in the app's
//  own localized strings, as Shortcuts shows them.
//
//  Scanning ~100 app bundles takes a moment, so it runs off the main actor in
//  the background — at launch and when the cache is ten minutes old — and a
//  request arriving before the first scan finishes simply isn't matched (it
//  goes to the model as before). Nothing here launches or talks to the apps.
//

import Foundation

@MainActor
final class InstalledAppActionsCatalog {
    static let shared = InstalledAppActionsCatalog()

    private(set) var installedApplications: [InstalledApplicationActions] = []
    private var lastScanDate: Date?
    private var scanTask: Task<Void, Never>?

    private static let rescanIntervalSeconds: TimeInterval = 10 * 60

    /// Apps Wisp already does things in itself, so a request naming them is
    /// left to their own routes and tools rather than turned into a shortcut
    /// suggestion.
    static let applicationsHandledNatively: Set<String> = [
        "com.apple.iCal",          // Calendar — the calendar fast path and tool
        "com.apple.reminders",     // Reminders — the reminders fast path and tool
        "com.apple.MobileSMS",     // Messages — send_imessage
        "com.apple.Safari",        // browser control
        "com.google.Chrome",       // browser control and tab organizing
        "com.apple.shortcuts",     // the Shortcuts app itself
    ]

    func scanInBackgroundIfStale() {
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < Self.rescanIntervalSeconds { return }
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            let scannedApplications = await Task.detached(priority: .utility) {
                Self.scanInstalledApplications()
            }.value
            guard let self else { return }
            self.installedApplications = scannedApplications
            self.lastScanDate = Date()
            self.scanTask = nil
            print("🧩 App actions: \(scannedApplications.count) apps offer \(scannedApplications.reduce(0) { $0 + $1.actions.count }) actions to Shortcuts")
        }
    }

    /// The apps a shortcut suggestion may name: not Wisp itself, not apps it
    /// handles natively, and not apps an installed tool already covers (a
    /// Notion MCP server, say) — the model can use that tool directly.
    func applicationsForSuggestions(excludingAppsCoveredByToolNames installedToolNames: Set<String>) -> [InstalledApplicationActions] {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let compactToolNames = installedToolNames.map { $0.lowercased().filter(\.isLetter) }
        return installedApplications.filter { application in
            guard application.bundleIdentifier != ownBundleIdentifier,
                  !Self.applicationsHandledNatively.contains(application.bundleIdentifier) else { return false }
            let compactApplicationName = AppActionRequestMatcher.shortName(of: application.applicationName).lowercased().filter(\.isLetter)
            guard compactApplicationName.count >= 3 else { return true }
            return !compactToolNames.contains { $0.contains(compactApplicationName) }
        }
    }

    // MARK: - Scanning

    nonisolated private static var applicationFolderURLs: [URL] {
        let homeApplicationsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            homeApplicationsURL,
        ]
    }

    nonisolated static func scanInstalledApplications() -> [InstalledApplicationActions] {
        var applicationsByBundleIdentifier: [String: InstalledApplicationActions] = [:]
        for applicationFolderURL in applicationFolderURLs {
            let folderContents = (try? FileManager.default.contentsOfDirectory(
                at: applicationFolderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for applicationURL in folderContents where applicationURL.pathExtension == "app" {
                guard let applicationActions = applicationActions(at: applicationURL),
                      applicationsByBundleIdentifier[applicationActions.bundleIdentifier] == nil else { continue }
                applicationsByBundleIdentifier[applicationActions.bundleIdentifier] = applicationActions
            }
        }
        return applicationsByBundleIdentifier.values.sorted { $0.applicationName < $1.applicationName }
    }

    nonisolated private static func applicationActions(at applicationURL: URL) -> InstalledApplicationActions? {
        let metadataURL = applicationURL.appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata")
        guard let actionsData = try? Data(contentsOf: metadataURL),
              let applicationBundle = Bundle(url: applicationURL),
              let bundleIdentifier = applicationBundle.bundleIdentifier else { return nil }

        let actions = AppIntentsMetadataParser.actions(fromActionsData: actionsData) { stringKey in
            localizedString(forKey: stringKey, in: applicationBundle)
        }
        guard !actions.isEmpty else { return nil }

        let applicationName = (applicationBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (applicationBundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
        return InstalledApplicationActions(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            applicationPath: applicationURL.path,
            actions: actions
        )
    }

    /// App Intents strings live in the default table for most apps, and in
    /// a table of their own for some; the first table that knows the key wins.
    nonisolated private static func localizedString(forKey stringKey: String, in applicationBundle: Bundle) -> String? {
        let missingMarker = "\u{1}"
        for tableName in [nil, "AppIntents", "AppShortcuts", "Localizable", "AssistantIntents"] as [String?] {
            let localizedValue = applicationBundle.localizedString(forKey: stringKey, value: missingMarker, table: tableName)
            if localizedValue != missingMarker && localizedValue != stringKey { return localizedValue }
        }
        return nil
    }
}
