//
//  NowPlayingCardView.swift
//  leanring-buddy
//
//  The now-playing glance card, drawn on the notch's dark palette (DS.*): the
//  track title, artist, a play/pause glyph, and which app it's in. Fed a
//  `NowPlayingSnapshot` read on-device (`NowPlayingDataProvider`).
//
//  States: loading, loaded, and nothing-playing (a plain line rather than an
//  empty card, since "nothing is playing" is a real, useful answer).
//

import SwiftUI

/// What the now-playing card is showing right now.
enum NowPlayingCardState: Equatable {
    case loading
    case nothingPlaying
    case loaded(NowPlayingSnapshot)
}

struct NowPlayingCardView: View {
    let state: NowPlayingCardState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            placeholder("Checking what's playing…")
        case .nothingPlaying:
            placeholder("Nothing is playing right now.")
        case let .loaded(snapshot):
            loadedContent(snapshot)
        }
    }

    private func loadedContent(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: snapshot.isPlaying ? "play.circle.fill" : "pause.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(DS.Colors.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                if let artist = snapshot.artist {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var attribution: some View {
        if case let .loaded(snapshot) = state {
            HStack(spacing: 5) {
                Circle()
                    .fill(DS.Colors.textTertiary)
                    .frame(width: 5, height: 5)
                Text("On this Mac · \(snapshot.appName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }
}
