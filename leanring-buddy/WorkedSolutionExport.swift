//
//  WorkedSolutionExport.swift
//  leanring-buddy
//
//  The pure side of "Save Worked Solution": deciding whether there is
//  anything to save, which display's drawings to save, how the files are
//  named, and the text of the Markdown file saved beside the picture.
//  Capturing the screen, rendering the picture and the save panel live in
//  CompanionManager+WorkedSolutionExport.swift; none of this touches AppKit.
//

import CoreGraphics
import Foundation

enum WorkedSolutionExport {
    /// Created on demand inside ~/Pictures.
    static let defaultFolderName = "Wisp Solutions"

    /// Longest question kept in the Markdown file, so a pasted essay doesn't
    /// become the whole document.
    static let maximumQuestionCharacters = 500

    // MARK: - What there is to save

    /// A drawing counts as a "worked solution" once it holds at least one
    /// handwritten note or circle. A lone marker or box (a "where is X" answer)
    /// isn't worth a file.
    static func isWorthSaving(_ annotations: [ScreenAnnotation]) -> Bool {
        annotations.contains { $0.style == .note || $0.style == .circle }
    }

    static func hasSomethingToSave(annotationsByDisplayFrame: [CGRect: [ScreenAnnotation]]) -> Bool {
        annotationsByDisplayFrame.values.contains { isWorthSaving($0) }
    }

    /// The display to save: the one with the most notes, then circles, then
    /// annotations overall. Ties break on the frame's position so the choice is
    /// stable rather than depending on dictionary order. Nil if no display
    /// holds a worked solution.
    static func displayFrameToSave(annotationsByDisplayFrame: [CGRect: [ScreenAnnotation]]) -> CGRect? {
        let candidateFrames = annotationsByDisplayFrame.filter { isWorthSaving($0.value) }.map(\.key)
        return candidateFrames.min { frameA, frameB in
            let countsA = importanceCounts(annotationsByDisplayFrame[frameA] ?? [])
            let countsB = importanceCounts(annotationsByDisplayFrame[frameB] ?? [])
            if countsA != countsB { return countsA.lexicographicallyPrecedes(countsB, by: >) }
            if frameA.minX != frameB.minX { return frameA.minX < frameB.minX }
            return frameA.minY < frameB.minY
        }
    }

    private static func importanceCounts(_ annotations: [ScreenAnnotation]) -> [Int] {
        [
            annotations.filter { $0.style == .note }.count,
            annotations.filter { $0.style == .circle }.count,
            annotations.count,
        ]
    }

    /// The note texts in the order they were drawn (the order of a worked
    /// solution), on one line each, with blank ones dropped.
    static func noteTexts(in annotations: [ScreenAnnotation]) -> [String] {
        annotations
            .filter { $0.style == .note }
            .compactMap { annotation in
                let singleLineText = collapsedToOneLine(annotation.label ?? "")
                return singleLineText.isEmpty ? nil : singleLineText
            }
    }

    // MARK: - File names

    /// "Worked solution 2026-10-17 14.32.05.png" — dots, not colons, because
    /// Finder shows a colon in a file name as a slash.
    static func defaultImageFileName(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Worked solution \(formatter.string(from: date)).png"
    }

    /// The Markdown file shares the picture's name, whatever the user renamed
    /// it to in the save panel: "Algebra.png" becomes "Algebra.md".
    static func markdownFileName(forImageFileName imageFileName: String) -> String {
        let baseName = (imageFileName as NSString).deletingPathExtension
        let isUsableBaseName = !baseName.isEmpty && !baseName.hasPrefix(".")
        return (isUsableBaseName ? baseName : "Worked solution") + ".md"
    }

    // MARK: - Markdown

    /// The notes beside the picture: the date, the question (when known), the
    /// picture it belongs to and the notes as a numbered list.
    static func markdown(
        noteTexts: [String],
        question: String?,
        date: Date,
        imageFileName: String,
        timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = ["# Worked solution", ""]

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("Date: \(dateFormatter.string(from: date))")

        if let clippedQuestion = clippedQuestion(question) {
            lines.append("")
            lines.append("Question: \(clippedQuestion)")
        }

        lines.append("")
        lines.append("![Worked solution](\(percentEncodedForMarkdownLink(imageFileName)))")
        lines.append("")
        lines.append("## Notes")
        lines.append("")
        if noteTexts.isEmpty {
            lines.append("(This drawing had circles but no written notes.)")
        } else {
            for (noteIndex, noteText) in noteTexts.enumerated() {
                lines.append("\(noteIndex + 1). \(collapsedToOneLine(noteText))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Nil for a missing or blank question; otherwise one line, clipped.
    static func clippedQuestion(_ question: String?) -> String? {
        guard let question else { return nil }
        let singleLineQuestion = collapsedToOneLine(question)
        guard !singleLineQuestion.isEmpty else { return nil }
        guard singleLineQuestion.count > maximumQuestionCharacters else { return singleLineQuestion }
        return String(singleLineQuestion.prefix(maximumQuestionCharacters)) + "…"
    }

    /// A note or question is shown on one Markdown line, so line breaks
    /// (which would end a list item) become single spaces.
    private static func collapsedToOneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
    }

    /// A file name with spaces or parentheses would break `![](…)`.
    private static func percentEncodedForMarkdownLink(_ fileName: String) -> String {
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "()")
        return fileName.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? fileName
    }
}
