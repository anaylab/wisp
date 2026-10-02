//
//  CodingAgentNotchViews.swift
//  leanring-buddy
//
//  The notch's views for the features brought over from Coucou: a coding
//  agent's permission card, its live session rows, the short notices the notch
//  drops (a session finished, a payment came in, a deploy failed), the
//  connected-service rows, and the choice shown after a file is dropped.
//
//  All of them sit on the always-dark island, so they use the fixed
//  `WispColor.Island.*` set and `wispIslandButtonStyle`.
//

import AppKit
import SwiftUI

/// A short message the notch drops on its own and folds away after a moment.
enum NotchNotice: Equatable {
    case codingAgentCompletion(CodingAgentCompletion)
    case serviceEvent(ServiceIntegrationEvent)
}

private func islandToneColor(_ tone: ServiceIntegrationTone) -> Color {
    switch tone {
    case .good: return DS.Colors.success
    case .bad: return DS.Colors.destructive
    case .neutral: return WispColor.Island.textTertiary
    }
}

// MARK: - Permission card

/// "Claude Code wants to run `npm test` in clicky" with Deny / Always / Allow.
/// Nothing is allowed without a click; left alone, it hands the question back
/// to the terminal after `CodingAgentSessionStore.approvalTimeoutSeconds`.
struct CodingAgentApprovalCard: View {
    let approvalRequest: CodingAgentApprovalRequest
    /// How many more are queued behind this one.
    let queuedBehindCount: Int
    @ObservedObject private var sessionStore = CodingAgentSessionStore.shared
    @ObservedObject private var companionPreference = WispCompanionPreference.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if companionPreference.isCompanionEnabled {
                    WispCompanionFace(mood: .needsYou, size: 20)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(WispColor.Brand.lavender)
                }
                Text("\(approvalRequest.agentKind.displayName) · \(approvalRequest.projectName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if queuedBehindCount > 0 {
                    Text("+\(queuedBehindCount) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WispColor.Island.textTertiary)
                }
            }

            Text("Wants to use \(approvalRequest.details.toolName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WispColor.Island.textPrimary)

            Text(approvalRequest.details.actionSummary)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(WispColor.Island.textPrimary)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(WispColor.Island.controlFill)
                )

            HStack(spacing: 6) {
                Button {
                    jumpToSession()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                }
                .wispIslandButtonStyle(prominence: .subtle)
                .nativeTooltip("Jump to the terminal")

                Spacer(minLength: 0)

                Button("Deny") {
                    sessionStore.answer(approvalWithID: approvalRequest.id, decision: .deny)
                }
                .font(.system(size: 11.5, weight: .medium))
                .wispIslandButtonStyle(prominence: .subtle)
                .nativeTooltip("Tell \(approvalRequest.agentKind.displayName) no")

                if approvalRequest.details.offersAlwaysAllow {
                    Button("Always") {
                        sessionStore.answer(approvalWithID: approvalRequest.id, decision: .alwaysAllow)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .wispIslandButtonStyle(prominence: .subtle)
                    .nativeTooltip("Allow this and add the rule Claude Code suggests, so it won't ask again")
                }

                Button("Allow") {
                    sessionStore.answer(approvalWithID: approvalRequest.id, decision: .allow)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .wispIslandButtonStyle(prominence: .prominent)
                .nativeTooltip("Allow this once")
            }
        }
    }

    private func jumpToSession() {
        guard let session = sessionStore.sessions.first(where: { $0.id == approvalRequest.sessionID }) else { return }
        CodingAgentTerminalJumper.jump(to: session)
    }
}

// MARK: - Session row

struct CodingAgentSessionRow: View {
    let session: CodingAgentSession

