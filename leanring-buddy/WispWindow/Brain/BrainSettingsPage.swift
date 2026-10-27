//
//  BrainSettingsPage.swift
//  leanring-buddy
//
//  Brain → Settings: every switch the brain has (`BrainPreferences`), each
//  next to what it does and, where there is one, its live status — the last
//  conversation digest, today's screen-activity recording, the vault folder.
//
//  Screen activity is off by default and explained plainly before it can be
//  turned on: what is recorded (app, window title, site), what never is
//  (screenshots; excluded apps and sites), and that it stays on this Mac.
//
//  This page also took over the old History → Memory page's conversation
//  history card (saved exchanges, Clear), and shows the legacy memory.md facts
//  only while the brain is off — the one time Wisp still reads that file.
//

import AppKit
import SwiftUI

struct BrainSettingsPage: View {
    @ObservedObject private var brainPreferences = BrainPreferences.shared
    @ObservedObject private var brainStore = BrainStore.shared
    @ObservedObject private var conversationDigester = BrainConversationDigester.shared
    @ObservedObject private var activityRecorder = BrainActivityRecorder.shared
    @ObservedObject private var memoryStore = MemoryStore.shared

    @State private var isConfirmingDeleteActivity = false
    @State private var newExcludedSiteText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brainCard
                conversationsCard
                inboxCard
                screenActivityCard
                vaultCard
                ConversationHistorySettingsCard()
                if !brainPreferences.isBrainEnabled && !memoryStore.facts.isEmpty {
                    LegacyMemoryFactsCard()
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(WispColor.windowBackground)
    }

    // MARK: - Brain

