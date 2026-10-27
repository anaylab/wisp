//
//  CursorAppearanceStore.swift
//  leanring-buddy
//
//  The colour of the on-screen cursor companion and the annotations it draws
//  (points, boxes, highlights, arrows). One published value that the overlay
//  views observe, so picking a colour in the Cursor settings updates everything
//  live. The wisp glyph in the notch and text composer follow it too, so the
//  brand mark always matches the pointer the user chose.
//

import Combine
import Foundation
import SwiftUI

enum WispCursorColor: String, CaseIterable, Identifiable {
    case blue
    case red
    case yellow
    case green

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return Color(hex: "#3380FF")
        case .red: return Color(hex: "#FF453A")
        case .yellow: return Color(hex: "#FFD60A")
        case .green: return Color(hex: "#34C759")
        }
    }

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        }
    }
}

@MainActor
final class CursorAppearanceStore: ObservableObject {
    static let shared = CursorAppearanceStore()

    @Published var selectedColor: WispCursorColor {
        didSet {
            UserDefaults.standard.set(selectedColor.rawValue, forKey: Self.colorKey)
        }
    }

    private static let colorKey = "wisp.cursor.color"

    static let defaultColor: WispCursorColor = .blue

    private init() {
        if let rawColor = UserDefaults.standard.string(forKey: Self.colorKey),
           let storedColor = WispCursorColor(rawValue: rawColor) {
            selectedColor = storedColor
        } else {
            selectedColor = Self.defaultColor
        }
    }

    /// The current cursor colour as a SwiftUI `Color`.
    var color: Color {
        selectedColor.color
    }

    func resetToDefault() {
        selectedColor = Self.defaultColor
    }
}
