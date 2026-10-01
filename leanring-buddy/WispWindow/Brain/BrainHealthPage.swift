//
//  BrainHealthPage.swift
//  leanring-buddy
//
//  Brain → Health: how the brain is doing. An overview first — pages by kind,
//  links, how many are still dangling, sources cited, the most connected
//  pages and the most recently changed — computed from the pages themselves,
//  so it's right even before a check has run. Then the maintenance check
//  (`BrainMaintenance`, deterministic, no model): broken links, orphans,
//  likely duplicates, oversized pages, missing summaries, stale facts —
//  grouped by kind, each with a Fix button when Wisp can fix it on its own.
//

import SwiftUI

struct BrainHealthPage: View {
    /// Pages record only the day they changed (`updated: 2026-09-30`), so a
    /// clock-relative "14 hours ago" would really be measuring from midnight.
    static func dayRelativeText(for dayDate: Date) -> String {
        let calendar = Calendar.current
        let dayCount = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: dayDate),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        switch dayCount {
        case ..<1: return "today"
        case 1: return "yesterday"
        default: return "\(dayCount) days ago"
        }
    }

    @ObservedObject private var brainStore = BrainStore.shared
    @ObservedObject private var maintenance = BrainMaintenance.shared

    var body: some View {
        let overview = BrainOverviewStatistics(pages: brainStore.pages)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overviewCard(overview)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        mostConnectedCard(overview)
                        recentlyChangedCard
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        mostConnectedCard(overview)
                        recentlyChangedCard
                    }
                }
                issuesCard
            }
            .padding(.horizontal, WispSpacing.xxl)
            .padding(.vertical, WispSpacing.xl)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(WispColor.windowBackground)
    }

    // MARK: - Overview

    private func overviewCard(_ overview: BrainOverviewStatistics) -> some View {
        DashboardCard(title: "Overview") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 24) {
                    statistic(value: overview.pageCount, label: overview.pageCount == 1 ? "page" : "pages")
                    statistic(value: overview.resolvedLinkCount, label: overview.resolvedLinkCount == 1 ? "link" : "links")
                    statistic(value: overview.unresolvedLinkCount, label: "waiting for a page", isWarning: overview.unresolvedLinkCount > 0)
                    statistic(value: overview.distinctSourceCount, label: overview.distinctSourceCount == 1 ? "source cited" : "sources cited")
                    statistic(value: overview.lockedPageCount, label: "locked")
                }
                if overview.pageCount > 0 {
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(BrainPageKind.allCases, id: \.self) { kind in
                            let pageCountOfKind = overview.pageCountByKind[kind] ?? 0
                            if pageCountOfKind > 0 {
                                kindTile(kind: kind, pageCount: pageCountOfKind)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statistic(value: Int, label: String, isWarning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(isWarning ? WispColor.warningText : WispColor.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(WispColor.textSecondary)
        }
    }

    private func kindTile(kind: BrainPageKind, pageCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrainKindStyle.color(for: kind))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(BrainKindStyle.color(for: kind).opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 0) {
                Text("\(pageCount)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(WispColor.textPrimary)
                Text(pageCount == 1 ? kind.displayName : kind.pluralDisplayName)
                    .font(.caption)
                    .foregroundStyle(WispColor.textSecondary)
            }
        }
    }

    private func mostConnectedCard(_ overview: BrainOverviewStatistics) -> some View {
        DashboardCard(title: "Most connected") {
            if overview.mostConnectedPages.isEmpty {
                Text("Pages that link to each other show up here.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(overview.mostConnectedPages, id: \.page.slug) { connectedPage in
                        pageShortcutRow(page: connectedPage.page, trailingText: "\(connectedPage.linkCount)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var recentlyChangedCard: some View {
        let recentlyChangedPages = brainStore.pages
            .filter { $0.updatedDate != nil }
            .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
            .prefix(5)
        return DashboardCard(title: "Recently changed") {
            if recentlyChangedPages.isEmpty {
                Text("Pages Wisp or you change show up here.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(recentlyChangedPages)) { page in
                        pageShortcutRow(
                            page: page,
                            trailingText: page.updatedDate.map(Self.dayRelativeText(for:)) ?? ""
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func pageShortcutRow(page: BrainPage, trailingText: String) -> some View {
        Button {
            BrainNavigator.openPageInWindow(slug: page.slug)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.kind.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BrainKindStyle.color(for: page.kind))
                    .frame(width: 16)
                Text(page.title)
                    .font(.callout)
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(trailingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WispColor.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Open \(page.title)")
    }

    // MARK: - Issues

    private var issuesCard: some View {
        DashboardCard(title: "Check-up") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(checkStatusText)
                        .font(.callout)
                        .foregroundStyle(WispColor.textSecondary)
                    Spacer()
                    if maintenance.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Button("Run Check", systemImage: "stethoscope") { maintenance.runLint() }
                        .buttonStyle(.bordered)
                        .disabled(maintenance.isWorking)
                        .pointerCursor(isEnabled: !maintenance.isWorking)
                }

                if maintenance.lastLintDate != nil && maintenance.issues.isEmpty && !maintenance.isWorking {
                    Label("Everything looks tidy.", systemImage: "checkmark.seal")
                        .font(.body)
                        .foregroundStyle(WispColor.success)
                } else if !maintenance.issues.isEmpty {
                    ForEach(issueKindsInDisplayOrder, id: \.self) { issueKind in
                        let issuesOfKind = maintenance.issues.filter { $0.kind == issueKind }
                        if !issuesOfKind.isEmpty {
                            Divider()
                            issueGroup(kind: issueKind, issues: issuesOfKind)
                        }
                    }
                }
            }
        }
    }

    private var checkStatusText: String {
        if maintenance.isWorking { return "Checking your brain…" }
        guard let lastLintDate = maintenance.lastLintDate else {
            return "Looks for broken links, orphan pages, likely duplicates, pages that have grown too big and missing summaries. Runs on its own now and then, too."
        }
        let issueCount = maintenance.issues.count
        let issueSummary = issueCount == 0 ? "no issues" : (issueCount == 1 ? "1 issue" : "\(issueCount) issues")
        return "Last checked \(BrainRelativeTime.description(for: lastLintDate)) — \(issueSummary)."
    }

    private var issueKindsInDisplayOrder: [BrainLintIssue.Kind] {
        [.brokenLink, .likelyDuplicate, .staleFact, .oversizedPage, .missingSummary, .orphanPage]
    }

    private func issueGroup(kind: BrainLintIssue.Kind, issues: [BrainLintIssue]) -> some View {
        let linkResolver = BrainLinkResolver(pages: brainStore.pages)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbolName(for: kind))
                    .foregroundStyle(WispColor.warningText)
                Text(Self.title(for: kind))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(WispColor.textPrimary)
                Text("\(issues.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WispColor.textTertiary)
                Spacer()
                let fixableIssues = issues.filter(\.isAutoFixable)
                if fixableIssues.count > 1 {
                    Button("Fix All \(fixableIssues.count)") {
                        for fixableIssue in fixableIssues { maintenance.fix(fixableIssue) }
                    }
                    .buttonStyle(.link)
                    .disabled(maintenance.isWorking)
                    .pointerCursor(isEnabled: !maintenance.isWorking)
                }
            }
            Text(Self.explanation(for: kind))
                .font(.caption)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(issues) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(BrainInlineMarkdown.attributedString(from: issue.message, isResolved: linkResolver.isResolved))
                            .font(.callout)
                            .foregroundStyle(WispColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        let issuePages = issue.pageSlugs.compactMap { issueSlug in brainStore.pages.first { $0.slug == issueSlug } }
                        if !issuePages.isEmpty {
                            BrainFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                                ForEach(issuePages) { issuePage in
                                    BrainPageLinkChip(title: issuePage.title, kind: issuePage.kind) {
                                        BrainNavigator.openPageInWindow(slug: issuePage.slug)
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Fix") { maintenance.fix(issue) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!issue.isAutoFixable || maintenance.isWorking)
                        .pointerCursor(isEnabled: issue.isAutoFixable && !maintenance.isWorking)
                        .help(issue.isAutoFixable ? "Let Wisp fix this" : "This one needs you — open the page to fix it")
                }
                .padding(.leading, 22)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let destination = BrainInlineMarkdown.destination(from: url) else { return .systemAction }
            switch destination {
            case .page(let target), .missingPage(let target):
                if let targetSlug = linkResolver.slug(forTarget: target) {
                    BrainNavigator.openPageInWindow(slug: targetSlug)
                }
            }
            return .handled
        })
    }

    static func title(for kind: BrainLintIssue.Kind) -> String {
        switch kind {
        case .brokenLink: return "Broken links"
        case .orphanPage: return "Orphan pages"
        case .likelyDuplicate: return "Likely duplicates"
        case .oversizedPage: return "Pages getting too big"
        case .missingSummary: return "Missing summaries"
        case .staleFact: return "Possibly outdated"
        }
    }

    static func symbolName(for kind: BrainLintIssue.Kind) -> String {
        switch kind {
        case .brokenLink: return "link.badge.plus"
        case .orphanPage: return "circle.dashed"
        case .likelyDuplicate: return "square.on.square"
        case .oversizedPage: return "text.append"
        case .missingSummary: return "text.quote"
        case .staleFact: return "clock.badge.exclamationmark"
        }
    }

    static func explanation(for kind: BrainLintIssue.Kind) -> String {
        switch kind {
        case .brokenLink: return "Links to pages that don't exist. Fixing creates a short stub page for each."
        case .orphanPage: return "Pages nothing links to and that link nowhere — easy to lose track of."
        case .likelyDuplicate: return "Two pages that seem to be about the same thing. Fixing merges them; the merge can be undone from the Log."
        case .oversizedPage: return "Close to the size limit, after which Wisp can't add to them. Split them or trim old notes."
        case .missingSummary: return "Pages without their one-line summary, which is what Wisp reads first."
        case .staleFact: return "Facts that may contradict newer ones or have gone out of date."
        }
    }
}

// MARK: - Overview statistics

/// Counts for the overview, computed from the page list in one pass.
struct BrainOverviewStatistics {
    let pageCount: Int
    let pageCountByKind: [BrainPageKind: Int]
    let resolvedLinkCount: Int
    let unresolvedLinkCount: Int
    let distinctSourceCount: Int
    let lockedPageCount: Int
    let mostConnectedPages: [(page: BrainPage, linkCount: Int)]

    init(pages: [BrainPage]) {
        let linkResolver = BrainLinkResolver(pages: pages)
        var pageCountByKind: [BrainPageKind: Int] = [:]
        var resolvedLinkCount = 0
        var unresolvedLinkCount = 0
        var distinctSources = Set<String>()
        var linkCountBySlug: [String: Int] = [:]
        for page in pages {
            pageCountByKind[page.kind, default: 0] += 1
            for source in page.sources { distinctSources.insert(source.lowercased()) }
            for target in page.outgoingLinkTargets {
                if let targetSlug = linkResolver.slug(forTarget: target) {
                    guard targetSlug != page.slug else { continue }
                    resolvedLinkCount += 1
                    linkCountBySlug[page.slug, default: 0] += 1
                    linkCountBySlug[targetSlug, default: 0] += 1
                } else {
                    unresolvedLinkCount += 1
                }
            }
        }
        // "you" is the label hand-made pages carry, not a source anyone cites.
        distinctSources.remove("you")

        self.pageCount = pages.count
        self.pageCountByKind = pageCountByKind
        self.resolvedLinkCount = resolvedLinkCount
        self.unresolvedLinkCount = unresolvedLinkCount
        self.distinctSourceCount = distinctSources.count
        self.lockedPageCount = pages.filter(\.isLocked).count
        self.mostConnectedPages = pages
            .compactMap { page in linkCountBySlug[page.slug].map { (page: page, linkCount: $0) } }
            .sorted { $0.linkCount > $1.linkCount }
            .prefix(5)
            .map { $0 }
    }
}
