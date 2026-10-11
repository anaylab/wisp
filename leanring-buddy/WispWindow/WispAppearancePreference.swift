//
//  WispAppearancePreference.swift
//  leanring-buddy
//
//  Light, dark, or follow the Mac — for the Wisp window only. The notch, the
//  on-screen overlay and the menu bar always keep their dark glass material, so
//  this never touches them. Stored in UserDefaults; `WispWindowController`
//  applies it to the window and re-applies it whenever the choice changes.
//

import AppKit
import Combine
import Foundation

@MainActor
final class WispAppearancePreference: ObservableObject {
    static let shared = WispAppearancePreference()

    enum Mode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        /// Nil follows the system.
        var appKitAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    private static let userDefaultsKey = "WispWindowAppearance"

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.userDefaultsKey) }
    }

    private init() {
        mode = UserDefaults.standard.string(forKey: Self.userDefaultsKey).flatMap(Mode.init(rawValue:)) ?? .system
    }
}
