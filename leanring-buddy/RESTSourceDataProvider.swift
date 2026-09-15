//
//  RESTSourceDataProvider.swift
//  leanring-buddy
//
//  Fetches a user-configured source (`ConfiguredSource`) over HTTPS and maps the
//  JSON response into generic glance-card blocks using the source's field
//  mapping. This is the "connect to any API" path: the model only names a
//  source, and Wisp turns the fetched values into the existing generic card so
//  no new template is needed per source.
//
//  Like weather, this reaches off the machine, so it is gated by
//  `GlanceCardDataPreference` (the caller passes the flag in) and the card is
//  labelled "Live · <source>". Only HTTPS URLs are allowed. An `actor` so the
//  fetch and decode run off the main actor.
//

import Foundation

actor RESTSourceDataProvider: GlanceCardDataProvider {
    static let shared = RESTSourceDataProvider()

    enum RESTSourceError: Error, Equatable {
        case liveCardDataDisabled
        /// The configured URL was missing, malformed, or not HTTPS.
        case invalidURL
        case badResponse
        /// None of the configured fields could be read from the response.
        case noReadableFields
    }

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Fetches the source and returns a generic card built from its fields.
    ///
    /// - Parameters:
    ///   - source: the resolved configuration (URL, headers, field mapping).
    ///   - isLiveCardDataEnabled: the network gate, read on the main actor and
    ///     passed in so this actor never reaches into main-actor state.
    func card(
        for source: ConfiguredSource,
        isLiveCardDataEnabled: Bool
    ) async throws -> GlanceCard {
        guard isLiveCardDataEnabled else {
            throw RESTSourceError.liveCardDataDisabled
        }

        // HTTPS only — never fetch a user card over plaintext.
        guard let url = URL(string: source.url),
              url.scheme?.lowercased() == "https" else {
            throw RESTSourceError.invalidURL
        }

        var request = URLRequest(url: url)
        for (headerName, headerValue) in source.headers ?? [:] {
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw RESTSourceError.badResponse
        }

        let jsonObject = try JSONSerialization.jsonObject(with: data)

        // Resolve each configured field's path against the response. A field
        // that doesn't resolve is skipped rather than failing the whole card.
        let pairs: [GlanceKeyValuePair] = source.fields.compactMap { field in
            guard let rawValue = Self.value(atDotPath: field.path, in: jsonObject) else {
                return nil
            }
            return GlanceKeyValuePair(
                key: field.label,
                value: Self.displayString(for: rawValue),
                tone: GlanceTone(rawValue: field.tone ?? "") ?? .neutral
            )
        }

        guard !pairs.isEmpty else {
            throw RESTSourceError.noReadableFields
        }

        return GlanceCard(blocks: [
            .header(title: source.name, iconName: "antenna.radiowaves.left.and.right", trailingText: nil),
            .keyValue(pairs: pairs),
        ])
    }

    // MARK: - JSON path resolution

    /// Walks a dot-separated path (`a.b.0.c`) into a decoded JSON object,
    /// stepping into dictionaries by key and arrays by integer index. Returns
    /// the leaf value, or nil if any segment does not resolve.
    nonisolated static func value(atDotPath path: String, in root: Any) -> Any? {
        let segments = path.split(separator: ".").map(String.init)
        var current: Any? = root
        for segment in segments {
            if let dictionary = current as? [String: Any] {
                current = dictionary[segment]
            } else if let array = current as? [Any], let index = Int(segment), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
            if current == nil { return nil }
        }
        return current
    }

    /// Renders a JSON leaf as a compact display string. Whole-number doubles
    /// lose their ".0"; booleans read as Yes/No; everything else is described.
    nonisolated static func displayString(for value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let boolean as Bool:
            return boolean ? "Yes" : "No"
        case let number as NSNumber:
            // NSNumber covers Int/Double/Bool from JSONSerialization; the Bool
            // case above already handled true/false literals.
            if number.doubleValue == number.doubleValue.rounded() {
                return String(number.intValue)
            }
            return String(number.doubleValue)
        default:
            return String(describing: value)
        }
    }
}