    var body: some View {
        HStack(spacing: 8) {
            stateGlyph
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.projectName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 10.5))
                    .foregroundColor(WispColor.Island.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button {
                CodingAgentTerminalJumper.jump(to: session)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .frame(width: 24, height: 22)
                    .background(Capsule(style: .continuous).fill(WispColor.Island.controlFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableScaleButtonStyle())
            .pointerCursor()
            .nativeTooltip("Jump to this session's terminal")
        }
    }

    /// "Claude Code · Editing · NotchHUDView.swift"
    private var statusLine: String {
        var statusParts = [session.agentKind.displayName]
        switch session.state {
        case .working, .thinking:
            statusParts.append(session.latestStep ?? session.state.label)
        default:
            statusParts.append(session.state.label)
        }
        if session.runningSubagentCount > 0 {
            statusParts.append("\(session.runningSubagentCount) subagent\(session.runningSubagentCount == 1 ? "" : "s")")
        }
        return statusParts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stateGlyph: some View {
        switch session.state {
        case .working, .thinking:
            ProgressView()
                .controlSize(.mini)
                .tint(WispColor.Brand.lavender)
        case .waitingForApproval, .waitingForInput:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(WispColor.Brand.lavender)
        case .rateLimited:
            Image(systemName: "hourglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.warning)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.success)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.destructive)
        case .idle:
            Circle()
                .fill(WispColor.Island.textTertiary)
                .frame(width: 6, height: 6)
        }
    }
}

// MARK: - Notices

struct NotchNoticeCard: View {
    let notice: NotchNotice
    @ObservedObject private var companionPreference = WispCompanionPreference.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingGlyph
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(WispColor.Island.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let actionLabel {
                Button(actionLabel, action: performAction)
                    .font(.system(size: 11, weight: .medium))
                    .wispIslandButtonStyle(prominence: .subtle)
            }
        }
    }

    /// The companion hops for good news and droops for bad; with it off, a symbol.
    @ViewBuilder
    private var leadingGlyph: some View {
        if companionPreference.isCompanionEnabled, let companionMood {
            WispCompanionFace(mood: companionMood, size: 28)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(symbolColor)
                .frame(width: 22)
        }
    }

    private var companionMood: WispCompanionMood? {
        switch notice {
        case .codingAgentCompletion(let completion):
            return completion.didFail ? .sad : .happy
        case .serviceEvent(let event):
            switch event.tone {
            case .good: return .happy
            case .bad: return .sad
            case .neutral: return nil
            }
        }
    }

    private var symbolName: String {
        switch notice {
        case .codingAgentCompletion(let completion):
            return completion.didFail ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        case .serviceEvent(let event):
            return event.serviceKind.symbolName
        }
    }

    private var symbolColor: Color {
        switch notice {
        case .codingAgentCompletion(let completion):
            return completion.didFail ? DS.Colors.destructive : DS.Colors.success
        case .serviceEvent(let event):
            return event.tone == .neutral ? WispColor.Brand.lavender : islandToneColor(event.tone)
        }
    }

    private var title: String {
        switch notice {
        case .codingAgentCompletion(let completion):
            return completion.didFail
                ? "\(completion.agentName) stopped in \(completion.projectName)"
                : "\(completion.agentName) finished in \(completion.projectName)"
        case .serviceEvent(let event):
            return event.title
        }
    }

    private var detail: String {
        switch notice {
        case .codingAgentCompletion(let completion):
            return completion.summary
        case .serviceEvent(let event):
            return [event.serviceKind.displayName, event.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private var actionLabel: String? {
        switch notice {
        case .codingAgentCompletion: return "Jump"
        case .serviceEvent(let event): return event.url == nil ? nil : "Open"
        }
    }

    private func performAction() {
        switch notice {
        case .codingAgentCompletion(let completion):
            if let session = CodingAgentSessionStore.shared.sessions.first(where: { $0.id == completion.sessionID }) {
                CodingAgentTerminalJumper.jump(to: session)
            }
        case .serviceEvent(let event):
            if let eventURL = event.url { NSWorkspace.shared.open(eventURL) }
        }
    }
}

// MARK: - Connected services

struct ConnectedServiceNotchRow: View {
    let serviceKind: ServiceIntegrationKind
    let snapshot: ServiceIntegrationSnapshot?
    let errorText: String?

    var body: some View {
        Button {
            if let dashboardURL = serviceKind.dashboardURL {
                NSWorkspace.shared.open(dashboardURL)
            } else {
                WispWindowNavigator.open(.services)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: serviceKind.symbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .frame(width: 14)
                Text(serviceKind.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(errorText == nil ? WispColor.Island.textSecondary : DS.Colors.destructive)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(WispColor.Island.controlFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .nativeTooltip(snapshot.map { $0.plainTextSummary(serviceName: serviceKind.displayName) } ?? errorText)
    }

    private var statusText: String {
        if let snapshot { return snapshot.headline }
        if let errorText { return errorText }
        return "Loading…"
    }
}

// MARK: - File drop choice

/// After a drop: what should Wisp do with the file?
struct NotchFileDropChoiceCard: View {
    @ObservedObject private var attachmentStore = NotchFileAttachmentStore.shared
    let onAskAboutIt: () -> Void
    let onAddToBrain: () -> Void
    let onEmail: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WispColor.Island.textSecondary)
                Text(droppedFilesTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(WispColor.Island.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Do nothing with it")
            }
            HStack(spacing: 6) {
                if attachmentStore.canAskAboutPendingDrop {
                    Button(action: onAskAboutIt) {
                        Label("Ask about it", systemImage: "text.bubble")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .wispIslandButtonStyle(prominence: .prominent)
                    .nativeTooltip("Attach it to your next questions")
                }
                if !attachmentStore.brainReadablePendingFileURLs.isEmpty {
                    Button(action: onAddToBrain) {
                        Label("Add to brain", systemImage: "brain")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .wispIslandButtonStyle(prominence: .subtle)
                    .nativeTooltip("Read it into your brain")
                }
                Button(action: onEmail) {
                    Label("Email", systemImage: "envelope")
                        .font(.system(size: 11, weight: .medium))
                }
                .wispIslandButtonStyle(prominence: .subtle)
                .nativeTooltip("Start a new email with it attached — you choose who and press Send")
            }
        }
    }

    private var droppedFilesTitle: String {
        let droppedFileURLs = attachmentStore.pendingDroppedFileURLs
        if droppedFileURLs.count == 1, let onlyFileURL = droppedFileURLs.first {
            return onlyFileURL.lastPathComponent
        }
        return "\(droppedFileURLs.count) files"
    }
}

/// The chip above the chat's composer while a file is attached.
struct NotchAttachedFileChip: View {
    let attachedFile: NotchAttachedFile
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 10, weight: .semibold))
            Text(attachedFile.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if attachedFile.wasTruncated {
                Text("beginning only")
                    .font(.system(size: 10))
                    .foregroundColor(WispColor.Island.textTertiary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Stop attaching this file")
        }
        .foregroundColor(WispColor.Island.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule(style: .continuous).fill(WispColor.Island.controlFill))
        .nativeTooltip("Wisp reads this file with each question until you remove it")
    }
}
