//
//  PlacesSnapshot.swift
//  leanring-buddy
//
//  The resolved data behind a places-nearby glance card — everything the
//  Maps-style template needs to draw, and nothing the model has to produce. The
//  model only names what the user is looking for (see `PlacesCardRequest`); Wisp
//  resolves the user's location on-device and searches Apple Maps through
//  `PlacesDataProvider`, mapping each result into one of these.
//
//  Coordinates are carried as plain doubles rather than a `CLLocationCoordinate2D`
//  so the snapshot stays `Equatable`/`Sendable` and can cross the provider actor
//  boundary; the card view rebuilds an `MKMapItem` from them to open a result in
//  Maps on tap.
//

import Foundation

/// One place in the results list. `distanceMeters` is the straight-line distance
/// from the user when their location was known, left nil otherwise so the card
/// simply omits the distance rather than showing a wrong one.
struct PlaceGlanceItem: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// A short category word for the leading glyph and subtitle, e.g. "Coffee",
    /// "Restaurant". Nil when Maps did not classify the result.
    let category: String?
    /// A short street line for the result, when available.
    let streetAddress: String?
    let distanceMeters: Double?
    let latitude: Double
    let longitude: Double
}

/// Everything a places card renders: the query it answered, the ordered results
/// (nearest first), and when it was generated.
struct PlacesSnapshot: Equatable, Sendable {
    let query: String
    let items: [PlaceGlanceItem]
    let generatedAt: Date
}

extension PlacesSnapshot {
    /// A fixed sample for SwiftUI previews so the card can be designed without a
    /// live location or network.
    static let previewSample = PlacesSnapshot(
        query: "coffee",
        items: [
            PlaceGlanceItem(
                id: "1",
                name: "Blue Bottle Coffee",
                category: "Coffee",
                streetAddress: "66 Mint St",
                distanceMeters: 240,
                latitude: 37.782,
                longitude: -122.407
            ),
            PlaceGlanceItem(
                id: "2",
                name: "Sightglass Coffee",
                category: "Coffee",
                streetAddress: "270 7th St",
                distanceMeters: 520,
                latitude: 37.777,
                longitude: -122.408
            ),
            PlaceGlanceItem(
                id: "3",
                name: "Ritual Coffee Roasters",
                category: "Coffee",
                streetAddress: "1026 Valencia St",
                distanceMeters: 1400,
                latitude: 37.756,
                longitude: -122.421
            )
        ],
        generatedAt: Date()
    )
}