    private var brainCard: some View {
        DashboardCard(title: "Brain") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    title: "Keep a brain",
                    detail: "Wisp keeps a personal wiki of what it learns about you and your work — people, projects, topics — as markdown pages on this Mac. Off, nothing is read from it or written to it."
                ) {
                    Toggle("Keep a brain", isOn: $brainPreferences.isBrainEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
                Divider()
                SettingRow(
                    title: "Use it in answers",
                    detail: "Before each question, the few pages that matter are included, so \"what did Sarah say about Atlas?\" just works."
                ) {
                    Toggle("Use it in answers", isOn: $brainPreferences.isPromptContextEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!brainPreferences.isBrainEnabled)
                        .pointerCursor(isEnabled: brainPreferences.isBrainEnabled)
                }
            }
        }
    }

    // MARK: - Conversations

    private var conversationsCard: some View {
        DashboardCard(title: "Conversations") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    title: "Learn from conversations",
                    detail: "When a conversation winds down, Wisp files the lasting facts from it — not the chatter — into your pages. Every change shows in the Log and can be undone."
                ) {
                    Toggle("Learn from conversations", isOn: $brainPreferences.isConversationDigestEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!brainPreferences.isBrainEnabled)
                        .pointerCursor(isEnabled: brainPreferences.isBrainEnabled)
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversationDigester.isDigesting
                             ? "Reading recent conversations…"
                             : "Last digest \(BrainRelativeTime.description(for: conversationDigester.lastDigestDate))")
                            .font(.callout)
                            .foregroundStyle(WispColor.textSecondary)
                        if let lastDigestSummary = conversationDigester.lastDigestSummary, !conversationDigester.isDigesting {
                            Text(lastDigestSummary)
                                .font(.caption)
                                .foregroundStyle(WispColor.textTertiary)
                        }
                    }
                    Spacer()
                    if conversationDigester.isDigesting {
                        ProgressView().controlSize(.small)
                    }
                    Button("Digest Now") { conversationDigester.digestNow() }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .disabled(!canDigestConversations)
                        .pointerCursor(isEnabled: canDigestConversations)
                        .help("File what's worth keeping from finished conversations right away")
                }
            }
        }
    }

    private var canDigestConversations: Bool {
        brainPreferences.isBrainEnabled && brainPreferences.isConversationDigestEnabled && !conversationDigester.isDigesting
    }

    // MARK: - Inbox

    private var inboxCard: some View {
        DashboardCard(title: "Inbox folder") {
            SettingRow(
                title: "Read files dropped in the inbox",
                detail: "Anything you put in the vault's raw/inbox folder — from Finder, a script, a share sheet — is read automatically, then moved to raw/ingested."
            ) {
                HStack(spacing: 8) {
                    Button("Open") {
                        brainStore.ensureVaultExists()
                        NSWorkspace.shared.open(brainStore.inboxURL)
                    }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .pointerCursor()
                    Toggle("Read files dropped in the inbox", isOn: $brainPreferences.isInboxWatchingEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!brainPreferences.isBrainEnabled)
                        .pointerCursor(isEnabled: brainPreferences.isBrainEnabled)
                }
            }
        }
    }

    // MARK: - Screen activity

    private var screenActivityCard: some View {
        DashboardCard(title: "Screen activity") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    title: "Remember what I work on",
                    detail: "Once a minute while you're at the Mac, Wisp notes the app in front, its window title and, in Chrome or Safari, the site. Once a day it turns that into lines like \"~2h on the Atlas spec\" on your project pages."
                ) {
                    Toggle("Remember what I work on", isOn: $brainPreferences.isActivityRecordingEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!brainPreferences.isBrainEnabled)
                        .pointerCursor(isEnabled: brainPreferences.isBrainEnabled)
                }

                VStack(alignment: .leading, spacing: 5) {
                    privacyPoint(symbolName: "camera.metering.none", text: "Never takes screenshots.")
                    privacyPoint(symbolName: "lock.shield", text: "Skips password managers, banking and private sites, Chrome Incognito windows, and anything you exclude below.")
                    privacyPoint(symbolName: "eye.slash", text: "Safari Private Browsing windows can't be told apart from normal ones — add sensitive sites below, or pause recording first.")
                    privacyPoint(symbolName: "phone.down", text: "Pauses while you're on a call or your camera is on, and when you step away.")
                    privacyPoint(symbolName: "desktopcomputer", text: "Stays on this Mac — the daily summary is always written by the local model — and is deleted after \(BrainActivityRecorder.retentionDays) days.")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: WispRadius.small, style: .continuous)
                        .fill(WispColor.surface1)
                )

                Divider()
                SettingRow(
                    title: "Also keep a little screen text",
                    detail: "Saves up to a few lines of text read from the screen with each note, so summaries can tell which document or ticket you were in. Off by default."
                ) {
                    Toggle("Also keep a little screen text", isOn: $brainPreferences.isActivityTextCaptureEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!brainPreferences.isActivityRecordingEnabled || !brainPreferences.isBrainEnabled)
                        .pointerCursor(isEnabled: brainPreferences.isActivityRecordingEnabled && brainPreferences.isBrainEnabled)
                }

                if brainPreferences.isActivityRecordingEnabled {
                    Divider()
                    todayActivityStatus
                }

                Divider()
                excludedAppsEditor
                Divider()
                excludedSitesEditor

                Divider()
                HStack(spacing: 8) {
                    Button("Allow Browser Access…") { activityRecorder.requestBrowserAccess() }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .disabled(!brainPreferences.isActivityRecordingEnabled)
                        .pointerCursor(isEnabled: brainPreferences.isActivityRecordingEnabled)
                        .help("macOS asks once per browser before Wisp can read the front tab's address")
                    Spacer()
                    Button("Delete Recorded Activity…", role: .destructive) { isConfirmingDeleteActivity = true }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .pointerCursor()
                }
            }
        }
        .confirmationDialog("Delete recorded activity?", isPresented: $isConfirmingDeleteActivity) {
            Button("Delete Activity", role: .destructive) { activityRecorder.deleteRecordedActivity() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every activity log on this Mac. Lines already in your pages stay.")
        }
    }

    private func privacyPoint(symbolName: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var todayActivityStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(activityRecorder.isRecording ? WispColor.success : WispColor.textTertiary)
                    .frame(width: 7, height: 7)
                Text(activityRecordingStatusText)
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                Spacer()
                if activityRecorder.isDigesting {
                    ProgressView().controlSize(.small)
                }
                Button("Summarize Today") { activityRecorder.digestToday() }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .disabled(activityRecorder.todaySampleCount == 0 || activityRecorder.isDigesting)
                    .pointerCursor(isEnabled: activityRecorder.todaySampleCount > 0 && !activityRecorder.isDigesting)
                    .help("Write today's activity into your pages now instead of tonight")
            }
            if let lastDigestSummary = activityRecorder.lastDigestSummary {
                Text("Last summary \(BrainRelativeTime.description(for: activityRecorder.lastDigestDate)): \(lastDigestSummary)")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }
            if !activityRecorder.todaySummary.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(activityRecorder.todaySummary.prefix(8)) { summaryRow in
                        HStack(spacing: 8) {
                            Image(systemName: summaryRow.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(WispColor.textSecondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(summaryRow.label)
                                    .font(.callout)
                                    .foregroundStyle(WispColor.textPrimary)
                                    .lineLimit(1)
                                if !summaryRow.detail.isEmpty {
                                    Text(summaryRow.detail)
                                        .font(.caption)
                                        .foregroundStyle(WispColor.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 6)
                            Text(summaryRow.formattedDuration)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(WispColor.textSecondary)
                        }
                    }
                }
                .padding(.leading, 15)
            }
        }
    }

    private var activityRecordingStatusText: String {
        let sampleCount = activityRecorder.todaySampleCount
        let sampleSummary = sampleCount == 0
            ? "nothing noted yet today"
            : "\(sampleCount) \(sampleCount == 1 ? "minute" : "minutes") noted today"
        return (activityRecorder.isRecording ? "Recording — " : "Paused — ") + sampleSummary
    }

    private var excludedAppsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Never record these apps")
                        .font(.body.weight(.medium))
                        .foregroundStyle(WispColor.textPrimary)
                    Text("On top of the built-in list (password managers and the like).")
                        .font(.caption)
                        .foregroundStyle(WispColor.textSecondary)
                }
                Spacer()
                Menu("Add App") {
                    let pickableApps = runningAppsNotYetExcluded
                    if pickableApps.isEmpty {
                        Text("Every open app is already excluded")
                    }
                    ForEach(pickableApps, id: \.bundleIdentifier) { runningApp in
                        Button {
                            brainPreferences.activityExcludedBundleIdentifiers.append(runningApp.bundleIdentifier)
                        } label: {
                            if let appIcon = runningApp.icon {
                                Label {
                                    Text(runningApp.name)
                                } icon: {
                                    Image(nsImage: appIcon)
                                }
                            } else {
                                Text(runningApp.name)
                            }
                        }
                    }
                }
                .fixedSize()
                .pointerCursor()
                .help("Pick from the apps that are open now")
            }
            if brainPreferences.activityExcludedBundleIdentifiers.isEmpty {
                Text("None added.")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            } else {
                BrainFlowLayout {
                    ForEach(brainPreferences.activityExcludedBundleIdentifiers, id: \.self) { excludedBundleIdentifier in
                        RemovableExclusionChip(text: Self.appName(forBundleIdentifier: excludedBundleIdentifier)) {
                            brainPreferences.activityExcludedBundleIdentifiers.removeAll { $0 == excludedBundleIdentifier }
                        }
                        .help(excludedBundleIdentifier)
                    }
                }
            }
        }
    }

    private struct PickableRunningApp {
        let bundleIdentifier: String
        let name: String
        let icon: NSImage?
    }

    private var runningAppsNotYetExcluded: [PickableRunningApp] {
        let alreadyExcluded = Set(brainPreferences.activityExcludedBundleIdentifiers.map { $0.lowercased() })
        let ownBundleIdentifier = Bundle.main.bundleIdentifier?.lowercased()
        var seenBundleIdentifiers = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { runningApplication -> PickableRunningApp? in
                guard let bundleIdentifier = runningApplication.bundleIdentifier else { return nil }
                let lowercasedBundleIdentifier = bundleIdentifier.lowercased()
                guard !alreadyExcluded.contains(lowercasedBundleIdentifier),
                      lowercasedBundleIdentifier != ownBundleIdentifier,
                      seenBundleIdentifiers.insert(lowercasedBundleIdentifier).inserted else { return nil }
                let icon = runningApplication.icon.map { originalIcon -> NSImage in
                    let smallIcon = originalIcon.copy() as? NSImage ?? originalIcon
                    smallIcon.size = NSSize(width: 16, height: 16)
                    return smallIcon
                }
                return PickableRunningApp(
                    bundleIdentifier: bundleIdentifier,
                    name: runningApplication.localizedName ?? bundleIdentifier,
                    icon: icon
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "com.tinyspeck.slackmacgap" → "Slack", when the app is installed.
    private static func appName(forBundleIdentifier bundleIdentifier: String) -> String {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return FileManager.default.displayName(atPath: applicationURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private var excludedSitesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Never record these sites")
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                Text("A site covers its subdomains too. Banking and private sites are already skipped.")
                    .font(.caption)
                    .foregroundStyle(WispColor.textSecondary)
            }
            HStack(spacing: 8) {
                TextField("example.com", text: $newExcludedSiteText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addExcludedSite)
                Button("Add", action: addExcludedSite)
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .disabled(normalizedNewExcludedSite.isEmpty)
                    .pointerCursor(isEnabled: !normalizedNewExcludedSite.isEmpty)
            }
            if !brainPreferences.activityExcludedDomains.isEmpty {
                BrainFlowLayout {
                    ForEach(brainPreferences.activityExcludedDomains, id: \.self) { excludedDomain in
                        RemovableExclusionChip(text: excludedDomain) {
                            brainPreferences.activityExcludedDomains.removeAll { $0 == excludedDomain }
                        }
                    }
                }
            }
        }
    }

    private var normalizedNewExcludedSite: String {
        BrainActivityExclusionPolicy.normalizedDomain(newExcludedSiteText)
    }

    private func addExcludedSite() {
        let excludedDomain = normalizedNewExcludedSite
        guard !excludedDomain.isEmpty else { return }
        if !brainPreferences.activityExcludedDomains.contains(excludedDomain) {
            brainPreferences.activityExcludedDomains.append(excludedDomain)
        }
        newExcludedSiteText = ""
    }

    // MARK: - Vault

    private var vaultCard: some View {
        DashboardCard(title: "Vault") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your brain is a plain markdown folder, a valid Obsidian vault. Edits made elsewhere apply right away.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(brainStore.vaultURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(WispFont.mono)
                    .foregroundStyle(WispColor.textPrimary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Reveal in Finder", systemImage: "folder") { brainStore.revealVaultInFinder() }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .pointerCursor()
                    if brainStore.isObsidianInstalled {
                        Button("Open in Obsidian", systemImage: "arrow.up.forward.app") { brainStore.openInObsidian() }
                            .buttonStyle(WispPillButtonStyle(isProminent: false))
                            .pointerCursor()
                    }
                    Button("Edit Schema", systemImage: "list.bullet.rectangle") {
                        brainStore.ensureVaultExists()
                        NSWorkspace.shared.open(brainStore.schemaFileURL)
                    }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .pointerCursor()
                    .help("SCHEMA.md: the conventions Wisp follows when it writes pages")
                }
            }
        }
    }
}

