//
//  BrainSharedViews.swift
//  leanring-buddy
//
//  Pieces every Brain page uses: where the Pages reader is pointed
//  (`BrainNavigator`, with back/forward history), the colour and symbol of each
//  page kind and change origin, chips, a wrapping chip layout, a clickable page
//  link, and the rendered-markdown view.
//
//  Kind colours are system colours (they adapt to light/dark and to the
//  user's accent-contrast settings) plus Wisp's own accent for the user's page
//  and the lavender AI accent for topics — never hardcoded hex.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Navigation

/// A request for the New Page sheet, optionally pre-filled (an unresolved
/// `[[link]]` offers to create the page it names).
struct BrainNewPageRequest: Identifiable {
    let id = UUID()
    var suggestedTitle: String
    var suggestedKind: BrainPageKind
}

/// Which page the Pages reader shows, and the history behind Back / Forward.
/// Shared so the graph, the log, Health and Today can all open a page.
@MainActor
final class BrainNavigator: ObservableObject {
    static let shared = BrainNavigator()

    /// Most pages kept in each direction of the history.
    private static let maximumHistoryLength = 50

    @Published private(set) var selectedPageSlug: String?
    @Published private(set) var backHistorySlugs: [String] = []
    @Published private(set) var forwardHistorySlugs: [String] = []
    @Published var isEditingSelectedPage = false
    @Published var newPageRequest: BrainNewPageRequest?

    var canGoBack: Bool { !backHistorySlugs.isEmpty }
    var canGoForward: Bool { !forwardHistorySlugs.isEmpty }

    /// Shows a page in the reader. Following a link records history; picking
    /// from the list does too, so Back always returns to what was on screen.
    func show(slug: String?) {
        guard slug != selectedPageSlug else { return }
        if let currentSlug = selectedPageSlug {
            backHistorySlugs.append(currentSlug)
            if backHistorySlugs.count > Self.maximumHistoryLength { backHistorySlugs.removeFirst() }
        }
        forwardHistorySlugs = []
        isEditingSelectedPage = false
        selectedPageSlug = slug
    }

    func goBack() {
        guard let previousSlug = backHistorySlugs.popLast() else { return }
        if let currentSlug = selectedPageSlug { forwardHistorySlugs.append(currentSlug) }
        isEditingSelectedPage = false
        selectedPageSlug = previousSlug
    }

    func goForward() {
        guard let nextSlug = forwardHistorySlugs.popLast() else { return }
        if let currentSlug = selectedPageSlug { backHistorySlugs.append(currentSlug) }
        isEditingSelectedPage = false
        selectedPageSlug = nextSlug
    }

    /// After a rename the old slug is gone: history entries follow the page.
    func pageWasRenamed(fromSlug previousSlug: String, toSlug newSlug: String) {
        backHistorySlugs = backHistorySlugs.map { $0 == previousSlug ? newSlug : $0 }
        forwardHistorySlugs = forwardHistorySlugs.map { $0 == previousSlug ? newSlug : $0 }
        if selectedPageSlug == previousSlug { selectedPageSlug = newSlug }
    }

    /// After a delete, drop the page from history and step back.
    func pageWasDeleted(slug deletedSlug: String) {
        backHistorySlugs.removeAll { $0 == deletedSlug }
        forwardHistorySlugs.removeAll { $0 == deletedSlug }
        if selectedPageSlug == deletedSlug {
            isEditingSelectedPage = false
            selectedPageSlug = backHistorySlugs.popLast()
        }
    }

    /// Opens the Wisp window at Brain → Pages showing this page — for the
    /// graph, the log, Health, Today, or anywhere else in the app.
    static func openPageInWindow(slug: String) {
        shared.show(slug: slug)
        WispWindowNavigator.open(.brainPages)
    }
}

// MARK: - Kind and origin styling

enum BrainKindStyle {
    static func color(for kind: BrainPageKind) -> Color {
        switch kind {
        case .me: return WispColor.accentText
        case .person: return Color(nsColor: .systemBlue)
        case .project: return Color(nsColor: .systemOrange)
        case .topic: return WispColor.intelligence
        case .organization: return Color(nsColor: .systemTeal)
        case .place: return Color(nsColor: .systemGreen)
        case .event: return Color(nsColor: .systemPink)
        case .source: return Color(nsColor: .systemBrown)
        case .note: return Color(nsColor: .systemGray)
        }
    }

