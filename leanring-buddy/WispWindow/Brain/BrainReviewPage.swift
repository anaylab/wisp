//
//  BrainReviewPage.swift
//  leanring-buddy
//
//  Brain → Review: the pages Wisp filed on its own (from conversations,
//  imports, the inbox, screen activity or its tools) that the user hasn't
//  checked yet, newest first. For each: "Looks right", fix its tags, move it
//  to another kind, open it, or undo the change that put it there.
//
//  Fixes go through `BrainStore.savePageEditedByUser`, so they are the user's
//  own edits — trusted, versioned, and undoable from Brain → Log — and the
//  page counts as reviewed afterwards. Which pages are waiting is decided by
//  `BrainReviewPlanner` (pure).
//

import SwiftUI

struct BrainReviewPage: View {
    @ObservedObject private var brainStore = BrainStore.shared
    @ObservedObject private var reviewStore = BrainReviewStore.shared

    /// The page whose tags are being edited inline, and the text so far.
    @State private var tagEditingSlug: String?
    @State private var tagEditingText = ""
    /// One line under the header about the last action ("Moved to People").
    @State private var feedbackMessage: String?

    var body: some View {
        // Read both published values so the list refreshes on either change.
        let _ = reviewStore.state
        let reviewItems = reviewStore.currentItems()
        VStack(spacing: 0) {
            header(itemCount: reviewItems.count, reviewItems: reviewItems)
            Divider()
            if reviewItems.isEmpty {
                ContentUnavailableView {
                    Label("All caught up", systemImage: "checkmark.seal")
                } description: {
                    Text("Pages Wisp files on its own from your chats, imports and inbox show up here for a quick check.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(reviewItems) { reviewItem in
                            if let page = brainStore.page(withSlug: reviewItem.slug) {
                                reviewRow(reviewItem: reviewItem, page: page)
                            }
                        }
                    }
                    .padding(.horizontal, WispSpacing.xxl)
                    .padding(.vertical, WispSpacing.xl)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(WispColor.windowBackground)
    }

    // MARK: - Header

    private func header(itemCount: Int, reviewItems: [BrainReviewItem]) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(itemCount == 0 ? "Nothing to review" : "\(itemCount) \(itemCount == 1 ? "page" : "pages") to review")
                    .font(.headline)
                    .foregroundStyle(WispColor.textPrimary)
                Text(feedbackMessage ?? "Filed by Wisp in the last \(BrainReviewPlanner.reviewWindowDays) days. Your fixes count as your own edits.")
                    .font(.caption)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if itemCount > 0 {
                Button("Mark All Reviewed", systemImage: "checkmark.circle") {
                    reviewStore.markAllReviewed(reviewItems)
                    feedbackMessage = "Marked \(itemCount) \(itemCount == 1 ? "page" : "pages") reviewed."
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .pointerCursor()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Row

    private func reviewRow(reviewItem: BrainReviewItem, page: BrainPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: page.kind.symbolName)
                    .foregroundStyle(BrainKindStyle.color(for: page.kind))
                Button {
                    BrainNavigator.openPageInWindow(slug: page.slug)
                } label: {
                    Text(page.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(WispColor.textPrimary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Open this page")
                BrainChip(text: page.kind.displayName, tint: BrainKindStyle.color(for: page.kind))
                if reviewItem.wasCreatedByAgent {
                    BrainChip(text: "New", symbolName: "sparkle", tint: WispColor.intelligence)
                }
                Spacer(minLength: 8)
                Text(reviewItem.latestChangeDate.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }

            if !page.summary.isEmpty {
                Text(page.summary)
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(2)
            }

            Label(provenanceLine(for: reviewItem), systemImage: BrainOriginStyle.symbolName(for: reviewItem.latestOrigin))
                .font(.caption)
                .foregroundStyle(WispColor.textTertiary)
                .lineLimit(2)

            if tagEditingSlug == page.slug {
                tagEditor(for: page)
            } else if !page.tags.isEmpty {
                BrainFlowLayout {
                    ForEach(page.tags, id: \.self) { tag in
                        BrainChip(text: "#\(tag)")
                    }
                }
            }

            actionBar(reviewItem: reviewItem, page: page)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                .fill(WispColor.textPrimary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
        )
    }

    private func provenanceLine(for reviewItem: BrainReviewItem) -> String {
        var lineParts = [
            "\(BrainOriginStyle.displayName(for: reviewItem.latestOrigin)) · \(BrainOriginStyle.trustLabel(for: reviewItem.latestTrust))"
        ]
        if let firstDescription = reviewItem.latestChangeDescriptions.first {
            lineParts.append(firstDescription)
        }
        if reviewItem.unreviewedChangeCount > 1 {
            lineParts.append("\(reviewItem.unreviewedChangeCount) changes")
        }
        return lineParts.joined(separator: " · ")
    }

    private func actionBar(reviewItem: BrainReviewItem, page: BrainPage) -> some View {
        HStack(spacing: 8) {
            Button("Looks Right", systemImage: "checkmark") {
                reviewStore.markReviewed(slug: page.slug, through: reviewItem.latestChangeDate)
                feedbackMessage = "\(page.title) marked reviewed."
            }
            .buttonStyle(WispPillButtonStyle())
            .pointerCursor()

            Button("Tags", systemImage: "tag") {
                tagEditingSlug = page.slug
                tagEditingText = page.tags.joined(separator: ", ")
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .pointerCursor()
            .help("Fix this page's tags")

            if page.kind != .me {
                Menu {
                    ForEach(BrainKindStyle.kindsForNewPage.filter { $0 != page.kind }, id: \.self) { newKind in
                        Button {
                            move(page: page, toKind: newKind)
                        } label: {
                            Label(newKind.pluralDisplayName, systemImage: newKind.symbolName)
                        }
                    }
                } label: {
                    Label("Move to", systemImage: "folder")
                }
                .menuStyle(.button)
                .fixedSize()
                .pointerCursor()
                .help("File this page under another kind")
            }

            Spacer(minLength: 8)

            Button("Undo", systemImage: "arrow.uturn.backward") {
                undoLatestChange(of: reviewItem, page: page)
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .pointerCursor()
            .help("Undo the change that put this here (the whole batch, as in Brain → Log)")
        }
    }

    private func tagEditor(for page: BrainPage) -> some View {
        HStack(spacing: 8) {
            TextField("Tags, separated by commas", text: $tagEditingText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveTags(for: page) }
            Button("Save") { saveTags(for: page) }
                .buttonStyle(WispPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
            Button("Cancel") { tagEditingSlug = nil }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .keyboardShortcut(.cancelAction)
                .pointerCursor()
        }
    }

    // MARK: - Actions

    private func saveTags(for page: BrainPage) {
        var editedPage = page
        editedPage.tags = BrainReviewPlanner.parsedTags(from: tagEditingText)
        tagEditingSlug = nil
        guard editedPage.tags != page.tags else {
            reviewStore.markReviewed(slug: page.slug)
            feedbackMessage = "\(page.title) marked reviewed."
            return
        }
        brainStore.savePageEditedByUser(editedPage)
        reviewStore.markReviewed(slug: page.slug)
        feedbackMessage = "Updated the tags on \(page.title)."
    }

    /// Changing kind moves the file to that kind's folder (a new slug), the
    /// same way renaming does in the page editor.
    private func move(page: BrainPage, toKind newKind: BrainPageKind) {
        let newSlug = BrainSlug.make(title: page.title, kind: newKind)
        guard BrainSlug.isSafe(newSlug) else {
            feedbackMessage = "Couldn't move \(page.title): its title can't be a file name."
            return
        }
        guard brainStore.page(withSlug: newSlug) == nil else {
            feedbackMessage = "There's already a \(newKind.displayName.lowercased()) called \(page.title) — merge them in Health."
            return
        }
        var movedPage = page
        movedPage.slug = newSlug
        movedPage.kind = newKind
        brainStore.savePageEditedByUser(movedPage, previousSlug: page.slug)
        BrainNavigator.shared.pageWasRenamed(fromSlug: page.slug, toSlug: newSlug)
        reviewStore.markReviewed(slug: newSlug)
        feedbackMessage = "Moved \(page.title) to \(newKind.pluralDisplayName)."
    }

    private func undoLatestChange(of reviewItem: BrainReviewItem, page: BrainPage) {
        switch brainStore.undo(changeID: reviewItem.latestChangeID) {
        case .undone:
            feedbackMessage = "Undid the change to \(page.title)."
        case .conflicted(let pageTitles):
            feedbackMessage = "\(pageTitles.joined(separator: ", ")) changed since — undo it from Brain → Log."
        case .alreadyUndone:
            feedbackMessage = "That change was already undone."
        case .notFound:
            feedbackMessage = "That change is no longer in the log."
        }
    }
}
