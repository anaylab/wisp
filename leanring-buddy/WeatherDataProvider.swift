//
//  WeatherDataProvider.swift
//  leanring-buddy
//
//  Fetches live weather for a place name and maps it into a `WeatherSnapshot`
//  for the weather glance card. Uses **Open-Meteo** — free, HTTPS, and **no API
//  key** — in two steps: geocode the name to a coordinate, then pull the
//  forecast. This is the one place a card reaches off the machine; it is gated
//  by `GlanceCardDataPreference` (the caller passes the flag in) and labelled at
//  the card, per the local-first posture.
//
//  An `actor` so the fetch and JSON decode run off the main actor and a small
//  result cache is race-free. It is cancellation-aware by virtue of async
//  URLSession — the caller cancels the previous fetch when a new turn replaces
//  the card.
//

import Foundation

/// Marker for a source that resolves a card request into rendered data. Each
/// data-sourced card kind has one; weather is the first.
protocol GlanceCardDataProvider: Sendable {}

actor WeatherDataProvider: GlanceCardDataProvider {
    static let shared = WeatherDataProvider()

    enum WeatherDataError: Error, Equatable {
        /// Live card data is turned off in settings.
        case liveCardDataDisabled
        /// The place name did not resolve to a location.
        case locationNotFound(String)
        /// The service returned a non-success response or unreadable body.
        case badResponse
    }

    private struct CachedSnapshot {
        let snapshot: WeatherSnapshot
        let fetchedAt: Date
    }

    /// Recent snapshots keyed by normalised place name, so repeated asks for the
    /// same place within a few minutes do not re-hit the network.
    private var cachedSnapshotsByLocationKey: [String: CachedSnapshot] = [:]
    private let cacheLifetime: TimeInterval = 600

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Resolves a place name to a live weather snapshot.
    ///
    /// - Parameters:
    ///   - locationName: the place the model asked about.
    ///   - isLiveCardDataEnabled: the gate value, read from
    ///     `GlanceCardDataPreference` by the caller on the main actor and passed
    ///     in so this actor never has to reach into main-actor state.
    ///   - now: injectable clock, so the cache and the "hours ahead" selection
    ///     are testable.
    func snapshot(
        forLocationName locationName: String,
        isLiveCardDataEnabled: Bool,
        now: Date = Date()
    ) async throws -> WeatherSnapshot {
        guard isLiveCardDataEnabled else {
            throw WeatherDataError.liveCardDataDisabled
        }

        let locationKey = locationName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = cachedSnapshotsByLocationKey[locationKey],
           now.timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.snapshot
        }

        let place = try await geocode(locationName: locationName)
        let forecastJSON = try await fetchForecastJSON(latitude: place.latitude, longitude: place.longitude)
        let snapshot = try WeatherSnapshot.make(
            fromForecastJSON: forecastJSON,
            placeName: place.displayName,
            now: now
        )

        cachedSnapshotsByLocationKey[locationKey] = CachedSnapshot(snapshot: snapshot, fetchedAt: now)
        return snapshot
    }

    // MARK: - Open-Meteo requests

    private struct GeocodedPlace {
        let displayName: String
        let latitude: Double
        let longitude: Double
    }

    private func geocode(locationName: String) async throws -> GeocodedPlace {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: locationName),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { throw WeatherDataError.badResponse }

        let (data, response) = try await urlSession.data(from: url)
        try ensureSuccessful(response)

        let decoded = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        guard let firstResult = decoded.results?.first else {
            throw WeatherDataError.locationNotFound(locationName)
        }
        return GeocodedPlace(
            displayName: firstResult.name,
            latitude: firstResult.latitude,
            longitude: firstResult.longitude
        )
    }

    private func fetchForecastJSON(latitude: Double, longitude: Double) async throws -> Data {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]
        guard let url = components?.url else { throw WeatherDataError.badResponse }

        let (data, response) = try await urlSession.data(from: url)
        try ensureSuccessful(response)
        return data
    }

    private func ensureSuccessful(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw WeatherDataError.badResponse
        }
    }

    private struct GeocodingResponse: Decodable {
        let results: [GeocodedResult]?

        struct GeocodedResult: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
        }
    }
}
