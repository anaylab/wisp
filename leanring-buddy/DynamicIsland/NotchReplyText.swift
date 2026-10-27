//
//  NotchReplyText.swift
//  leanring-buddy
//
//  Formats a reply for the island. The old renderer was inline-only, so a
//  reply with a list or a heading showed raw "-" and "##" characters in one
//  block. `NotchReplyBlock.parse` splits the text into paragraphs, headings,
//  bullets and numbered steps (pure, no UI); `NotchReplyText` draws them.
//

import SwiftUI

enum NotchReplyBlock: Equatable {
    case heading(String)
    case paragraph(String)
    case bullet(String)
    case numbered(number: String, text: String)

    /// Line-based on purpose: the local model writes simple markdown, and a
    /// line that matches nothing stays a paragraph, so nothing is ever dropped.
    /// Consecutive plain lines are joined into one paragraph.
    static func parse(_ replyText: String) -> [NotchReplyBlock] {
        var blocks: [NotchReplyBlock] = []
        var pendingParagraphLines: [String] = []

        func flushParagraph() {
            guard !pendingParagraphLines.isEmpty else { return }
            blocks.append(.paragraph(pendingParagraphLines.joined(separator: " ")))
            pendingParagraphLines = []
        }

        for rawLine in replyText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("#") {
                flushParagraph()
                let headingText = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(headingText.isEmpty ? line : headingText))
            } else if let bulletText = bulletText(in: line) {
                flushParagraph()
                blocks.append(.bullet(bulletText))
            } else if let (number, text) = numberedParts(in: line) {
                flushParagraph()
                blocks.append(.numbered(number: number, text: text))
            } else {
                pendingParagraphLines.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    private static func bulletText(in line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func numberedParts(in line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let remainder = line.dropFirst(digits.count)
        guard remainder.hasPrefix(". ") || remainder.hasPrefix(") ") else { return nil }
        let text = remainder.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (String(digits), text)
    }
}

struct NotchReplyText: View {
    let replyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(NotchReplyBlock.parse(replyText).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: NotchReplyBlock) -> some View {
        switch block {
        case .heading(let text):
            inlineText(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WispColor.Island.textPrimary)
                .padding(.top, 2)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 12.5))
                .foregroundColor(WispColor.Island.textPrimary)
                .lineSpacing(2.5)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(WispColor.Island.textTertiary)
                    .frame(width: 4, height: 4)
                    .offset(y: -1.5)
                inlineText(text)
                    .font(.system(size: 12.5))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineSpacing(2.5)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(number)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(WispColor.Island.textSecondary)
                    .frame(minWidth: 12, alignment: .trailing)
                inlineText(text)
                    .font(.system(size: 12.5))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineSpacing(2.5)
            }
        }
    }

    /// **bold**, `code` and links inside one block; falls back to plain text.
    /// Wrapping is explicit (`fixedSize`) so a long sentence grows the card
    /// downward instead of being cut at the card's width.
    private func inlineText(_ text: String) -> some View {
        let parsingOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed = (try? AttributedString(markdown: text, options: parsingOptions))
            ?? AttributedString(text)
        return Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What Wisp is hearing, wrapped and growing downward from the notch. On a
/// notched Mac the wrap only holds the mark and a waveform, so before this the
/// words themselves were never visible while talking; the non-notch pill shows
/// them on one truncated line.
struct NotchLiveCaptionCard: View {
    let transcript: String
    let isThinking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isThinking ? "ellipsis" : "waveform")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(WispColor.Brand.lavender)
                .frame(width: 12, height: 16)
            Text(transcript)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(WispColor.Island.textPrimary)
                .lineSpacing(2)
                // The newest words matter most, so a long utterance keeps its
                // tail and shortens at the head.
                .lineLimit(4)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
