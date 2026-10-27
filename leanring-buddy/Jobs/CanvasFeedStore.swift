//
//  CanvasFeedStore.swift
//  leanring-buddy
//
//  Validates the pasted Canvas feed URL, fetches it, and keeps the last
//  snapshot on disk. The fetch is the one off-machine read this job makes: a
//  plain https GET to the user's own school server, no cookies, no custom
//  headers, no redirect off https. The URL is a secret, so no error produced
//  here ever contains it.
//

import Foundation

// MARK: - Validation

nonisolated enum CanvasFeedURLValidationError: Error, Equatable, Sendable, LocalizedError {
    case empty, notAURL, notHTTPS, missingHost, containsCredentials, couldNotSaveToKeychain

    // Never includes the input: it may be a secret feed URL.
    var errorDescription: String? {
        switch self {
        case .empty: return "Paste your Canvas calendar feed link."
        case .notAURL: return "That doesn't look like a link."
        case .notHTTPS: return "The Canvas feed link must be a secure https link."
        case .missingHost: return "That link has no website address."
        case .containsCredentials: return "That link contains a username or password, which Wisp won't use."
        case .couldNotSaveToKeychain: return "Wisp couldn't save the link to your Keychain. Your previous link, if any, is unchanged."
        }
    }
}

nonisolated enum CanvasFeedURLValidator {
    /// Trims, rewrites webcal:// to https://, and requires https, a host and no userinfo.
    /// The path is deliberately not checked: Canvas feed paths differ per school.
    static func validate(_ rawText: String) -> Result<URL, CanvasFeedURLValidationError> {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        // A pasted link never legitimately contains whitespace inside.
        guard !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return .failure(.notAURL) }

        let lowercasedText = text.lowercased()
        if lowercasedText.hasPrefix("webcals://") {
            text = "https://" + text.dropFirst("webcals://".count)
        } else if lowercasedText.hasPrefix("webcal://") {
            text = "https://" + text.dropFirst("webcal://".count)
        }

        // Without "scheme://" a bare host or "javascript:..." is not a feed link.
        guard text.contains("://"),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased() else { return .failure(.notAURL) }
        guard scheme == "https" else { return .failure(.notHTTPS) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        guard components.user == nil, components.password == nil else { return .failure(.containsCredentials) }
        guard let url = components.url else { return .failure(.notAURL) }
        return .success(url)
    }

    /// "yourschool.instructure.com/…": the host only, never the path or token.
    static func maskedDisplay(for url: URL) -> String {
        (url.host ?? "your school") + "/…"
    }
}

// MARK: - Fetch

nonisolated enum CanvasFeedFetchError: Error, Equatable, Sendable, LocalizedError {
    case noFeedConfigured, offline, httpStatus(Int), notICS, tooLarge, timedOut

    // Never contains the URL.
    var errorDescription: String? {
        switch self {
        case .noFeedConfigured: return "No Canvas feed is set up."
        case .offline: return "Couldn't reach your Canvas feed. Check your connection."
        case .httpStatus(let code): return "Your Canvas feed answered with an error (\(code))."
        case .notICS: return "Your Canvas feed didn't return a calendar. The link may have been reset."
        case .tooLarge: return "Your Canvas feed is larger than Wisp will download."
        case .timedOut: return "Your Canvas feed took too long to answer."
        }
    }
}

/// Refuses any redirect that leaves https, so the token is never sent in the clear.
private nonisolated final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

actor CanvasFeedStore {
    static let shared = CanvasFeedStore()

    static let maximumFeedBytes = 5 * 1024 * 1024
    static let requestTimeoutSeconds: TimeInterval = 20

    private let feedURLProvider: @Sendable () -> URL?
    private let snapshotFileURL: URL

    init(feedURLProvider: @escaping @Sendable () -> URL? = { CanvasFeedKeychainStore.feedURL() },
         snapshotFileURL: URL = CanvasFeedStore.defaultSnapshotFileURL()) {
        self.feedURLProvider = feedURLProvider
        self.snapshotFileURL = snapshotFileURL
    }

    nonisolated static func defaultSnapshotFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return supportDirectory.appendingPathComponent("Wisp/jobs-canvas-snapshot.json")
    }

    func fetchCurrentItems(now: Date, calendar: Calendar) async throws -> [CanvasItem] {
        guard let feedURL = feedURLProvider() else { throw CanvasFeedFetchError.noFeedConfigured }
        let icsText = try await downloadFeedText(from: feedURL)
        guard icsText.contains("BEGIN:VCALENDAR") else { throw CanvasFeedFetchError.notICS }
        return CanvasFeedParser.parse(icsText: icsText, now: now, calendar: calendar)
    }

    private func downloadFeedText(from feedURL: URL) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = Self.requestTimeoutSeconds
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = Self.requestTimeoutSeconds

        do {
            let (byteStream, response) = try await session.bytes(for: request, delegate: HTTPSOnlyRedirectDelegate())
            guard let httpResponse = response as? HTTPURLResponse else { throw CanvasFeedFetchError.offline }
            guard (200..<300).contains(httpResponse.statusCode) else { throw CanvasFeedFetchError.httpStatus(httpResponse.statusCode) }
            if httpResponse.expectedContentLength > Int64(Self.maximumFeedBytes) { throw CanvasFeedFetchError.tooLarge }

            var downloadedData = Data()
            for try await byte in byteStream {
                downloadedData.append(byte)
                if downloadedData.count > Self.maximumFeedBytes { throw CanvasFeedFetchError.tooLarge }
            }
            return String(data: downloadedData, encoding: .utf8) ?? String(decoding: downloadedData, as: UTF8.self)
        } catch let fetchError as CanvasFeedFetchError {
            throw fetchError
        } catch let urlError as URLError {
            // URLError text embeds the URL, so translate rather than rethrow.
            if urlError.code == .cancelled { throw CancellationError() }
            throw urlError.code == .timedOut ? CanvasFeedFetchError.timedOut : CanvasFeedFetchError.offline
        }
    }

    // MARK: - Snapshot

    func loadSnapshot() -> CanvasSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CanvasSnapshot.self, from: data)
    }

    /// Atomic, 0600: the file holds course titles and due dates.
    func saveSnapshot(_ snapshot: CanvasSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)

        let fileManager = FileManager.default
        let directory = snapshotFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Create the temp file already 0600 so it is never briefly world-readable.
        let temporaryFileURL = directory.appendingPathComponent(".jobs-canvas-snapshot-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryFileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fileManager.fileExists(atPath: snapshotFileURL.path) {
            _ = try fileManager.replaceItemAt(snapshotFileURL, withItemAt: temporaryFileURL)
        } else {
            try fileManager.moveItem(at: temporaryFileURL, to: snapshotFileURL)
        }
    }

    func clearSnapshot() {
        try? FileManager.default.removeItem(at: snapshotFileURL)
    }
}
