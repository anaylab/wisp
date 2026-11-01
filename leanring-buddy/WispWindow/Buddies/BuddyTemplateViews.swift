//
//  BuddyTemplateViews.swift
//  leanring-buddy
//
//  The template gallery inside the new-buddy flow (OpenBot's agent templates):
//  cards you can search and filter, then a review that says what the buddy will
//  do, when and with what, before "Add buddy" creates it. Templates you saved
//  from your own buddies come first and can be removed here.
//

import SwiftUI

struct BuddyTemplateGalleryView: View {
    var onCreated: (UUID) -> Void
    var onBack: () -> Void

    @ObservedObject private var templateStore = BuddyTemplateStore.shared
    @State private var searchText = ""
    @State private var category: BuddyTemplate.Category?
    @State private var reviewedTemplate: BuddyTemplate?

    private var shownTemplates: [BuddyTemplate] {
        templateStore.allTemplates.filter { template in
            (category == nil || template.category == category)
                && BuddyTemplateReview.matches(template, searchText: searchText)
        }
    }

    var body: some View {
        if let reviewedTemplate {
            BuddyTemplateReviewView(
                template: reviewedTemplate,
                onAdd: { added in onCreated(BuddyStore.shared.addBuddy(from: added).id) },
                onBack: { withAnimation(WispMotion.smooth) { self.reviewedTemplate = nil } }
            )
            .transition(.opacity)
        } else {
            gallery
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("New buddy").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(WispColor.textSecondary)
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer()
            }
            Text("Templates")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(WispColor.textPrimary)

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(WispColor.textTertiary)
                    TextField("Search templates", text: $searchText).textFieldStyle(.plain).font(.system(size: 12.5))
                }
                .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 260)
                .background(Capsule(style: .continuous).fill(WispColor.surface3.opacity(0.7)))
                categoryChip(nil, title: "All")
                ForEach(BuddyTemplate.Category.allCases) { candidate in categoryChip(candidate, title: candidate.title) }
                Spacer(minLength: 0)
            }

            if shownTemplates.isEmpty {
                Text("No templates match.").font(.system(size: 13)).foregroundStyle(WispColor.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(shownTemplates) { template in card(template) }
            }
        }
    }

    private func categoryChip(_ chipCategory: BuddyTemplate.Category?, title: String) -> some View {
        let isSelected = category == chipCategory
        return Button { withAnimation(WispMotion.quick) { category = chipCategory } } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
                .padding(.horizontal, 11).frame(height: 28)
                .background {
                    if isSelected { Color.clear.wispBevel(Capsule(style: .continuous), fill: WispColor.surface3) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func card(_ template: BuddyTemplate) -> some View {
        let colorIndex = template.colorIndex ?? template.specialty.preferredColorIndex
        return Button { withAnimation(WispMotion.smooth) { reviewedTemplate = template } } label: {
            HStack(alignment: .top, spacing: 12) {
                BuddyCharacter(colorIndex: colorIndex, size: 40, mood: .idle, liveliness: .still)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(template.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(WispColor.textPrimary).lineLimit(1)
                        if template.isSaved {
                            Text("Yours").font(.system(size: 9.5, weight: .medium)).foregroundStyle(WispColor.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(WispColor.surface3.opacity(0.8)))
                        }
                    }
                    Text(template.tagline).font(.system(size: 12)).foregroundStyle(WispColor.textSecondary)
                        .multilineTextAlignment(.leading).lineLimit(2)
                    Text(template.schedule.summary()).font(.system(size: 11)).foregroundStyle(WispColor.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WispColor.surface2.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WispColor.cardSeparator.opacity(0.5), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .contextMenu {
            if template.isSaved {
                Button("Remove Template", systemImage: "trash", role: .destructive) {
                    templateStore.remove(templateWithID: template.id)
                }
            }
        }
        .accessibilityLabel("\(template.name). \(template.tagline)")
    }
}

/// What a template will do, laid out before anything is created.
struct BuddyTemplateReviewView: View {
    let template: BuddyTemplate
    var onAdd: (BuddyTemplate) -> Void
    var onBack: () -> Void

    var body: some View {
        let colorIndex = template.colorIndex ?? template.specialty.preferredColorIndex
        let toolSummary = BuddyToolAccessPolicy.summary(of: template.toolAccess ?? template.specialty.toolAccess)
        let rows = BuddyTemplateReview.rows(for: template, toolSummary: toolSummary)
        return VStack(alignment: .leading, spacing: 20) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Templates").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(WispColor.textSecondary)
            }
            .buttonStyle(.plain).pointerCursor()

            HStack(spacing: 14) {
                BuddyCharacter(colorIndex: colorIndex, size: 56, mood: .idle, liveliness: .full, looksAtPointer: true)
                    .frame(width: 66, height: 66)
                VStack(alignment: .leading, spacing: 5) {
                    Text(template.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(WispColor.textPrimary)
                    HStack(spacing: 6) {
                        chip(template.specialty.title)
                        chip(template.personality.title)
                    }
                }
            }

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WispColor.textSecondary)
                        Text(row.text).font(.system(size: 13.5)).foregroundStyle(WispColor.textPrimary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    if row.id != rows.last?.id {
                        Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.surface2.opacity(0.7)))

            HStack(spacing: 8) {
                Button("Add buddy") { onAdd(template) }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: colorIndex)).pointerCursor()
                Text(template.schedule.isRepeating ? "It starts on its schedule, not now." : "It runs only when you ask.")
                    .font(.system(size: 12)).foregroundStyle(WispColor.textTertiary)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(WispColor.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(WispColor.surface3.opacity(0.8)))
    }
}
