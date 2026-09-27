//
//  NotchIslandStyle.swift
//  leanring-buddy
//
//  How the notch island is drawn. The default is Apple's Dynamic Island look:
//  a solid true-black surface that on a notched Mac is indistinguishable from
//  the camera cutout, so the island reads as the notch itself growing rather
//  than a panel laid over it. Liquid Glass (the dark-tinted refracting surface
//  with a specular rim) remains available as an opt-in look.
//

import Combine
import SwiftUI

/// The surface the notch island is drawn with.
enum NotchIslandSurfaceStyle: String, CaseIterable, Identifiable {
    /// Solid black, like Apple's Dynamic Island. The default.
    case black
    /// Dark-tinted Liquid Glass with a specular rim.
    case liquidGlass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .black: return "Black"
        case .liquidGlass: return "Liquid Glass"
        }
    }
}

/// The single source of truth for the island's surface style. Modeled on
/// `WispSoundPreference`: a `@Published` value persisted across launches.
@MainActor
final class NotchIslandStylePreference: ObservableObject {
    static let shared = NotchIslandStylePreference()

    private static let surfaceStyleUserDefaultsKey = "wisp.notch.islandSurfaceStyle"

    @Published var surfaceStyle: NotchIslandSurfaceStyle {
        didSet {
            UserDefaults.standard.set(surfaceStyle.rawValue, forKey: Self.surfaceStyleUserDefaultsKey)
        }
    }

    private init() {
        // Absent or unrecognised falls back to black, the Dynamic Island look.
        let storedRawValue = UserDefaults.standard.string(forKey: Self.surfaceStyleUserDefaultsKey) ?? ""
        surfaceStyle = NotchIslandSurfaceStyle(rawValue: storedRawValue) ?? .black
    }
}

extension View {
    /// The notch island's surface in the chosen style: solid black, or the
    /// dark-tinted Liquid Glass (`wispNotchGlassSurface`).
    @ViewBuilder
    func wispNotchIslandSurface<IslandShape: Shape>(
        in islandShape: IslandShape,
        style surfaceStyle: NotchIslandSurfaceStyle
    ) -> some View {
        switch surfaceStyle {
        case .black:
            background(WispColor.Island.surface, in: islandShape)
        case .liquidGlass:
            wispNotchGlassSurface(in: islandShape)
        }
    }
}

/// How prominent an island button is.
enum WispIslandButtonProminence {
    /// A flat grey fill — secondary actions (Dismiss, Cancel).
    case subtle
    /// A white capsule with black text — the one primary action.
    case prominent
}

/// The island's button style: flat fills on the black surface, no hairlines,
/// with hover/pressed states and a pointer cursor.
struct WispIslandButtonStyle: ButtonStyle {
    var prominence: WispIslandButtonProminence = .subtle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(prominence == .prominent ? WispColor.Island.prominentText : WispColor.Island.textPrimary)
            .padding(.horizontal, WispSpacing.md)
            .padding(.vertical, WispSpacing.sm + 1)
            .background(Capsule(style: .continuous).fill(fill(isPressed: configuration.isPressed)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : WispMotion.quick, value: configuration.isPressed)
            .animation(reduceMotion ? nil : WispMotion.quick, value: isHovered)
            .contentShape(Capsule(style: .continuous))
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func fill(isPressed: Bool) -> Color {
        switch prominence {
        case .subtle:
            if isPressed { return WispColor.Island.controlFillPressed }
            if isHovered { return WispColor.Island.controlFillHovered }
            return WispColor.Island.controlFill
        case .prominent:
            if isPressed { return WispColor.Island.prominentFill.opacity(0.78) }
            if isHovered { return WispColor.Island.prominentFill.opacity(0.9) }
            return WispColor.Island.prominentFill
        }
    }
}

extension View {
    func wispIslandButtonStyle(prominence: WispIslandButtonProminence = .subtle) -> some View {
        buttonStyle(WispIslandButtonStyle(prominence: prominence))
    }
}
