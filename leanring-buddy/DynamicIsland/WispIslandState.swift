//
//  WispIslandState.swift
//  leanring-buddy
//
//  The Dynamic Island's state machine. Wisp's notch surface is state-driven: it
//  quietly reflects what the companion is doing and expands into exactly the
//  surface a moment needs, then resolves back to the tiny wisp.
//
//  This is deliberately *derived* from the app's existing signals rather than
//  replacing them. The backend already tracks a `CompanionVoiceState`
//  (idle/listening/processing/responding), a pending tool confirmation, and the
//  current answer; `WispIslandState` is the richer vocabulary the UI reasons in,
//  computed from those signals plus a short-lived success/error "flash". Keeping
//  it a projection means the redesign adds no new backend state to keep in sync.
//

import SwiftUI

/// The full set of moments the Dynamic Island can portray. Only the states the
/// app has real signals for are driven today (idle, listening, thinking,
/// responding, preview, confirmation, success, error); `processing` and
/// `executing` are part of the vocabulary for future tool/agent signals.
enum WispIslandState: Equatable {
    /// At rest — the tiny wisp, almost still.
    case idle
    /// Capturing voice.
    case listening
    /// Reasoning with the model.
    case thinking
    /// Generic background work (reserved for future signals).
    case processing
    /// A finished answer lingering on the surface to be read.
    case preview
    /// Asking permission before an external/sensitive action.
    case confirmation
    /// Carrying out an approved action (reserved for future tool signals).
    case executing
    /// Speaking / rendering the reply.
    case responding
    /// A brief moment of resolution after something completed.
    case success
    /// A brief interruption when something failed or was declined.
    case error

    /// The logo motion that matches this island state.
    var markState: WispMarkState {
        switch self {
        case .idle:         return .idle
        case .listening:    return .listening
        case .thinking, .processing, .confirmation: return .thinking
        case .executing, .responding:               return .acting
        case .preview:      return .idle
        case .success:      return .success
        case .error:        return .error
        }
    }

    /// A short human label shown beside the mark.
    var label: String {
        switch self {
        case .idle:         return "Ready"
        case .listening:    return "Listening…"
        case .thinking:     return "Thinking…"
        case .processing:   return "Working…"
        case .preview:      return "Here you go"
        case .confirmation: return "Needs your ok"
        case .executing:    return "Doing it…"
        case .responding:   return "Responding…"
        case .success:      return "Done"
        case .error:        return "Didn't go through"
        }
    }

    /// The accent used for the state dot / glow on the dark glass. Most states
    /// use the sage brand accent; confirmation borrows the warning tone (a
    /// decision is pending), success/error use their semantic colours.
    var accent: Color {
        switch self {
        case .idle, .preview:
            return WispColor.OnGlass.textTertiary
        case .listening, .thinking, .processing, .executing, .responding:
            return WispColor.Brand.sage
        case .confirmation:
            return WispColor.warning
        case .success:
            return WispColor.success
        case .error:
            return WispColor.destructive
        }
    }

    /// Whether the surface should read as "lit" (active) rather than at rest.
    var isActive: Bool {
        switch self {
        case .idle, .preview: return false
        default: return true
        }
    }
}