    /// Kinds a user can pick for a new page (there is only one Me page).
    static var kindsForNewPage: [BrainPageKind] {
        BrainPageKind.allCases.filter { $0 != .me }
    }
}

enum BrainOriginStyle {
    static func displayName(for origin: BrainEditProvenance.Origin) -> String {
        switch origin {
        case .user: return "You"
        case .conversation: return "Conversation"
        case .ingest: return "Inbox"
        case .notesImport: return "Notes import"
        case .activity: return "Screen activity"
        case .agent: return "Wisp"
        }
    }

    static func symbolName(for origin: BrainEditProvenance.Origin) -> String {
        switch origin {
        case .user: return "hand.point.up.left"
        case .conversation: return "bubble.left.and.bubble.right"
        case .ingest: return "tray.and.arrow.down"
        case .notesImport: return "note.text"
        case .activity: return "macwindow"
        case .agent: return "sparkles"
        }
    }

    static let allOrigins: [BrainEditProvenance.Origin] = [.user, .conversation, .ingest, .notesImport, .activity, .agent]

    static func trustLabel(for trust: BrainEditProvenance.Trust) -> String {
        switch trust {
        case .userAuthored: return "Your words"
        case .derivedFromUser: return "From you"
        case .external: return "Outside source"
        }
    }

    static func trustExplanation(for trust: BrainEditProvenance.Trust) -> String {
        switch trust {
        case .userAuthored: return "Written by you — may rewrite sections and your Me page."
        case .derivedFromUser: return "Drawn from your own conversations or notes — may add, never replace."
        case .external: return "From an article, page or screen text — may only add, and never touches your Me page."
        }
    }

    static func trustColor(for trust: BrainEditProvenance.Trust) -> Color {
        switch trust {
        case .userAuthored: return WispColor.success
        case .derivedFromUser: return WispColor.accentText
        case .external: return WispColor.warningText
        }
    }
}

// MARK: - Chips

/// A small rounded label: frontmatter values, trust badges, counts.
struct BrainChip: View {
    let text: String
    var symbolName: String?
    var tint: Color = WispColor.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

/// Lays chips out left to right, wrapping onto new lines as needed.
struct BrainFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRowWidth: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if currentRowWidth > 0 && currentRowWidth + horizontalSpacing + subviewSize.width > availableWidth {
                totalHeight += currentRowHeight + verticalSpacing
                widestRowWidth = max(widestRowWidth, currentRowWidth)
                currentRowWidth = 0
                currentRowHeight = 0
            }
            currentRowWidth += (currentRowWidth > 0 ? horizontalSpacing : 0) + subviewSize.width
            currentRowHeight = max(currentRowHeight, subviewSize.height)
        }
        totalHeight += currentRowHeight
        widestRowWidth = max(widestRowWidth, currentRowWidth)
        return CGSize(width: proposal.width ?? widestRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + subviewSize.width > bounds.maxX {
                currentX = bounds.minX
                currentY += currentRowHeight + verticalSpacing
                currentRowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(subviewSize))
            currentX += subviewSize.width + horizontalSpacing
            currentRowHeight = max(currentRowHeight, subviewSize.height)
        }
    }
}

// MARK: - Page link

/// A page as a clickable chip (kind colour dot + title) that opens it in the
/// reader. Unresolved targets are drawn dimmed and dashed, and their click
/// asks to create the page instead.
struct BrainPageLinkChip: View {
    let title: String
    let kind: BrainPageKind?
    let action: () -> Void

    @State private var isHovered = false

    private var isUnresolved: Bool { kind == nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let kind {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BrainKindStyle.color(for: kind))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(WispColor.textTertiary)
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isUnresolved ? WispColor.textTertiary : WispColor.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovered ? WispColor.surface3 : WispColor.surface2)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isUnresolved ? WispColor.borderStrong : Color.clear,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in isHovered = hovering }
        .help(isUnresolved ? "No page called \(title) yet — click to create it" : "Open \(title)")
    }
}

// MARK: - Relative time

