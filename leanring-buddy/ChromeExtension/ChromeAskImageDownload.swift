//
//  ChromeAskImageDownload.swift
//  leanring-buddy
//
//  "Ask Wisp about this image" (phase 06): Wisp downloads the image itself,
//  so the model sees its real pixels rather than a downscaled screenshot of
//  them.
//
//  The download follows the Canvas feed's rules (`CanvasFeedStore`): a plain
//  https GET, no cookies sent or kept, no cache, no redirect off https, and a
//  size cap (10 MB) enforced while the bytes arrive, not trusted from the
//  headers. The page the image is on decided its address, so it is treated as
//  untrusted: a data: or http: address, one with a username in it, or one the
//  extension had to cut short is refused, and the turn falls back to the
//  screenshot. It is one user-asked fetch of an address Chrome already loaded,
//  the same kind of network use as the brain fetching a page the user named.
//
//  The rules are pure; the fetch is Foundation only, so
//  `Tests/ChromeExtAskAboutThis` compiles this file whole.
//

import Foundation

nonisolated enum ChromeAskImageDownloadError: Error, Equatable, Sendable, LocalizedError {
    case notHTTPS, missingHost, containsCredentials, addressCutOff
    case httpStatus(Int), notAnImage, tooLarge, timedOut, offline

    // Never includes the address: it came from a page.
    var errorDescription: String? {
        switch self {
        case .notHTTPS: return "the image isn't at a secure https address"
        case .missingHost: return "the image's address has no website"
        case .containsCredentials: return "the image's address contains a username or password"
        case .addressCutOff: return "the image's address is too long"
        case .httpStatus(let statusCode): return "the image's website answered with an error (\(statusCode))"
        case .notAnImage: return "that address didn't return an image"
        case .tooLarge: return "the image is larger than 10 MB"
        case .timedOut: return "the image took too long to download"
        case .offline: return "the image couldn't be downloaded"
        }
    }
}

nonisolated enum ChromeAskImageDownloadRules {
    static let maximumImageBytes = 10 * 1024 * 1024
    static let requestTimeoutSeconds: TimeInterval = 15

    /// The address to download, or why not. `wasCutOff` is the event's
    /// `truncated`: a cut address would fetch something else.
    static func validatedImageURL(_ imageURLText: String, wasCutOff: Bool) -> Result<URL, ChromeAskImageDownloadError> {
        guard !wasCutOff else { return .failure(.addressCutOff) }
        let trimmedText = imageURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedText),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" else { return .failure(.notHTTPS) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        guard components.user == nil, components.password == nil else { return .failure(.containsCredentials) }
        guard let url = components.url else { return .failure(.notHTTPS) }
        return .success(url)
    }

    /// Checks a response before its body is read: a success status, an image
    /// type, and a declared size within the cap (-1 = not declared).
    static func problem(withStatusCode statusCode: Int, mimeType: String?, expectedContentLength: Int64) -> ChromeAskImageDownloadError? {
        guard (200..<300).contains(statusCode) else { return .httpStatus(statusCode) }
        guard let mimeType, mimeType.lowercased().hasPrefix("image/") else { return .notAnImage }
        if expectedContentLength > Int64(maximumImageBytes) { return .tooLarge }
        return nil
    }

    /// Whether a redirect may be followed: only to another https address.
    static func allowsRedirect(to redirectURL: URL?) -> Bool {
        redirectURL?.scheme?.lowercased() == "https"
    }
}

/// Refuses any redirect that leaves https.
private nonisolated final class ChromeAskImageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(ChromeAskImageDownloadRules.allowsRedirect(to: request.url) ? request : nil)
    }
}

nonisolated enum ChromeAskImageDownloader {

    /// The image's bytes, as served.
    static func download(_ imageURL: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = ChromeAskImageDownloadRules.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = ChromeAskImageDownloadRules.requestTimeoutSeconds
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: imageURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = ChromeAskImageDownloadRules.requestTimeoutSeconds

        do {
            let (byteStream, response) = try await session.bytes(for: request, delegate: ChromeAskImageRedirectDelegate())
            guard let httpResponse = response as? HTTPURLResponse else { throw ChromeAskImageDownloadError.offline }
            if let responseProblem = ChromeAskImageDownloadRules.problem(
                withStatusCode: httpResponse.statusCode,
                mimeType: httpResponse.mimeType,
                expectedContentLength: httpResponse.expectedContentLength
            ) {
                throw responseProblem
            }

            var downloadedData = Data()
            if httpResponse.expectedContentLength > 0 {
                downloadedData.reserveCapacity(Int(httpResponse.expectedContentLength))
            }
            for try await byte in byteStream {
                downloadedData.append(byte)
                if downloadedData.count > ChromeAskImageDownloadRules.maximumImageBytes {
                    throw ChromeAskImageDownloadError.tooLarge
                }
            }
            return downloadedData
        } catch let downloadError as ChromeAskImageDownloadError {
            throw downloadError
        } catch let urlError as URLError {
            // URLError's text embeds the address, so translate rather than rethrow.
            if urlError.code == .cancelled { throw CancellationError() }
            if urlError.code == .timedOut { throw ChromeAskImageDownloadError.timedOut }
            throw ChromeAskImageDownloadError.offline
        }
    }
}
