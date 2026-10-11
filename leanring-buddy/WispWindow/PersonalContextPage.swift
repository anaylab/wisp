//
//  PersonalContextPage.swift
//  leanring-buddy
//
//  Connections → Your Data: where personal context is switched on and off,
//  where each source's macOS permission is granted (the only place that asks
//  — a question never does), and a search box to see exactly what Wisp would
//  find for a question.
//

import AppKit
import SwiftUI

struct PersonalContextPage: View {
    @ObservedObject private var personalContextStore = PersonalContextStore.shared

    @State private var trialQueryText = ""
    @State private var trialHits: [PersonalContextHit]?
    @State private var isTrialSearchRunning = false
    @State private var sourceKindBeingGranted: PersonalContextSourceKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                overviewCard
                sourcesCard
                trialSearchCard
            }
            .padding(16)
        }
        .background(WispColor.windowBackground)
        .onAppear { personalContextStore.refreshAvailability() }
        // Coming back from System Settings (or opening Mail) changes what's searchable.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            personalContextStore.refreshAvailability()
        }
    }

    // MARK: - Overview

    private var overviewCard: some View {
        DashboardCard(title: "Your data in answers") {
            SettingRow(
                title: "Use your data to answer",
                detail: "Ask \"when is mom's flight?\" or \"what's my dentist's address?\" and Wisp searches your calendar, reminders, contacts and documents on this Mac — and Mail, Notes or Messages when you mention them. Searched only when a question is about your things, never uploaded by Wisp."
            ) {
                Toggle("", isOn: $personalContextStore.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
            Divider()
            SettingRow(
                title: "Also with cloud models",
                detail: "Off: with Claude, GPT or Gemini selected, your data stays out of the request. On: what Wisp finds is sent to that provider along with your question."
            ) {
                Toggle("", isOn: $personalContextStore.allowsCloudModels)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
                    .disabled(!personalContextStore.isEnabled)
            }
        }
    }

    // MARK: - Sources

    private var sourcesCard: some View {
        DashboardCard(title: "Sources") {
            ForEach(PersonalContextSourceKind.allCases) { sourceKind in
                if sourceKind != PersonalContextSourceKind.allCases.first { Divider() }
                sourceRow(for: sourceKind)
            }
            Text("Mail and Notes are searched only while they're open, and only when your question mentions them — Wisp never opens them for a search. Messages needs Full Disk Access, which only System Settings can grant.")
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .disabled(!personalContextStore.isEnabled)
        .opacity(personalContextStore.isEnabled ? 1 : 0.55)
    }

    private func sourceRow(for sourceKind: PersonalContextSourceKind) -> some View {
        let availability = personalContextStore.availabilityBySourceKind[sourceKind] ?? .needsPermission
        let isSourceEnabled = personalContextStore.enabledSourceKinds.contains(sourceKind)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: sourceKind.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceKind.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(availability.isSearchable ? WispColor.success : WispColor.textTertiary)
                        .frame(width: 6, height: 6)
                    Text(availability.statusText(for: sourceKind))
                        .font(.callout)
                        .foregroundStyle(WispColor.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if isSourceEnabled {
                accessButton(for: sourceKind, availability: availability)
            }
            Toggle("", isOn: Binding(
                get: { isSourceEnabled },
                set: { personalContextStore.setSource(sourceKind, isEnabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .pointerCursor()
        }
    }

    @ViewBuilder
    private func accessButton(for sourceKind: PersonalContextSourceKind, availability: PersonalContextSourceAvailability) -> some View {
        switch availability {
        case .needsPermission:
            Button(sourceKindBeingGranted == sourceKind ? "Asking…" : "Allow") {
                sourceKindBeingGranted = sourceKind
                Task {
                    await personalContextStore.requestAccess(for: sourceKind)
                    sourceKindBeingGranted = nil
                }
            }
            .buttonStyle(.bordered)
            .disabled(sourceKindBeingGranted != nil)
            .pointerCursor()
        case .denied:
            Button("Open System Settings") { openPrivacySettings(for: sourceKind) }
                .buttonStyle(.bordered)
                .pointerCursor()
        case .needsFullDiskAccess:
            Button("Open Full Disk Access") { openPrivacySettings(for: sourceKind) }
                .buttonStyle(.bordered)
                .pointerCursor()
        case .available, .appNotRunning:
            EmptyView()
        }
    }

    private func openPrivacySettings(for sourceKind: PersonalContextSourceKind) {
        let privacyAnchor: String
        switch sourceKind {
        case .calendar: privacyAnchor = "Privacy_Calendars"
        case .reminders: privacyAnchor = "Privacy_Reminders"
        case .contacts: privacyAnchor = "Privacy_Contacts"
        case .mail, .notes: privacyAnchor = "Privacy_Automation"
        case .messages, .files: privacyAnchor = "Privacy_AllFiles"
        }
        if let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyAnchor)") {
            NSWorkspace.shared.open(privacySettingsURL)
        }
    }

    // MARK: - Trial search

    private var trialSearchCard: some View {
        DashboardCard(title: "Try a search") {
            Text("See what Wisp would find on this Mac. Every enabled source is searched, Mail, Notes and Messages included.")
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
            HStack(spacing: 8) {
                TextField("flight denver, dentist address, invoice acme…", text: $trialQueryText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runTrialSearch() }
                Button(isTrialSearchRunning ? "Searching…" : "Search") { runTrialSearch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTrialSearchRunning || trialQueryText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .pointerCursor()
            }
            if let trialHits {
                if trialHits.isEmpty {
                    Text("Nothing matched.")
                        .font(.callout)
                        .foregroundStyle(WispColor.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(trialHits) { trialHit in
                            trialHitRow(trialHit)
                        }
                    }
                }
            }
        }
        .disabled(!personalContextStore.isEnabled)
    }

    private func trialHitRow(_ trialHit: PersonalContextHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: trialHit.sourceKind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WispColor.textSecondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(trialHit.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(2)
                if !trialHit.detail.isEmpty {
                    Text(trialHit.detail)
                        .font(.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .lineLimit(1)
                }
                if let excerpt = trialHit.excerpt {
                    Text(PersonalContextPromptBlock.singleLine(excerpt, limit: 200))
                        .font(.callout)
                        .foregroundStyle(WispColor.textTertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func runTrialSearch() {
        let queryText = trialQueryText.trimmingCharacters(in: .whitespaces)
        guard !queryText.isEmpty, !isTrialSearchRunning else { return }
        isTrialSearchRunning = true
        Task {
            trialHits = await personalContextStore.search(queryText: queryText, onlySourceKinds: nil, maximumHitCount: 10) ?? []
            isTrialSearchRunning = false
        }
    }
}
