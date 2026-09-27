//
//  PlacesDataProvider.swift
//  leanring-buddy
//
//  Finds places near the user for a places-nearby glance card. Uses Apple's own
//  frameworks — CoreLocation for the user's position and MapKit's `MKLocalSearch`
//  for the results — so there is **no API key** and the data is Maps' own index,
//  the same source that makes "restaurants near me" feel native.
//
//  This reaches off the machine (MapKit's search hits Apple's servers), so it is
//  gated by `GlanceCardDataPreference` (the caller passes the flag in) and
//  labelled at the card, matching the weather card's posture. Location itself is
//  gated by the user's macOS Location permission, requested on first use.
//
//  The provider is an `actor` so the search and result mapping run off the main
//  actor; every `MKMapItem` is flattened into a Sendable `PlaceGlanceItem` before
//  it leaves this actor. The one-shot location fetch lives in the small
//  `@MainActor WispLocationProvider` below, because `CLLocationManager` wants to
//  be created and driven from the main run loop.
//

import CoreLocation
import Foundation
import MapKit

actor PlacesDataProvider: GlanceCardDataProvider {
    static let shared = PlacesDataProvider()

    enum PlacesDataError: Error, Equatable {
        /// Live card data is turned off in settings.
        case liveCardDataDisabled
        /// The user has not granted (or has denied) Location access.
        case locationAccessDenied
        /// Location could not be determined (services off, or a transient fix
        /// failure).
        case locationUnavailable
        /// The search ran but returned nothing for the query nearby.
        case noResults(String)
        /// The search itself failed.
        case searchFailed
    }

    /// The most results a card shows — past a handful the notch stops being a
    /// glance.
    private let maximumResults = 5

    /// The search box drawn around the user; wide enough to catch nearby options
    /// without pulling in a whole metro area.
    private let searchRadiusMeters: CLLocationDistance = 4000

    /// Resolves a query into nearby places.
    ///
    /// - Parameters:
    ///   - query: what the user is looking for ("coffee", "ramen", …).
    ///   - isLiveCardDataEnabled: the gate value, read from
    ///     `GlanceCardDataPreference` by the caller on the main actor and passed
    ///     in so this actor never reaches into main-actor state.
    ///   - now: injectable clock for the snapshot's timestamp.
    func snapshot(
        forQuery query: String,
        isLiveCardDataEnabled: Bool,
        now: Date = Date()
    ) async throws -> PlacesSnapshot {
        guard isLiveCardDataEnabled else {
            throw PlacesDataError.liveCardDataDisabled
        }

        let userLocation: CLLocation
        do {
            userLocation = try await WispLocationProvider.shared.requestCurrentLocation()
        } catch WispLocationProvider.LocationError.accessDenied {
            throw PlacesDataError.locationAccessDenied
        } catch {
            throw PlacesDataError.locationUnavailable
        }

        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = query
        searchRequest.region = MKCoordinateRegion(
            center: userLocation.coordinate,
            latitudinalMeters: searchRadiusMeters,
            longitudinalMeters: searchRadiusMeters
        )

        let searchResponse: MKLocalSearch.Response
        do {
            searchResponse = try await MKLocalSearch(request: searchRequest).start()
        } catch {
            throw PlacesDataError.searchFailed
        }

        let nearestFirstItems = searchResponse.mapItems
            .compactMap { mapItem in placeItem(from: mapItem, relativeTo: userLocation) }
            .sorted { leftItem, rightItem in
                (leftItem.distanceMeters ?? .greatestFiniteMagnitude)
                    < (rightItem.distanceMeters ?? .greatestFiniteMagnitude)
            }
            .prefix(maximumResults)

        let items = Array(nearestFirstItems)
        guard !items.isEmpty else {
            throw PlacesDataError.noResults(query)
        }

        return PlacesSnapshot(query: query, items: items, generatedAt: now)
    }

    // MARK: - Mapping

    /// Flattens one Maps result into a Sendable `PlaceGlanceItem`, or nil when it
    /// has no name to show.
    private func placeItem(from mapItem: MKMapItem, relativeTo userLocation: CLLocation) -> PlaceGlanceItem? {
        guard let name = mapItem.name else { return nil }

        let location = mapItem.location
        let coordinate = location.coordinate
        let distanceMeters = userLocation.distance(from: location)

        return PlaceGlanceItem(
            // No stable Maps identifier across OS versions, so derive one from the
            // name and coordinate — enough to distinguish rows in a short list.
            id: "\(name)@\(coordinate.latitude),\(coordinate.longitude)",
            name: name,
            category: friendlyCategoryName(mapItem.pointOfInterestCategory),
            streetAddress: mapItem.address?.shortAddress,
            distanceMeters: distanceMeters,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    /// Turns MapKit's raw point-of-interest category (e.g. `MKPOICategoryCafe`)
    /// into a short human word ("Cafe"). Returns nil when Maps did not classify
    /// the result, so the card simply omits the category.
    private func friendlyCategoryName(_ category: MKPointOfInterestCategory?) -> String? {
        guard let rawValue = category?.rawValue else { return nil }
        let prefix = "MKPOICategory"
        guard rawValue.hasPrefix(prefix) else { return rawValue }
        let stripped = String(rawValue.dropFirst(prefix.count))
        return stripped.isEmpty ? nil : stripped
    }
}

// MARK: - One-shot location

/// A small main-actor wrapper around `CLLocationManager` that vends the user's
/// current location once, `async`. `CLLocationManager` wants to be created and
/// driven on the main run loop and delivers its results through a delegate; this
/// bridges that callback world into a single awaitable call, requesting Location
/// permission on first use.
@MainActor
final class WispLocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = WispLocationProvider()

    enum LocationError: Error, Equatable {
        /// The user has denied or restricted Location access.
        case accessDenied
        /// No location could be produced (services off, or a fix failure).
        case unavailable
    }

    private let locationManager = CLLocationManager()

    /// Every awaiting caller's continuation. A single `requestLocation` result
    /// resolves all of them, so overlapping asks share one fix.
    private var pendingLocationContinuations: [CheckedContinuation<CLLocation, Error>] = []

    /// True while we have prompted for permission and are waiting for the user to
    /// decide, so the authorization-change callback knows to start the fix.
    private var isAwaitingAuthorizationDecision = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Resolves the user's current location, requesting permission if it has not
    /// been decided. Throws `accessDenied` if the user has refused, so the card
    /// can show a clear "grant access" state instead of a wrong or empty result.
    func requestCurrentLocation() async throws -> CLLocation {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            throw LocationError.accessDenied

        case .notDetermined:
            // Prompt, then wait — the fix is started from the authorization
            // callback once the user has granted access.
            return try await withCheckedThrowingContinuation { continuation in
                pendingLocationContinuations.append(continuation)
                isAwaitingAuthorizationDecision = true
                locationManager.requestWhenInUseAuthorization()
            }

        default:
            // Some authorized state — ask for a fix immediately.
            return try await withCheckedThrowingContinuation { continuation in
                pendingLocationContinuations.append(continuation)
                locationManager.requestLocation()
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard isAwaitingAuthorizationDecision else { return }

            let status = manager.authorizationStatus
            if status == .denied || status == .restricted {
                isAwaitingAuthorizationDecision = false
                failAllPending(with: LocationError.accessDenied)
            } else if status == .notDetermined {
                // Still waiting on the user; the prompt is up.
                return
            } else {
                // Authorized — now start the fix the caller is waiting for.
                isAwaitingAuthorizationDecision = false
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else {
                failAllPending(with: LocationError.unavailable)
                return
            }
            resumeAllPending(with: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            failAllPending(with: LocationError.unavailable)
        }
    }

    // MARK: Continuation bookkeeping

    private func resumeAllPending(with location: CLLocation) {
        let continuations = pendingLocationContinuations
        pendingLocationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: location)
        }
    }

    private func failAllPending(with error: Error) {
        let continuations = pendingLocationContinuations
        pendingLocationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