// MARK: - Exclusion chip

private struct RemovableExclusionChip: View {
    let text: String
    let onRemove: () -> Void

    @State private var isRemoveButtonHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
                .foregroundStyle(WispColor.textPrimary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isRemoveButtonHovered ? WispColor.destructiveText : WispColor.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering in isRemoveButtonHovered = hovering }
            .help("Record \(text) again")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(WispColor.surface2))
    }
}

// MARK: - Conversation history (moved from the old Memory page)

/// The saved recent conversation (`ConversationHistoryStore`): what is kept,
/// and the one action a privacy-minded user needs — clear it.
struct ConversationHistorySettingsCard: View {
    @ObservedObject private var conversationHistoryStore = ConversationHistoryStore.shared

    @State private var isConfirmingClearConversationHistory = false

    var body: some View {
        DashboardCard(title: "Conversation history") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The last \(ConversationHistoryCodec.maximumPersistedTurnCount) exchanges are saved on this Mac, text only, so Wisp can pick up where you left off. Only the last \(resumeWindowDescription) carry into a new session.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(savedHistorySummary)
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)

                HStack(spacing: 8) {
                    Button("Clear Conversation History…", role: .destructive) { isConfirmingClearConversationHistory = true }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .disabled(conversationHistoryStore.persistedTurns.isEmpty)
                        .pointerCursor(isEnabled: !conversationHistoryStore.persistedTurns.isEmpty)
                    Button("Reveal in Finder") { conversationHistoryStore.revealHistoryFileInFinder() }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .pointerCursor()
                    Spacer()
                }
            }
        }
        .confirmationDialog(
            "Clear conversation history?",
            isPresented: $isConfirmingClearConversationHistory
        ) {
            Button("Clear History", role: .destructive) { conversationHistoryStore.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Forgets the current conversation and deletes the saved copy. Brain pages are unaffected.")
        }
    }

    private var savedHistorySummary: String {
        let savedTurns = conversationHistoryStore.persistedTurns
        guard let newestTurn = savedTurns.last else { return "Nothing saved." }
        let exchangeWord = savedTurns.count == 1 ? "exchange" : "exchanges"
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .full
        let newestTurnRelativeTime = relativeFormatter.localizedString(for: newestTurn.startedAt, relativeTo: Date())
        return "\(savedTurns.count) saved \(exchangeWord) · latest \(newestTurnRelativeTime)"
    }

    private var resumeWindowDescription: String {
        let resumeWindowHours = Int(ConversationHistoryCodec.maximumResumedTurnAge / 3600)
        return resumeWindowHours == 1 ? "hour" : "\(resumeWindowHours) hours"
    }
}

// MARK: - Legacy memory.md (brain off only)

/// The old `~/.wisp/memory.md` facts, with a delete button each. Only shown
/// while the brain is off: with it on, those facts live on the Me page and
/// the file isn't read.
struct LegacyMemoryFactsCard: View {
    @ObservedObject private var memoryStore = MemoryStore.shared

    var body: some View {
        DashboardCard(title: "Remembered facts (memory.md)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("With the brain off, Wisp falls back to the facts in ~/.wisp/memory.md.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                ForEach(Array(memoryStore.facts.enumerated()), id: \.offset) { _, fact in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(WispColor.accentText)
                        Text(fact)
                            .font(.callout)
                            .foregroundStyle(WispColor.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button {
                            memoryStore.removeFact(fact)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(WispColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("Forget this")
                    }
                }
                Button("Reveal memory.md in Finder") { memoryStore.revealMemoryFileInFinder() }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .pointerCursor()
            }
        }
        .onAppear { memoryStore.reloadIfFileChanged() }
    }
}
