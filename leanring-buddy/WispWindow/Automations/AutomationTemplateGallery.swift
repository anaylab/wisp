//
//  AutomationTemplateGallery.swift
//  leanring-buddy
//
//  The eight ready-made automations. Picking one does not switch anything on: it opens the same
//  editable draft card as "say it", so the user sees exactly what will run before saving.
//

import SwiftUI

struct AutomationTemplateGallery: View {
    let onPick: (AutomationTemplate) -> Void

    @ObservedObject private var automationStore = AutomationStore.shared

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(Array(AutomationTemplates.all.enumerated()), id: \.element.id) { templateIndex, template in
                templateCard(template)
                    .wispEntrance(order: templateIndex)
            }
        }
    }

    /// Canvas sync and the checklist exist once each (JobsEngine owns them), so a second copy
    /// would only be a duplicate view onto the same job.
    private func isAlreadyAdded(_ template: AutomationTemplate) -> Bool {
        guard template.action.isManagedByJobsEngine else { return false }
        return automationStore.automations.contains { $0.action == template.action }
    }

    private func templateCard(_ template: AutomationTemplate) -> some View {
        let alreadyAdded = isAlreadyAdded(template)
        return Button {
            onPick(template)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: template.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WispColor.accentText)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WispColor.accentText.opacity(0.14)))
                    Text(template.title)
                        .font(WispFont.bodyMedium)
                        .foregroundStyle(WispColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if alreadyAdded {
                        Text("Added")
                            .font(WispFont.caption)
                            .foregroundStyle(WispColor.textTertiary)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
                Text(template.summary)
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AutomationDisplayText.triggerSummary(template.trigger))
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.textTertiary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .wispBentoSurface(isInteractive: !alreadyAdded)
            .opacity(alreadyAdded ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: WispBentoMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(WispBentoPressStyle())
        .disabled(alreadyAdded)
        .pointerCursor(isEnabled: !alreadyAdded)
        .accessibilityLabel("\(template.title). \(template.summary)")
        .accessibilityHint(alreadyAdded ? "Already added." : "Opens it for editing before it is saved.")
    }
}
