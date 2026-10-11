//
//  BrainPagesPage.swift
//  leanring-buddy
//
//  Brain → Pages: every page of the user's brain on the left — the Me page
//  pinned on top, the rest grouped by kind, or ranked search results while
//  typing — and the selected page on the right, read (`BrainPageReaderView`)
//  or edited (`BrainPageEditorView`).
//
//  The vault on disk is the source of truth (Obsidian or a text editor may
//  change it at any time), so while this page is on screen it asks the store
//  to re-read the wiki folder every few seconds; the store only re-parses when
//  a file actually changed.
//

import SwiftUI

struct BrainPagesPage: View {
    @ObservedObject private var brainStore = BrainStore.shared
    @ObservedObject private var navigator = BrainNavigator.shared

    @State private var searchText = ""
    @State private var kindFilter: BrainPageKind?

    /// How often hand edits made outside Wisp are picked up while visible.
    private let externalEditCheckIntervalNanoseconds: UInt64 = 3_000_000_000

    var body: some View {
        Group {
            if brainStore.pages.isEmpty {
                emptyBrainInvitation
            } else {
                HStack(spacing: 0) {
                    pageListColumn
                        .frame(width: 270)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(WispColor.windowBackground)
        .onAppear(perform: selectDefaultPageIfNeeded)
        .onChange(of: brainStore.pages) { _, _ in selectDefaultPageIfNeeded() }
        .task {
            while !Task.isCancelled {
                brainStore.reloadIfChanged()
                try? await Task.sleep(nanoseconds: externalEditCheckIntervalNanoseconds)
            }
        }
        .sheet(item: $navigator.newPageRequest) { newPageRequest in
            BrainNewPageSheet(request: newPageRequest)
        }
    }

    private func selectDefaultPageIfNeeded() {
        if let selectedPageSlug = navigator.selectedPageSlug,
           brainStore.pages.contains(where: { $0.slug == selectedPageSlug }) {
            return
        }
        if navigator.selectedPageSlug == nil, let firstPage = brainStore.mePage ?? brainStore.pages.first {
            navigator.show(slug: firstPage.slug)
        }
    }

    // MARK: - List

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var listSelection: Binding<String?> {
        Binding(
            get: { navigator.selectedPageSlug },
            set: { newSlug in
                if let newSlug { navigator.show(slug: newSlug) }
            }
        )
    }

    private var pageListColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                searchField
                kindFilterMenu
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            List(selection: listSelection) {
                if trimmedSearchText.isEmpty {
                    groupedPageRows
                } else {
                    searchResultRows
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: 8) {
                Button {
                    navigator.newPageRequest = BrainNewPageRequest(suggestedTitle: "", suggestedKind: kindFilter ?? .note)
                } label: {
                    Label("New Page", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.large)
                .pointerCursor()

                Button {
                    WispWindowRouter.shared.select(.brainInbox)
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .frame(height: 16)
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.large)
                .pointerCursor()
                .help("Add files, links or text to your brain")
            }
            .padding(12)
        }
        .background(WispColor.groupedCardBackground.opacity(0.6))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WispColor.textTertiary)
            TextField("Search your brain", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(WispColor.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: WispRadius.small, style: .continuous)
                .fill(WispColor.surface2)
        )
    }

    private var kindFilterMenu: some View {
        Menu {
            Button {
                kindFilter = nil
            } label: {
                if kindFilter == nil { Label("All kinds", systemImage: "checkmark") } else { Text("All kinds") }
            }
            Divider()
            ForEach(BrainPageKind.allCases, id: \.self) { kind in
                Button {
                    kindFilter = kind
                } label: {
                    if kindFilter == kind {
                        Label(kind.pluralDisplayName, systemImage: "checkmark")
                    } else {
                        Label(kind.pluralDisplayName, systemImage: kind.symbolName)
                    }
                }
            }
        } label: {
            Image(systemName: kindFilter == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(kindFilter == nil ? WispColor.textSecondary : WispColor.accentText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .help(kindFilter.map { "Showing \($0.pluralDisplayName.lowercased()) only" } ?? "Filter by kind")
    }

    @ViewBuilder
    private var groupedPageRows: some View {
        if kindFilter == nil || kindFilter == .me {
            if let mePage = brainStore.mePage {
                Section {
                    pageRow(mePage)
                        .tag(mePage.slug)
                }
            } else if kindFilter == nil {
                Section {
                    Button {
                        if let createdPage = brainStore.createPageByUser(title: "Me", kind: .me) {
                            navigator.show(slug: createdPage.slug)
                            navigator.isEditingSelectedPage = true
                        }
                    } label: {
                        Label("Start your Me page", systemImage: "person.crop.circle.badge.plus")
                            .foregroundStyle(WispColor.accentText)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("The page about you — Wisp reads it with every question")
                }
            }
        }
        ForEach(kindsToList, id: \.self) { kind in
            let pagesOfKind = brainStore.pages.filter { $0.kind == kind }
            if !pagesOfKind.isEmpty {
                Section {
                    ForEach(pagesOfKind) { page in
                        pageRow(page)
                            .tag(page.slug)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(kind.pluralDisplayName)
                        Text("\(pagesOfKind.count)")
                            .foregroundStyle(WispColor.textTertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var kindsToList: [BrainPageKind] {
        if let kindFilter { return kindFilter == .me ? [] : [kindFilter] }
        return BrainPageKind.allCases.filter { $0 != .me }
    }

    @ViewBuilder
    private var searchResultRows: some View {
        let searchResults = brainStore.search(
            trimmedSearchText,
            limit: 60,
            kinds: kindFilter.map { Set([$0]) }
        )
        if searchResults.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No page mentions “\(trimmedSearchText)”.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                Button("Create “\(trimmedSearchText)”") {
                    navigator.newPageRequest = BrainNewPageRequest(suggestedTitle: trimmedSearchText, suggestedKind: kindFilter ?? .note)
                }
                .buttonStyle(.link)
                .pointerCursor()
            }
            .padding(.vertical, 8)
        } else {
            Section("\(searchResults.count) \(searchResults.count == 1 ? "match" : "matches")") {
                ForEach(searchResults, id: \.slug) { searchResult in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: searchResult.kind.symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BrainKindStyle.color(for: searchResult.kind))
                            .frame(width: 18)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(searchResult.title)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            let excerpt = searchResult.snippet.isEmpty ? searchResult.summary : searchResult.snippet
                            if !excerpt.isEmpty {
                                Text(excerpt)
                                    .font(.caption)
                                    .foregroundStyle(WispColor.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(searchResult.slug)
                }
            }
        }
    }

    private func pageRow(_ page: BrainPage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: page.kind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrainKindStyle.color(for: page.kind))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title)
                    .font(.body.weight(page.kind == .me ? .semibold : .regular))
                    .lineLimit(1)
                if !page.summary.isEmpty {
                    Text(page.summary)
                        .font(.caption)
                        .foregroundStyle(WispColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if page.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(WispColor.textTertiary)
                    .help("Locked — Wisp won't change this page")
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selectedPageSlug = navigator.selectedPageSlug,
           let selectedPage = brainStore.pages.first(where: { $0.slug == selectedPageSlug }) {
            if navigator.isEditingSelectedPage {
                BrainPageEditorView(originalPage: selectedPage)
                    .id("edit-\(selectedPage.slug)")
            } else {
                BrainPageReaderView(page: selectedPage)
                    .id("read-\(selectedPage.slug)")
            }
        } else {
            ContentUnavailableView {
                Label("Pick a page", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Choose a page on the left, or search for anything Wisp knows.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyBrainInvitation: some View {
        ContentUnavailableView {
            Label("Your brain is empty", systemImage: "brain")
        } description: {
            Text("Wisp files what it learns here — lasting facts from your conversations, things you add to the Inbox, notes you import. Every page is a plain markdown file on this Mac that you can read and edit.")
        } actions: {
            HStack(spacing: 10) {
                Button("Add to Brain") { WispWindowRouter.shared.select(.brainInbox) }
                    .buttonStyle(WispPillButtonStyle())
                    .controlSize(.large)
                    .pointerCursor()
                Button("Start your Me page") {
                    if let createdPage = brainStore.createPageByUser(title: "Me", kind: .me) {
                        navigator.show(slug: createdPage.slug)
                        navigator.isEditingSelectedPage = true
                    }
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.large)
                .pointerCursor()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New page sheet

/// Title + kind for a page made by hand. Opens straight into the editor.
struct BrainNewPageSheet: View {
    let request: BrainNewPageRequest

    @ObservedObject private var brainStore = BrainStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pageTitle: String
    @State private var pageKind: BrainPageKind

    init(request: BrainNewPageRequest) {
        self.request = request
        _pageTitle = State(initialValue: request.suggestedTitle)
        _pageKind = State(initialValue: request.suggestedKind == .me ? .note : request.suggestedKind)
    }

    private var trimmedTitle: String {
        pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An existing page this title would land on — creating opens it instead.
    private var existingPageWithSameName: BrainPage? {
        guard !trimmedTitle.isEmpty else { return nil }
        return BrainLinkResolver(pages: brainStore.pages).slug(forTarget: trimmedTitle)
            .flatMap { existingSlug in brainStore.pages.first { $0.slug == existingSlug } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New page")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Title", text: $pageTitle, prompt: Text("Sarah Chen, Atlas, Lisbon trip…"))
                Picker("Kind", selection: $pageKind) {
                    ForEach(BrainKindStyle.kindsForNewPage, id: \.self) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                    }
                }
                .pointerCursor()
            }
            .formStyle(.columns)

            if let existingPage = existingPageWithSameName {
                Label("“\(existingPage.title)” already exists — this will open it.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button(existingPageWithSameName == nil ? "Create" : "Open") { createPage() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(WispPillButtonStyle())
                    .disabled(trimmedTitle.isEmpty)
                    .pointerCursor(isEnabled: !trimmedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func createPage() {
        let wasExistingPage = existingPageWithSameName != nil
        guard let page = brainStore.createPageByUser(title: trimmedTitle, kind: pageKind) else { return }
        dismiss()
        BrainNavigator.shared.show(slug: page.slug)
        // A fresh page is empty: go straight to writing it.
        if !wasExistingPage {
            BrainNavigator.shared.isEditingSelectedPage = true
        }
    }
}
