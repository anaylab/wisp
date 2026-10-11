//
//  ShortcutSuggestionCardView.swift
//  leanring-buddy
//
//  The notch card shown when the user asked another app for something Wisp
//  can only reach through a shortcut: the app's icon and the actions of its
//  that fit the request (as Shortcuts names them), the name to give the
//  shortcut so the next request runs it, and Open Shortcuts / Copy Name.
//  Drawn in the island palette like the other result cards.
//

import AppKit
import SwiftUI

struct ShortcutSuggestionCardView: View {
    let suggestion: AppActionSuggestion

    @State private var hasCopiedName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actionList
            nameRow
            HStack(spacing: 8) {
                GlanceCardActionButton(title: "Open Shortcuts") { openShortcutsApp() }
                Spacer(minLength: 0)
                GlanceCardActionButton(title: hasCopiedName ? "Copied" : "Copy Name") { copySuggestedName() }
            }
        }
        .schedulingResultCardSurface()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: suggestion.application.applicationPath))
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Make it a Shortcut")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WispColor.Island.textPrimary)
                Text("\(AppActionRequestMatcher.shortName(of: suggestion.application.applicationName)) can do this through Shortcuts")
                    .font(.system(size: 11))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestion.matchedActions) { matchedAction in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WispColor.Island.textTertiary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(matchedAction.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(WispColor.Island.textPrimary)
                        if let descriptionText = matchedAction.descriptionText {
                            Text(descriptionText)
                                .font(.system(size: 11))
                                .foregroundColor(WispColor.Island.textTertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    /// The name to give the shortcut — the part that makes the next request work.
    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NAME IT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(WispColor.Island.textTertiary)
            Text(suggestion.suggestedShortcutName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(WispColor.Island.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(WispColor.Island.controlFill))
        }
    }

    private func openShortcutsApp() {
        // Shortcuts' own URL for a new, empty shortcut.
        if let newShortcutURL = URL(string: "shortcuts://create-shortcut") {
            NSWorkspace.shared.open(newShortcutURL)
        }
    }

    private func copySuggestedName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(suggestion.suggestedShortcutName, forType: .string)
        hasCopiedName = true
    }
}
