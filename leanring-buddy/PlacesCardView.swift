//
//  PlacesCardView.swift
//  leanring-buddy
//
//  The places-nearby glance card, drawn on the notch's dark palette (DS.*) in a
//  Maps-like results list: each nearby place as a category glyph, its name, a
//  short category/street subtitle, and the distance from the user. It is fed a
//  `PlacesSnapshot` that Wisp resolves on-device from the user's location and
//  Apple Maps (`PlacesDataProvider`), so nothing here comes from the model.
//
//  Each row is tappable and opens that place in Apple Maps, so the card is a
//  jumping-off point the way Maps search results are. Rows show a pointer cursor
//  and a hover highlight, per the project's interaction conventions.
//
//  Four states, so the card can appear the instant a turn asks for it: loading,
//  loaded (which handles the empty "nothing nearby" case), failed, and
//  access-denied (a clear prompt to grant Location access rather than a
//  misleading empty list).
//

import MapKit
import SwiftUI

/// What the places card is showing right now. The query is carried through
/// loading and failure so the card always has a title.
enum PlacesCardState: Equatable {
    case loading(query: String)
    case failed(query: String)
    case accessDenied
    case loaded(PlacesSnapshot)
}

struct PlacesCardView: View {
    let state: PlacesCardState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            attribution
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
        }
    }

    /// "Coffee nearby" for a query, "Nearby" as a neutral fallback.
    private var headerTitle: String {
        switch state {
        case let .loading(query), let .failed(query):
            return "\(capitalizedFirst(query)) nearby"
        case .accessDenied:
            return "Nearby"
        case let .loaded(snapshot):
            return "\(capitalizedFirst(snapshot.query)) nearby"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            placeholder("Finding places near you…")
        case .failed:
            placeholder("No places found nearby.")
        case .accessDenied:
            placeholder("Grant Location access in System Settings to find places nearby.")
        case let .loaded(snapshot):
            if snapshot.items.isEmpty {
                placeholder("Nothing nearby.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.items) { placeItem in
                        PlaceRow(placeItem: placeItem)
                    }
                }
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Network-backed (MapKit's search hits Apple's servers), so it is labelled
    /// "Live" and credited to Apple Maps, matching the weather card's posture.
    private var attribution: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(DS.Colors.accentText)
                .frame(width: 5, height: 5)
            Text("Live · Apple Maps")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    /// Capitalizes only the first character so a multi-word query like "thai
    /// food" becomes "Thai food" rather than title-casing every word.
    private func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

// MARK: - Row

/// One place in the list. A button that opens the place in Apple Maps, with a
/// pointer cursor and a hover highlight so its clickability reads.
private struct PlaceRow: View {
    let placeItem: PlaceGlanceItem

    @State private var isHovered = false

    var body: some View {
        Button(action: openInMaps) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: categorySymbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(placeItem.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let distanceText {
                    Text(distanceText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isHovered ? DS.Colors.surface3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    /// Category then street, joined by a dot when both exist.
    private var subtitleText: String? {
        let parts = [placeItem.category, placeItem.streetAddress].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A short, locale-aware distance like "250 m" or "0.3 mi", or nil when the
    /// distance was not known.
    private var distanceText: String? {
        guard let distanceMeters = placeItem.distanceMeters else { return nil }
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        return formatter.string(fromDistance: distanceMeters)
    }

    /// A leading glyph keyed to a few common categories, falling back to a map
    /// pin. Matches on a lowercased contains so both "Cafe" and "Restaurant"
    /// resolve without an exhaustive table.
    private var categorySymbolName: String {
        guard let category = placeItem.category?.lowercased() else { return "mappin.circle.fill" }
        if category.contains("cafe") || category.contains("coffee") {
            return "cup.and.saucer.fill"
        }
        if category.contains("restaurant") || category.contains("food") || category.contains("bakery") {
            return "fork.knife"
        }
        if category.contains("bar") || category.contains("brewery") || category.contains("winery") {
            return "wineglass.fill"
        }
        if category.contains("pharmacy") || category.contains("hospital") {
            return "cross.fill"
        }
        if category.contains("store") || category.contains("market") || category.contains("shop") {
            return "bag.fill"
        }
        if category.contains("gas") || category.contains("ev") || category.contains("charging") {
            return "fuelpump.fill"
        }
        if category.contains("park") {
            return "tree.fill"
        }
        return "mappin.circle.fill"
    }

    /// Opens this place in Apple Maps by rebuilding a map item from the stored
    /// coordinate — the snapshot deliberately holds no `MKMapItem` so it can stay
    /// Sendable across the provider actor.
    private func openInMaps() {
        let location = CLLocation(
            latitude: placeItem.latitude,
            longitude: placeItem.longitude
        )
        let mapItem = MKMapItem(location: location, address: nil)
        mapItem.name = placeItem.name
        mapItem.openInMaps()
    }
}

// MARK: - Previews

#Preview("Loaded") {
    PlacesCardView(state: .loaded(.previewSample))
        .padding()
        .frame(width: 320)
        .background(Color.black)
}

#Preview("Loading") {
    PlacesCardView(state: .loading(query: "coffee"))
        .padding()
        .frame(width: 320)
        .background(Color.black)
}

#Preview("Access denied") {
    PlacesCardView(state: .accessDenied)
        .padding()
        .frame(width: 320)
        .background(Color.black)
}
