//
//  DownloadConciergeViews.swift
//  leanring-buddy
//
//  What the download concierge looks like: the notch card ("Paper.pdf from
//  arxiv.org → ~/Documents/Papers/…" with File / Just brain / Ignore), the
//  report after a filing (with Undo), the flank badge for offers waiting
//  behind quiet mode, and the switch in Settings → Agent → Chrome Tabs.
//
//  The notch views sit on the island, so they use `WispColor.Island` and the
//  island button style; the Settings row uses the window's tokens.
//

import SwiftUI

// MARK: - Notch card

/// The offer (or the report after acting). Draws nothing when there is neither,
/// so the notch can place it unconditionally.
struct DownloadConciergeNotchCard: View {
    @ObservedObject private var downloadConcierge = DownloadConcierge.shared

    var body: some View {
        if let currentOffer = downloadConcierge.currentOffer {
            offerCard(currentOffer)
        } else if let latestReport = downloadConcierge.latestReport {
            reportCard(latestReport)
        }
    }

    private func offerCard(_ offer: DownloadFilingOffer) -> some View {
        let plan = offer.plan
        let downloadedFile = plan.downloadedFile
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: downloadedFile.isImage ? "photo" : (downloadedFile.isPDF ? "doc.richtext" : "arrow.down.circle"))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(WispColor.Island.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(offerTitle(for: downloadedFile))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(WispColor.Island.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if plan.changesSomething {
                        Text("→ \(destinationText(for: plan))")
                            .font(.system(size: 11))
                            .foregroundColor(WispColor.Island.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                if plan.canAddToBrain || plan.matchedRule != nil {
                    HStack(spacing: 6) {
                        if plan.canAddToBrain && plan.changesSomething {
                            optionChip(title: "Add to brain", isOn: offer.addsToBrain, tooltip: "Also add this file to your brain when it's filed") {
                                downloadConcierge.toggleAddsToBrainOnCurrentOffer()
                            }
                        }
                        if let matchedRule = plan.matchedRule {
                            optionChip(title: "Always for \(matchedRule.name)", isOn: offer.marksRuleAlways, tooltip: "File downloads like this without asking next time (Undo stays for 10 minutes)") {
                                downloadConcierge.toggleMarksRuleAlwaysOnCurrentOffer()
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    if plan.changesSomething {
                        Button(plan.movesToAnotherFolder ? "File" : "Rename") {
                            downloadConcierge.fileCurrentOffer()
                            collapseNotchIfNothingIsLeft()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .wispIslandButtonStyle(prominence: .prominent)
                        .pointerCursor()
                        .nativeTooltip(plan.movesToAnotherFolder ? "Rename and move the file as shown" : "Rename the file as shown")
                    }
                    if plan.canAddToBrain {
                        Button(plan.changesSomething ? "Just brain" : "Add to brain") {
                            downloadConcierge.addCurrentOfferToBrainOnly()
                            collapseNotchIfNothingIsLeft()
                        }
                        .font(.system(size: 11, weight: plan.changesSomething ? .medium : .semibold))
                        .wispIslandButtonStyle(prominence: plan.changesSomething ? .subtle : .prominent)
                        .pointerCursor()
                        .nativeTooltip("Leave the file where it is and add it to your brain")
                    }
                    Button("Ignore") {
                        downloadConcierge.ignoreCurrentOffer()
                        collapseNotchIfNothingIsLeft()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .wispIslandButtonStyle(prominence: .subtle)
                    .pointerCursor()
                    .nativeTooltip("Leave this download alone")

                    if downloadConcierge.pendingOffers.count > 1 {
                        Text("+\(downloadConcierge.pendingOffers.count - 1) more")
                            .font(.system(size: 10.5))
                            .foregroundColor(WispColor.Island.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Download finished: \(offerTitle(for: downloadedFile))")
    }

    private func reportCard(_ report: DownloadConciergeReport) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(WispColor.Island.accent)
            Text(report.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(WispColor.Island.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let undoableRecord = downloadConcierge.undoableRecordForLatestReport {
                Button("Undo") {
                    downloadConcierge.undoFiling(withRecordID: undoableRecord.id)
                }
                .font(.system(size: 11, weight: .semibold))
                .wispIslandButtonStyle(prominence: .subtle)
                .pointerCursor()
                .nativeTooltip("Move the file back where Chrome saved it")
            }
            Button {
                downloadConcierge.dismissLatestReport()
                collapseNotchIfNothingIsLeft()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .wispIslandButtonStyle(prominence: .subtle)
            .pointerCursor()
            .nativeTooltip("Hide")
            .accessibilityLabel("Hide")
        }
    }

    /// A small on/off pill for one option of the offer.
    private func optionChip(title: String, isOn: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .wispIslandButtonStyle(prominence: .subtle)
        .pointerCursor()
        .nativeTooltip(tooltip)
        .accessibilityValue(isOn ? "on" : "off")
    }

    /// "Paper.pdf from arxiv.org", or just the name for a file with no page.
    private func offerTitle(for downloadedFile: DownloadedFile) -> String {
        guard let sourceHost = downloadedFile.sourceHost else { return downloadedFile.fileName }
        return "\(downloadedFile.fileName) from \(sourceHost)"
    }

    /// "~/Documents/Papers/Attention Is All You Need.pdf".
    private func destinationText(for plan: DownloadFilingPlan) -> String {
        let folderText = DownloadFilingSafety.abbreviatedPath(plan.destinationFolderPath, homeDirectoryPath: DownloadConcierge.homeDirectoryPath)
        return "\(folderText)/\(plan.suggestedFileName)"
    }

    /// With nothing left to show, the notch goes back to being the notch.
    private func collapseNotchIfNothingIsLeft() {
        if downloadConcierge.pendingOffers.isEmpty && downloadConcierge.latestReport == nil {
            NotificationCenter.default.post(name: .wispDismissPanel, object: nil)
        }
    }
}

// MARK: - Flank badge

/// "↓ 2" in the notch's right flank: offers waiting (held back in quiet mode,
/// or left unanswered). Hovering the notch shows the card.
struct DownloadConciergeFlankBadge: View {
    @ObservedObject private var downloadConcierge = DownloadConcierge.shared

    var body: some View {
        let waitingOfferCount = downloadConcierge.pendingOffers.count
        HStack(spacing: 3) {
            Image(systemName: waitingOfferCount > 0 ? "arrow.down.circle" : "checkmark.circle")
                .font(.system(size: 10, weight: .semibold))
            if waitingOfferCount > 0 {
                Text("\(waitingOfferCount)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundColor(WispColor.Island.textPrimary)
        .nativeTooltip(waitingOfferCount == 1
            ? "A download is ready to file — hover to see it"
            : (waitingOfferCount > 1 ? "\(waitingOfferCount) downloads are ready to file — hover to see them" : "Download filed — hover to undo"))
    }
}

// MARK: - Settings row

/// The concierge's one row in the Chrome Tabs card: the switch, what it
/// needs, and a way to edit the rules.
struct DownloadConciergeSettingsRow: View {
    @ObservedObject private var downloadConcierge = DownloadConcierge.shared
    @ObservedObject private var chromeExtensionBridge = ChromeExtensionBridge.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Offer to file finished downloads")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Edit rules…") {
                    downloadConcierge.openRulesFile()
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .pointerCursor()
                .nativeTooltip("Open ~/.wisp/download-rules.json")
                Toggle("", isOn: $downloadConcierge.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .pointerCursor()
                    .accessibilityLabel("Offer to file finished downloads")
            }
            ForEach(downloadConcierge.ruleProblems, id: \.self) { ruleProblem in
                Text(ruleProblem)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.warningText)
            }
        }
    }

    private var detailText: String {
        if !chromeExtensionBridge.hasCapability(.downloads) {
            return "Needs Downloads allowed in Chrome. Nothing moves until you say yes."
        }
        return "Rename, file by rule, or add to your brain. Nothing moves until you say yes."
    }
}
