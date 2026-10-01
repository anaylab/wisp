//
//  BrainInboxPage.swift
//  leanring-buddy
//
//  Brain → Inbox: how things get into the brain on purpose. A big drop zone
//  takes files, folders, web links and plain text; buttons do the same for
//  people who'd rather pick (Add files…, Add link…, Paste text…). Everything
//  lands in `BrainIngestQueue`, whose jobs are listed underneath with their
//  progress, Cancel / Retry, and — once read — what changed and which pages.
//
//  A dropped folder is a notes import (`BrainNotesImporter.importFolder`), as
//  is "Choose folder…" in the Notes card; Apple Notes imports directly. Files
//  dropped into the vault's `raw/inbox/` from Finder are picked up too while
//  inbox watching is on.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrainInboxPage: View {
    @ObservedObject private var ingestQueue = BrainIngestQueue.shared
    @ObservedObject private var notesImporter = BrainNotesImporter.shared
    @ObservedObject private var brainPreferences = BrainPreferences.shared
    @ObservedObject private var brainStore = BrainStore.shared

    @State private var isDropTargeted = false
    @State private var isShowingAddLinkSheet = false
    @State private var isShowingPasteTextSheet = false
    /// One line under the drop zone about the last drop ("2 files added, 1 skipped").
    @State private var lastDropFeedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !brainPreferences.isBrainEnabled {
                    brainOffBanner
                }
                dropZone
                jobsSection
                notesImportCard
            }
            .padding(.horizontal, WispSpacing.xxl)
            .padding(.vertical, WispSpacing.xl)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(WispColor.windowBackground)
        .sheet(isPresented: $isShowingAddLinkSheet) {
            BrainAddLinkSheet { webPageURL in
                ingestQueue.enqueue(webPageURL: webPageURL)
            }
        }
        .sheet(isPresented: $isShowingPasteTextSheet) {
            BrainPasteTextSheet { pastedText, title in
                ingestQueue.enqueue(text: pastedText, title: title)
            }
        }
    }

    private var brainOffBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .foregroundStyle(WispColor.warningText)
            Text("The brain is off, so nothing added here will be read until you turn it back on.")
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
            Spacer(minLength: 8)
            Button("Turn On") { brainPreferences.isBrainEnabled = true }
                .buttonStyle(.bordered)
                .pointerCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous)
                .fill(WispColor.warning.opacity(0.10))
        )
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isDropTargeted ? WispColor.accentText : WispColor.textTertiary)
                .symbolEffect(.bounce, value: isDropTargeted)
            VStack(spacing: 4) {
                Text(isDropTargeted ? "Let go to add it" : "Drop anything worth remembering")
                    .font(WispFont.headline)
                    .foregroundStyle(WispColor.textPrimary)
                Text("Files (\(supportedExtensionsDescription)), folders of notes, web links or text. Wisp reads each one on this Mac and files what matters into your pages.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Add Files…", systemImage: "doc.badge.plus", action: chooseFilesToAdd)
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                Button("Add Link…", systemImage: "link.badge.plus") { isShowingAddLinkSheet = true }
                    .buttonStyle(.bordered)
                    .pointerCursor()
                Button("Paste Text…", systemImage: "doc.on.clipboard") { isShowingPasteTextSheet = true }
                    .buttonStyle(.bordered)
                    .pointerCursor()
            }
            .controlSize(.large)
            if let lastDropFeedback {
                Text(lastDropFeedback)
                    .font(.caption)
                    .foregroundStyle(WispColor.textSecondary)
                    .transition(.opacity)
            }
            HStack(spacing: 6) {
                Image(systemName: brainPreferences.isInboxWatchingEnabled ? "eye" : "eye.slash")
                    .font(.caption)
                Text(brainPreferences.isInboxWatchingEnabled
                     ? "Files you put in the inbox folder are read automatically."
                     : "Inbox folder watching is off (Brain → Settings).")
                    .font(.caption)
                Button("Open Inbox Folder") {
                    brainStore.ensureVaultExists()
                    NSWorkspace.shared.open(brainStore.inboxURL)
                }
                .buttonStyle(.link)
                .font(.caption)
                .pointerCursor()
            }
            .foregroundStyle(WispColor.textTertiary)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous)
                .fill(isDropTargeted ? WispColor.accentSubtle : WispColor.groupedCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? WispColor.accentText : WispColor.borderStrong,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [7, 5])
                )
        )
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var supportedExtensionsDescription: String {
        let commonExtensions = ["pdf", "md", "txt", "docx", "html"]
        let shownExtensions = commonExtensions.filter { BrainIngestQueue.supportedFileExtensions.contains($0) }
        return shownExtensions.map { $0.uppercased() }.joined(separator: ", ") + "…"
    }

    // MARK: - Adding

    private func chooseFilesToAdd() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Add to Brain"
        openPanel.prompt = "Add"
        openPanel.message = "Choose files for Wisp to read, or a folder of notes to import."
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = BrainIngestQueue.supportedFileExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        guard openPanel.runModal() == .OK else { return }
        addLocalItems(openPanel.urls)
    }

    /// Files go to the ingest queue, folders to the notes importer, anything
    /// unreadable is counted and reported rather than silently dropped.
    private func addLocalItems(_ itemURLs: [URL]) {
        var addedFileCount = 0
        var importedFolderCount = 0
        var skippedFileNames: [String] = []
        for itemURL in itemURLs {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                notesImporter.importFolder(itemURL)
                importedFolderCount += 1
            } else if BrainIngestQueue.supportedFileExtensions.contains(itemURL.pathExtension.lowercased()) {
                ingestQueue.enqueue(fileURL: itemURL)
                addedFileCount += 1
            } else {
                skippedFileNames.append(itemURL.lastPathComponent)
            }
        }
        var feedbackParts: [String] = []
        if addedFileCount > 0 { feedbackParts.append(addedFileCount == 1 ? "1 file added" : "\(addedFileCount) files added") }
        if importedFolderCount > 0 { feedbackParts.append(importedFolderCount == 1 ? "1 folder importing" : "\(importedFolderCount) folders importing") }
        if !skippedFileNames.isEmpty {
            feedbackParts.append("skipped \(skippedFileNames.prefix(3).joined(separator: ", ")) (can't read that type)")
        }
        withAnimation { lastDropFeedback = feedbackParts.isEmpty ? nil : feedbackParts.joined(separator: " · ") }
    }

    private func handleDrop(_ itemProviders: [NSItemProvider]) -> Bool {
        var handledAnyItem = false
        for itemProvider in itemProviders {
            if itemProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handledAnyItem = true
                _ = itemProvider.loadObject(ofClass: URL.self) { droppedURL, _ in
                    guard let droppedURL else { return }
                    Task { @MainActor in addLocalItems([droppedURL]) }
                }
            } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handledAnyItem = true
                _ = itemProvider.loadObject(ofClass: URL.self) { droppedURL, _ in
                    guard let droppedURL else { return }
                    Task { @MainActor in addDroppedWebLink(droppedURL) }
                }
            } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                handledAnyItem = true
                _ = itemProvider.loadObject(ofClass: String.self) { droppedText, _ in
                    guard let droppedText else { return }
                    Task { @MainActor in addDroppedText(droppedText) }
                }
            }
        }
        return handledAnyItem
    }

    private func addDroppedWebLink(_ droppedURL: URL) {
        guard let scheme = droppedURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            if droppedURL.isFileURL { addLocalItems([droppedURL]) }
            return
        }
        ingestQueue.enqueue(webPageURL: droppedURL)
        withAnimation { lastDropFeedback = "Reading \(droppedURL.host() ?? droppedURL.absoluteString)…" }
    }

    /// Dropped text that is just a link is treated as the link.
    private func addDroppedText(_ droppedText: String) {
        let trimmedText = droppedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        if !trimmedText.contains(" "), !trimmedText.contains("\n"),
           let possibleWebURL = URL(string: trimmedText),
           let scheme = possibleWebURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            addDroppedWebLink(possibleWebURL)
            return
        }
        let title = BrainPasteTextSheet.suggestedTitle(for: trimmedText)
        ingestQueue.enqueue(text: trimmedText, title: title)
        withAnimation { lastDropFeedback = "Added “\(title)”" }
    }

    // MARK: - Jobs

    @ViewBuilder
    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reading")
                    .font(.headline)
                    .foregroundStyle(WispColor.textPrimary)
                if ingestQueue.pendingJobCount > 0 {
                    BrainChip(text: "\(ingestQueue.pendingJobCount) in progress", tint: WispColor.accentText)
                }
                Spacer()
                if ingestQueue.jobs.contains(where: { $0.state.isFinal }) {
                    Button("Clear Finished") { ingestQueue.clearFinishedJobs() }
                        .buttonStyle(.link)
                        .pointerCursor()
                }
            }
            .padding(.leading, 2)

            if ingestQueue.jobs.isEmpty {
                Text("Nothing added this session. Whatever you add shows up here while Wisp reads it — one at a time, so your questions still get answered quickly.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(WispColor.groupedCardBackground)
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(ingestQueue.jobs.enumerated()), id: \.element.id) { jobIndex, job in
                        if jobIndex > 0 { Divider() }
                        BrainIngestJobRow(job: job)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(WispColor.groupedCardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Notes import

    private var notesImportCard: some View {
        DashboardCard(title: "Import notes") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bring in notes you already keep — an Obsidian vault, a folder of markdown or text files, a Bear or Notes export — or your Apple Notes directly. Originals are copied into the vault's raw/notes folder and never changed.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Choose Folder…", systemImage: "folder", action: chooseNotesFolder)
                        .buttonStyle(.bordered)
                        .pointerCursor()
                    Button("Import Apple Notes", systemImage: "note.text") { notesImporter.importAppleNotes() }
                        .buttonStyle(.bordered)
                        .disabled(notesImporter.isImporting)
                        .pointerCursor(isEnabled: !notesImporter.isImporting)
                        .help("Wisp asks macOS for permission to read Notes the first time")
                    if notesImporter.isImporting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let lastErrorMessage = notesImporter.lastErrorMessage {
                    Label(lastErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(WispColor.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !notesImporter.runs.isEmpty {
                    Divider()
                    ForEach(notesImporter.runs) { importRun in
                        notesImportRunRow(importRun)
                    }
                }
            }
        }
    }

    private func notesImportRunRow(_ importRun: BrainNotesImporter.ImportRun) -> some View {
        let handledFileCount = importRun.enqueuedFileCount + importRun.skippedFileCount
        let isStillCopying = !importRun.isFinished && handledFileCount < importRun.totalFileCount
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(importRun.sourceName, systemImage: importRun.isFinished ? "checkmark.circle" : "folder")
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                Spacer()
                Text(importRun.startedDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }
            if importRun.totalFileCount > 0 && isStillCopying {
                ProgressView(value: Double(handledFileCount), total: Double(importRun.totalFileCount))
                    .progressViewStyle(.linear)
            } else if importRun.totalFileCount == 0 && !importRun.isFinished {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(notesImportRunSummary(importRun))
                .font(.caption)
                .foregroundStyle(WispColor.textSecondary)
        }
    }

    private func notesImportRunSummary(_ importRun: BrainNotesImporter.ImportRun) -> String {
        if let statusMessage = importRun.statusMessage, importRun.isFinished || importRun.totalFileCount == 0 {
            return statusMessage.prefix(1).uppercased() + statusMessage.dropFirst()
        }
        if importRun.totalFileCount == 0 { return "Looking for notes…" }
        var summaryParts = ["\(importRun.enqueuedFileCount) of \(importRun.totalFileCount) notes queued for reading"]
        if importRun.skippedFileCount > 0 {
            summaryParts.append("\(importRun.skippedFileCount) skipped")
        }
        return summaryParts.joined(separator: " · ")
    }

    private func chooseNotesFolder() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Import Notes"
        openPanel.prompt = "Import"
        openPanel.message = "Choose a folder of notes — an Obsidian vault, markdown files or an export."
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let folderURL = openPanel.url else { return }
        notesImporter.importFolder(folderURL)
    }
}

// MARK: - Job row

private struct BrainIngestJobRow: View {
    let job: BrainIngestJob

    @ObservedObject private var ingestQueue = BrainIngestQueue.shared
    @ObservedObject private var brainStore = BrainStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: sourceSymbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(stateTint)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(WispColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(stateDescription)
                        .font(.caption)
                        .foregroundStyle(stateTint)
                }
                progressIndicator
                finishedDetails
            }
            actionButtons
        }
        .padding(.vertical, 10)
    }

    private var sourceSymbolName: String {
        switch job.source {
        case .file(let fileURL):
            return fileURL.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text"
        case .webPage: return "globe"
        case .text: return "text.alignleft"
        }
    }

    private var stateDescription: String {
        switch job.state {
        case .queued: return "Waiting"
        case .extractingText: return "Opening…"
        case .reading(let progress): return "Reading · \(Int((progress * 100).rounded()))%"
        case .merging: return "Filing into pages…"
        case .finished(_, let changeDescriptions, _):
            return changeDescriptions.isEmpty ? "Nothing new" : "Done"
        case .failed: return "Couldn't read"
        case .cancelled: return "Cancelled"
        }
    }

    private var stateTint: Color {
        switch job.state {
        case .finished: return WispColor.success
        case .failed: return WispColor.destructiveText
        case .cancelled: return WispColor.textTertiary
        case .queued: return WispColor.textSecondary
        default: return WispColor.intelligence
        }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        switch job.state {
        case .reading(let progress):
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(WispColor.intelligence)
        case .extractingText, .merging:
            ProgressView()
                .progressViewStyle(.linear)
                .tint(WispColor.intelligence)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var finishedDetails: some View {
        if case .finished(_, let changeDescriptions, let pageTitles) = job.state {
            if changeDescriptions.isEmpty {
                Text("Everything in it was already in your brain.")
                    .font(.caption)
                    .foregroundStyle(WispColor.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(changeDescriptions.prefix(6).enumerated()), id: \.offset) { _, changeDescription in
                        Text("• \(changeDescription)")
                            .font(.caption)
                            .foregroundStyle(WispColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if changeDescriptions.count > 6 {
                        Text("and \(changeDescriptions.count - 6) more — see Brain → Log")
                            .font(.caption)
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
            }
            if !pageTitles.isEmpty {
                let linkResolver = BrainLinkResolver(pages: brainStore.pages)
                BrainFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(pageTitles, id: \.self) { pageTitle in
                        let touchedPage = linkResolver.slug(forTarget: pageTitle)
                            .flatMap { touchedSlug in brainStore.pages.first { $0.slug == touchedSlug } }
                        if let touchedPage {
                            BrainPageLinkChip(title: touchedPage.title, kind: touchedPage.kind) {
                                BrainNavigator.openPageInWindow(slug: touchedPage.slug)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch job.state {
        case .failed, .cancelled:
            Button("Retry") { ingestQueue.retry(jobID: job.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
        case .finished:
            EmptyView()
        default:
            Button {
                ingestQueue.cancel(jobID: job.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(WispColor.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Stop reading this")
        }
    }
}

// MARK: - Sheets

struct BrainAddLinkSheet: View {
    let onAdd: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""

    init(onAdd: @escaping (URL) -> Void) {
        self.onAdd = onAdd
        // Start with a link already on the clipboard — the common case.
        let clipboardText = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _linkText = State(initialValue: Self.webURL(from: clipboardText) != nil ? clipboardText : "")
    }

    static func webURL(from text: String) -> URL? {
        var candidateText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateText.isEmpty, !candidateText.contains(" ") else { return nil }
        if !candidateText.lowercased().hasPrefix("http://") && !candidateText.lowercased().hasPrefix("https://") {
            guard candidateText.contains(".") else { return nil }
            candidateText = "https://" + candidateText
        }
        guard let candidateURL = URL(string: candidateText), candidateURL.host() != nil else { return nil }
        return candidateURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a link")
                .font(.title3.weight(.semibold))
            Text("Wisp fetches the page, reads it on this Mac and files what matters. Only the page's own address is contacted.")
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $linkText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addLink)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button("Add", action: addLink)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(Self.webURL(from: linkText) == nil)
                    .pointerCursor(isEnabled: Self.webURL(from: linkText) != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func addLink() {
        guard let webURL = Self.webURL(from: linkText) else { return }
        onAdd(webURL)
        dismiss()
    }
}

struct BrainPasteTextSheet: View {
    let onAdd: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pastedText: String
    @State private var title: String

    init(onAdd: @escaping (String, String) -> Void) {
        self.onAdd = onAdd
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        _pastedText = State(initialValue: clipboardText)
        _title = State(initialValue: clipboardText.isEmpty ? "" : Self.suggestedTitle(for: clipboardText))
    }

    /// The first line, shortened — a sensible name for the log and sources.
    static func suggestedTitle(for text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Pasted text"
        let withoutHeadingMarks = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- "))
        let shortenedTitle = String(withoutHeadingMarks.prefix(60))
        return shortenedTitle.isEmpty ? "Pasted text" : shortenedTitle
    }

    private var trimmedText: String {
        pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste text")
                .font(.title3.weight(.semibold))
            TextField("Title", text: $title, prompt: Text("What is it? (meeting notes, an email…)"))
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $pastedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: WispRadius.small, style: .continuous)
                        .fill(WispColor.groupedCardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WispRadius.small, style: .continuous)
                        .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
                )
                .frame(minHeight: 220)
            HStack {
                Text("\(trimmedText.count) characters")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button("Add") {
                    let finalTitle = title.trimmingCharacters(in: .whitespaces)
                    onAdd(trimmedText, finalTitle.isEmpty ? Self.suggestedTitle(for: trimmedText) : finalTitle)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedText.isEmpty)
                .pointerCursor(isEnabled: !trimmedText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
