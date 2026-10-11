//
//  BrainPageEditorView.swift
//  leanring-buddy
//
//  One brain page, edited as the raw markdown file it is — frontmatter and
//  all — with an optional live preview beside it. Save hands the parsed page
//  to `BrainStore.savePageEditedByUser`, which versions it (undoable from the
//  Log) and bypasses the planner: the user may do anything to their own brain.
//
//  Changing the title (or the kind) moves the page to a new file name, since a
//  slug comes from both; the store deletes the old file after writing the new
//  one, and the reader's history follows the rename. The Me page always stays
//  `me.md`.
//

import SwiftUI

struct BrainPageEditorView: View {
    let originalPage: BrainPage

    @ObservedObject private var brainStore = BrainStore.shared
    @ObservedObject private var navigator = BrainNavigator.shared

    @State private var draftMarkdown: String
    @State private var isPreviewVisible = false
    @State private var saveErrorMessage: String?
    @State private var isConfirmingDiscard = false

    init(originalPage: BrainPage) {
        self.originalPage = originalPage
        _draftMarkdown = State(initialValue: BrainPageFormat.render(originalPage))
    }

    private var hasUnsavedChanges: Bool {
        draftMarkdown != BrainPageFormat.render(originalPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorBar
            Divider()
            if let saveErrorMessage {
                Label(saveErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(WispColor.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(WispColor.warning.opacity(0.10))
                Divider()
            }
            HStack(spacing: 0) {
                TextEditor(text: $draftMarkdown)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(WispColor.groupedCardBackground)
                if isPreviewVisible {
                    Divider()
                    ScrollView {
                        BrainMarkdownView(
                            markdown: BrainPageFormat.splitFrontmatter(draftMarkdown).body,
                            resolver: BrainLinkResolver(pages: brainStore.pages),
                            onOpenLink: { _ in }
                        )
                        .padding(20)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $isConfirmingDiscard) {
            Button("Discard Changes", role: .destructive) { navigator.isEditingSelectedPage = false }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var editorBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing \(originalPage.title)")
                    .font(.headline)
                    .foregroundStyle(WispColor.textPrimary)
                Text("Frontmatter first. Link pages with [[Title]]; ## starts a section.")
                    .font(.caption)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle(isOn: $isPreviewVisible) {
                Label("Preview", systemImage: "rectangle.split.2x1")
            }
            .toggleStyle(.button)
            .pointerCursor()
            .help("Show the rendered page beside the markdown")
            Button("Cancel") {
                if hasUnsavedChanges {
                    isConfirmingDiscard = true
                } else {
                    navigator.isEditingSelectedPage = false
                }
            }
            .keyboardShortcut(.cancelAction)
            .pointerCursor()
            Button("Save", action: save)
                .buttonStyle(WispPillButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
                .pointerCursor()
                .help("Save (⌘S)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func save() {
        var editedPage = BrainPageFormat.parse(markdown: draftMarkdown, slug: originalPage.slug)
        editedPage.createdDate = editedPage.createdDate ?? originalPage.createdDate

        if originalPage.slug == "me" {
            // There is exactly one Me page, and it lives at me.md.
            editedPage.slug = "me"
            editedPage.kind = .me
        } else if editedPage.kind == .me {
            saveErrorMessage = "Only one page can be your Me page — choose another kind."
            return
        } else {
            let titleChanged = BrainSlug.comparableName(editedPage.title) != BrainSlug.comparableName(originalPage.title)
            let kindChanged = editedPage.kind != originalPage.kind
            // A hand-made file with spaces or capitals in its name can't be
            // written back as-is; give it a proper slug on save.
            if titleChanged || kindChanged || !BrainSlug.isSafe(originalPage.slug) {
                let newSlug = BrainSlug.make(title: editedPage.title, kind: editedPage.kind)
                if newSlug != originalPage.slug {
                    if brainStore.pages.contains(where: { $0.slug == newSlug }) {
                        saveErrorMessage = "A page with that name already exists. Pick another title, or merge the two by hand."
                        return
                    }
                    editedPage.slug = newSlug
                }
            }
        }

        let previousSlug = editedPage.slug == originalPage.slug ? nil : originalPage.slug
        let saveResult = brainStore.savePageEditedByUser(editedPage, previousSlug: previousSlug)
        guard saveResult.didChangeAnything else {
            saveErrorMessage = "Couldn't save the page. Check that the title has some letters or numbers in it."
            return
        }
        saveErrorMessage = nil
        if let previousSlug {
            navigator.pageWasRenamed(fromSlug: previousSlug, toSlug: editedPage.slug)
        }
        navigator.isEditingSelectedPage = false
    }
}