enum BrainRelativeTime {
    static func description(for date: Date?) -> String {
        guard let date else { return "never" }
        if Date().timeIntervalSince(date) < 45 { return "just now" }
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .full
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Rendered markdown

/// A page body drawn natively: headings, paragraphs, bullets and tasks,
/// numbered items, quotes, code and rules, with clickable `[[links]]`. Clicks
/// on brain links go to `onOpenLink`; web links open in the browser.
struct BrainMarkdownView: View {
    let markdown: String
    let resolver: BrainLinkResolver
    let onOpenLink: (BrainInlineMarkdown.LinkDestination) -> Void

    var body: some View {
        let blocks = BrainMarkdownBlockParser.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { blockIndex, block in
                blockView(block, isFirstBlock: blockIndex == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if let destination = BrainInlineMarkdown.destination(from: url) {
                onOpenLink(destination)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder
    private func blockView(_ block: BrainMarkdownBlock, isFirstBlock: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(styledInlineText(text))
                .font(headingFont(forLevel: level))
                .foregroundStyle(WispColor.textPrimary)
                .padding(.top, isFirstBlock ? 0 : (level <= 2 ? 10 : 4))
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(styledInlineText(text))
                .font(.body)
                .foregroundStyle(WispColor.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let indentLevel, let text, let checkboxIsChecked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let checkboxIsChecked {
                    Image(systemName: checkboxIsChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(checkboxIsChecked ? WispColor.accentText : WispColor.textTertiary)
                } else {
                    Circle()
                        .fill(indentLevel == 0 ? WispColor.accentText : WispColor.textTertiary)
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] + 3 }
                }
                Text(styledInlineText(text))
                    .font(.body)
                    .foregroundStyle(checkboxIsChecked == true ? WispColor.textSecondary : WispColor.textPrimary)
                    .strikethrough(checkboxIsChecked == true, color: WispColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indentLevel) * 18 + 2)
        case .numbered(let indentLevel, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(WispColor.textSecondary)
                Text(styledInlineText(text))
                    .font(.body)
                    .foregroundStyle(WispColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indentLevel) * 18)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(WispColor.borderStrong)
                    .frame(width: 3)
                Text(styledInlineText(text))
                    .font(.body)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(WispColor.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WispRadius.small, style: .continuous)
                    .fill(WispColor.surface2)
            )
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func headingFont(forLevel level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    /// Inline markdown with brain links coloured: existing pages in the accent,
    /// missing ones dimmed and underlined with a dash, so the eye can tell
    /// "go there" from "nothing there yet" without hovering.
    private func styledInlineText(_ text: String) -> AttributedString {
        var attributedText = BrainInlineMarkdown.attributedString(from: text, isResolved: resolver.isResolved)
        for run in attributedText.runs {
            guard let linkURL = run.link else { continue }
            switch BrainInlineMarkdown.destination(from: linkURL) {
            case .page:
                attributedText[run.range].foregroundColor = WispColor.accentText
            case .missingPage:
                attributedText[run.range].foregroundColor = WispColor.textTertiary
                attributedText[run.range].underlineStyle = Text.LineStyle(pattern: .dash, color: WispColor.textTertiary)
            case nil:
                attributedText[run.range].foregroundColor = WispColor.accentText
                attributedText[run.range].underlineStyle = .single
            }
        }
        for run in attributedText.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributedText[run.range].font = .system(.body, design: .monospaced)
            attributedText[run.range].backgroundColor = WispColor.surface2
        }
        return attributedText
    }
}

// MARK: - Window visibility

/// Reports whether the hosting window is actually on screen (not minimised,
/// not fully covered, not on another Space), so the graph can stop its clock
/// when nobody can see it.
struct BrainWindowVisibilityReader: NSViewRepresentable {
    let onVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityTrackingView {
        let trackingView = VisibilityTrackingView()
        trackingView.onVisibilityChange = onVisibilityChange
        return trackingView
    }

    func updateNSView(_ nsView: VisibilityTrackingView, context: Context) {
        nsView.onVisibilityChange = onVisibilityChange
    }

    final class VisibilityTrackingView: NSView {
        var onVisibilityChange: ((Bool) -> Void)?
        private var occlusionObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = nil
            guard let window else { return }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportVisibility() }
            }
            reportVisibility()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func reportVisibility() {
            guard let window else { return }
            onVisibilityChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        }
    }
}
