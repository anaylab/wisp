//
//  BrainPageReaderView.swift
//  leanring-buddy
//
//  One brain page, read: its title and summary, frontmatter as chips (kind,
//  tags, aliases, where it came from, when it last changed), the body drawn as
//  native text with clickable `[[links]]`, and then how it connects — the
//  pages it links to (unresolved targets dimmed, one click to create) and the
//  pages that link back, each with the line that mentions this page.
//
//  The action bar carries Back / Forward through the reading history, Edit,
//  the lock (a locked page is never changed by Wisp, only by hand), and the
//  file actions: Reveal in Finder, open in the default editor or Obsidian, and
//  Delete — which is versioned, so it can be undone from Brain → Log.
//

import SwiftUI

struct BrainPageReaderView: View {
    let page: BrainPage

    @ObservedObject private var brainStore = BrainStore.shared
    @ObservedObject private var navigator = BrainNavigator.shared

    @State private var isConfirmingDelete = false
    @State private var isShowingSourcesPopover = false
    /// A `[[link]]` with no page yet that the user clicked, for the create prompt.
    @State private var unresolvedLinkTargetToCreate: String?

    var body: some View {
        let linkResolver = BrainLinkResolver(pages: brainStore.pages)
        VStack(spacing: 0) {
            actionBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    frontmatterChips
                    if page.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyBodyHint
                    } else {
                        BrainMarkdownView(markdown: page.body, resolver: linkResolver, onOpenLink: openLink)
                    }
                    connectionsSection(linkResolver: linkResolver)
                }
                .padding(.horizontal, WispSpacing.xxl)
                .padding(.vertical, WispSpacing.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(
            "Delete “\(page.title)”?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete Page", role: .destructive, action: deletePage)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is removed from your brain. Wisp keeps a copy, so you can bring it back from Brain → Log.")
        }
        .confirmationDialog(
            "“\(unresolvedLinkTargetToCreate ?? "")” doesn't have a page yet",
            isPresented: Binding(
                get: { unresolvedLinkTargetToCreate != nil },
                set: { isPresented in if !isPresented { unresolvedLinkTargetToCreate = nil } }
            )
        ) {
            Button("Create Page…") {
                if let targetTitle = unresolvedLinkTargetToCreate {
                    navigator.newPageRequest = BrainNewPageRequest(suggestedTitle: targetTitle, suggestedKind: .note)
                }
                unresolvedLinkTargetToCreate = nil
            }
            Button("Cancel", role: .cancel) { unresolvedLinkTargetToCreate = nil }
        } message: {
            Text("Create it now, or leave the link — Wisp fills pages in as it learns more.")
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button {
                    navigator.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!navigator.canGoBack)
                .help("Back")
                .keyboardShortcut("[", modifiers: .command)
                Button {
                    navigator.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!navigator.canGoForward)
                .help("Forward")
                .keyboardShortcut("]", modifiers: .command)
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            .pointerCursor()

            if let updatedDate = page.updatedDate {
                Text("Updated \(updatedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }

            Spacer(minLength: 8)

            Button(action: toggleLock) {
                Image(systemName: page.isLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(page.isLocked ? WispColor.accentText : WispColor.textSecondary)
            }
            .buttonStyle(.bordered)
            .pointerCursor()
            .help(page.isLocked
                  ? "Locked — Wisp won't change this page. Click to let Wisp add to it again."
                  : "Lock this page so only you can change it")

            Button {
                navigator.isEditingSelectedPage = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("e", modifiers: .command)
            .pointerCursor()
            .help("Edit the page's markdown (⌘E)")

            Menu {
                Button("Reveal in Finder", systemImage: "folder") { brainStore.revealPageInFinder(page) }
                Button("Open in Default Editor", systemImage: "square.and.pencil") { brainStore.openPageInDefaultEditor(page) }
                if brainStore.isObsidianInstalled {
                    Button("Open in Obsidian", systemImage: "arrow.up.forward.app") { brainStore.openInObsidian(page: page) }
                }
                Divider()
                Button("Copy Link", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("[[\(page.title)]]", forType: .string)
                }
                Divider()
                Button("Delete Page…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .help("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: page.kind.symbolName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BrainKindStyle.color(for: page.kind))
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                        .fill(BrainKindStyle.color(for: page.kind).opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title)
                    .font(WispFont.hero)
                    .foregroundStyle(WispColor.textPrimary)
                    .textSelection(.enabled)
                if !page.summary.isEmpty {
                    Text(page.summary)
                        .font(.title3)
                        .foregroundStyle(WispColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var frontmatterChips: some View {
        BrainFlowLayout {
            BrainChip(text: page.kind.displayName, symbolName: page.kind.symbolName, tint: BrainKindStyle.color(for: page.kind))
            if page.isLocked {
                BrainChip(text: "Locked", symbolName: "lock.fill", tint: WispColor.accentText)
            }
            ForEach(page.tags, id: \.self) { tag in
                BrainChip(text: "#\(tag)")
            }
            if !page.aliases.isEmpty {
                BrainChip(text: "also " + page.aliases.joined(separator: ", "), symbolName: "textformat.alt")
            }
            if !page.sources.isEmpty {
                Button {
                    isShowingSourcesPopover = true
                } label: {
                    BrainChip(
                        text: page.sources.count == 1 ? "1 source" : "\(page.sources.count) sources",
                        symbolName: "doc.on.doc"
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Where this page's content came from")
                .popover(isPresented: $isShowingSourcesPopover, arrowEdge: .bottom) {
                    sourcesPopover
                }
            }
            if let createdDate = page.createdDate {
                BrainChip(text: "Created \(createdDate.formatted(date: .abbreviated, time: .omitted))", symbolName: "calendar")
            }
        }
    }

    private var sourcesPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources, oldest first")
                .font(.headline)
            ForEach(Array(page.sources.enumerated()), id: \.offset) { _, source in
                Label(source, systemImage: "doc.text")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(minWidth: 240, alignment: .leading)
    }

    private var emptyBodyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing on this page yet.")
                .font(.body)
                .foregroundStyle(WispColor.textSecondary)
            Button("Write something") { navigator.isEditingSelectedPage = true }
                .buttonStyle(.link)
                .pointerCursor()
        }
    }

    // MARK: - Connections

    @ViewBuilder
    private func connectionsSection(linkResolver: BrainLinkResolver) -> some View {
        let outgoingTargets = page.outgoingLinkTargets
        let backlinkPages = brainStore.backlinks(to: page)
        if !outgoingTargets.isEmpty || !backlinkPages.isEmpty {
            Divider().padding(.vertical, 4)
        }

        if !outgoingTargets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                connectionHeading("Links to", count: outgoingTargets.count)
                BrainFlowLayout {
                    ForEach(outgoingTargets, id: \.self) { target in
                        let linkedPage = linkResolver.slug(forTarget: target)
                            .flatMap { linkedSlug in brainStore.pages.first { $0.slug == linkedSlug } }
                        BrainPageLinkChip(title: linkedPage?.title ?? target, kind: linkedPage?.kind) {
                            if let linkedPage {
                                navigator.show(slug: linkedPage.slug)
                            } else {
                                unresolvedLinkTargetToCreate = target
                            }
                        }
                    }
                }
            }
        }

        if !backlinkPages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                connectionHeading("Linked from", count: backlinkPages.count)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(backlinkPages) { backlinkPage in
                        BacklinkRow(
                            backlinkPage: backlinkPage,
                            mentioningLine: BrainBacklinkContext.mentioningLine(
                                in: backlinkPage.body,
                                linkingToAnyOf: page.allNames + [page.slug]
                            ),
                            linkResolver: linkResolver,
                            onOpen: { navigator.show(slug: backlinkPage.slug) }
                        )
                    }
                }
            }
        }
    }

    private func connectionHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(WispFont.overline)
                .tracking(0.6)
                .foregroundStyle(WispColor.textSecondary)
            Text("\(count)")
                .font(WispFont.overline)
                .foregroundStyle(WispColor.textTertiary)
        }
    }

    // MARK: - Actions

    private func openLink(_ destination: BrainInlineMarkdown.LinkDestination) {
        switch destination {
        case .page(let target):
            let linkResolver = BrainLinkResolver(pages: brainStore.pages)
            if let linkedSlug = linkResolver.slug(forTarget: target) {
                navigator.show(slug: linkedSlug)
            } else {
                unresolvedLinkTargetToCreate = target
            }
        case .missingPage(let target):
            unresolvedLinkTargetToCreate = target
        }
    }

    private func toggleLock() {
        var lockedOrUnlockedPage = page
        lockedOrUnlockedPage.isLocked.toggle()
        brainStore.savePageEditedByUser(lockedOrUnlockedPage)
    }

    private func deletePage() {
        let deletedSlug = page.slug
        if brainStore.deletePage(withSlug: deletedSlug) {
            navigator.pageWasDeleted(slug: deletedSlug)
        }
    }
}

/// A page linking here, with the line that mentions this page underneath.
private struct BacklinkRow: View {
    let backlinkPage: BrainPage
    let mentioningLine: String?
    let linkResolver: BrainLinkResolver
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: backlinkPage.kind.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BrainKindStyle.color(for: backlinkPage.kind))
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(backlinkPage.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(WispColor.textPrimary)
                    if let mentioningLine {
                        // Shown as plain styled text: the whole row is the
                        // button, so the line's own links aren't separate targets.
                        Text(BrainInlineMarkdown.attributedString(from: mentioningLine, isResolved: linkResolver.isResolved))
                            .font(.callout)
                            .foregroundStyle(WispColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else if !backlinkPage.summary.isEmpty {
                        Text(backlinkPage.summary)
                            .font(.callout)
                            .foregroundStyle(WispColor.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                    .fill(isHovered ? WispColor.surface2 : WispColor.surface1.opacity(0.6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in isHovered = hovering }
        .help("Open \(backlinkPage.title)")
    }
}
