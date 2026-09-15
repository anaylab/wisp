//
//  GlanceCardDataPreference.swift
//  leanring-buddy
//
//  The single gate for card data providers. Some glance cards (weather) render
//  live data fetched over the network — the one place this otherwise local-first
//  app reaches off the machine for a card. This preference lets the user turn
//  that off, returning the card system to fully local (the generic block card
//  never touches the network regardless).
//
//  Modeled on the app's other UserDefaults-backed stores (e.g.
//  `BuddyChatProviderSelection`): a `@Published` source of truth that persists.
//

import Combine
import Foundation

@MainActor
final class GlanceCardDataPreference: ObservableObject {
    static let shared = GlanceCardDataPreference()

    private static let liveCardDataEnabledKey = "wisp.glanceCard.liveDataEnabled"

    /// Whether card data providers may fetch live data over the network.
    /// Defaults to on — the feature is useful out of the box — but the whole of
    /// it can be disabled here to keep every card fully local.
    @Published var isLiveCardDataEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isLiveCardDataEnabled, forKey: Self.liveCardDataEnabledKey)
        }
    }

    private init() {
        // Absent defaults to enabled, so a fresh install gets live cards.
        if UserDefaults.standard.object(forKey: Self.liveCardDataEnabledKey) == nil {
            isLiveCardDataEnabled = true
        } else {
            isLiveCardDataEnabled = UserDefaults.standard.bool(forKey: Self.liveCardDataEnabledKey)
        }
    }
}
