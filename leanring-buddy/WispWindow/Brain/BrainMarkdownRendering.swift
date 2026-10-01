//
//  BrainMarkdownRendering.swift
//  leanring-buddy
//
//  The pure half of the Brain reader: splits a page body into blocks
//  (headings, paragraphs, bullets, quotes, code, rules) and turns a line of
//  markdown into an `AttributedString` whose `[[links]]` are real links.
//
//  Why not hand the whole body to `AttributedString(markdown:)`: its block
//  parsing collapses a page into one run of text (no bullets, no heading
//  sizes), and it knows nothing of Obsidian-style `[[wiki links]]`. So blocks
//  are split here, and each block's inline text is rewritten — `[[Target|shown]]`
//  becomes `[shown](wisp-brain://page/Target)` — before Foundation parses the
//  bold / italic / code / link spans. A link whose target has no page yet gets
//  the `missing` host instead, so the view can dim it and offer "Create page"
//  without re-resolving anything.
//
//  Foundation only, so `Tests/BrainUI` compiles it standalone.
//

import Foundation

// MARK: - Blocks

nonisolated enum BrainMarkdownBlock: Equatable, Sendable {
    /// `# Title` … `###### Title`.
    case heading(level: Int, text: String)
    /// Consecutive plain lines, soft-wrapped into one paragraph.
    case paragraph(text: String)
    /// `- item`, with its nesting depth and an optional task checkbox
    /// (`nil` = plain bullet, `false` = `[ ]`, `true` = `[x]`).
    case bullet(indentLevel: Int, text: String, checkboxIsChecked: Bool?)
    /// `1. item` / `1) item`.
    case numbered(indentLevel: Int, number: String, text: String)
    /// `> quoted text`, consecutive lines joined.
    case quote(text: String)
    /// A fenced code block, verbatim.
    case code(language: String, text: String)
    /// `---`, `***` or `___` on its own line.
    case rule
}

enum BrainMarkdownBlockParser {
    static func blocks(from markdown: String) -> [BrainMarkdownBlock] {
        var blocks: [BrainMarkdownBlock] = []
        var pendingParagraphLines: [String] = []
        var pendingQuoteLines: [String] = []
        var openCodeFence: (language: String, lines: [String])?

        func flushParagraph() {
            guard !pendingParagraphLines.isEmpty else { return }
            blocks.append(.paragraph(text: pendingParagraphLines.joined(separator: " ")))
            pendingParagraphLines = []
        }

        func flushQuote() {
            guard !pendingQuoteLines.isEmpty else { return }
            blocks.append(.quote(text: pendingQuoteLines.joined(separator: " ")))
            pendingQuoteLines = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Inside a code fence everything is verbatim until the closing fence.
            if var codeFence = openCodeFence {
                if trimmedLine.hasPrefix("```") {
                    blocks.append(.code(language: codeFence.language, text: codeFence.lines.joined(separator: "\n")))
                    openCodeFence = nil
                } else {
                    codeFence.lines.append(line)
                    openCodeFence = codeFence
                }
                continue
            }

            if trimmedLine.hasPrefix("```") {
                flushParagraph()
                flushQuote()
                let language = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                openCodeFence = (language: language, lines: [])
                continue
            }

            if trimmedLine.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }

            if trimmedLine.hasPrefix(">") {
                flushParagraph()
                pendingQuoteLines.append(String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()

            if isRule(trimmedLine) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(from: trimmedLine) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            let indentLevel = indentationLevel(of: line)

            if let bullet = bullet(from: trimmedLine) {
                flushParagraph()
                blocks.append(.bullet(indentLevel: indentLevel, text: bullet.text, checkboxIsChecked: bullet.checkboxIsChecked))
                continue
            }

            if let numberedItem = numberedItem(from: trimmedLine) {
                flushParagraph()
                blocks.append(.numbered(indentLevel: indentLevel, number: numberedItem.number, text: numberedItem.text))
                continue
            }

            pendingParagraphLines.append(trimmedLine)
        }

        // An unclosed fence still shows what was typed, rather than eating it.
        if let codeFence = openCodeFence {
            blocks.append(.code(language: codeFence.language, text: codeFence.lines.joined(separator: "\n")))
        }
        flushParagraph()
        flushQuote()
        return blocks
    }

    /// Two spaces (or one tab) per nesting level, the way pages are written.
    static func indentationLevel(of line: String) -> Int {
        var leadingSpaceCount = 0
        for character in line {
            if character == " " {
                leadingSpaceCount += 1
            } else if character == "\t" {
                leadingSpaceCount += 2
            } else {
                break
            }
        }
        return min(leadingSpaceCount / 2, 6)
    }

    private static func isRule(_ trimmedLine: String) -> Bool {
        guard trimmedLine.count >= 3, let firstCharacter = trimmedLine.first, "-*_".contains(firstCharacter) else { return false }
        return trimmedLine.allSatisfy { $0 == firstCharacter || $0 == " " }
            && trimmedLine.filter({ $0 == firstCharacter }).count >= 3
    }

    private static func heading(from trimmedLine: String) -> (level: Int, text: String)? {
        let hashCount = trimmedLine.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashCount) else { return nil }
        let remainder = trimmedLine.dropFirst(hashCount)
        guard remainder.first == " " else { return nil }
        let headingText = remainder.trimmingCharacters(in: .whitespaces)
        return headingText.isEmpty ? nil : (hashCount, headingText)
    }

    private static func bullet(from trimmedLine: String) -> (text: String, checkboxIsChecked: Bool?)? {
        guard trimmedLine.count >= 2,
              let marker = trimmedLine.first, "-*+".contains(marker),
              trimmedLine.dropFirst().first == " " else { return nil }
        var itemText = String(trimmedLine.dropFirst(2))
        var checkboxIsChecked: Bool?
        if itemText.hasPrefix("[ ] ") || itemText == "[ ]" {
            checkboxIsChecked = false
            itemText = String(itemText.dropFirst(3))
        } else if itemText.lowercased().hasPrefix("[x] ") || itemText.lowercased() == "[x]" {
            checkboxIsChecked = true
            itemText = String(itemText.dropFirst(3))
        }
        return (itemText.trimmingCharacters(in: .whitespaces), checkboxIsChecked)
    }

    private static func numberedItem(from trimmedLine: String) -> (number: String, text: String)? {
        let digits = trimmedLine.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let afterDigits = trimmedLine.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return (String(digits), afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Inline text and links

enum BrainInlineMarkdown {
    static let linkScheme = "wisp-brain"

    /// Where a link in a rendered page goes.
    nonisolated enum LinkDestination: Equatable, Sendable {
        /// A page that exists (by `[[link]]` target, resolved again on click).
        case page(target: String)
        /// A `[[link]]` whose page doesn't exist yet.
        case missingPage(target: String)
    }

    /// Only letters and digits survive unencoded, so a target containing
    /// `)`, spaces or `#` can never break the markdown link it is written into.
    private static let unreservedTargetCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    )

    static func urlString(for destination: LinkDestination) -> String {
        let host: String
        let target: String
        switch destination {
        case .page(let pageTarget):
            host = "page"
            target = pageTarget
        case .missingPage(let missingTarget):
            host = "missing"
            target = missingTarget
        }
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: unreservedTargetCharacters) ?? target
        return "\(linkScheme)://\(host)/\(encodedTarget)"
    }

    static func destination(from url: URL) -> LinkDestination? {
        guard url.scheme == linkScheme else { return nil }
        let prefixForPage = "\(linkScheme)://page/"
        let prefixForMissingPage = "\(linkScheme)://missing/"
        let absoluteURLString = url.absoluteString
        if absoluteURLString.hasPrefix(prefixForPage) {
            let encodedTarget = String(absoluteURLString.dropFirst(prefixForPage.count))
            return .page(target: encodedTarget.removingPercentEncoding ?? encodedTarget)
        }
        if absoluteURLString.hasPrefix(prefixForMissingPage) {
            let encodedTarget = String(absoluteURLString.dropFirst(prefixForMissingPage.count))
            return .missingPage(target: encodedTarget.removingPercentEncoding ?? encodedTarget)
        }
        return nil
    }

    /// Rewrites every `[[target|shown]]` outside inline code into a markdown
    /// link to a `wisp-brain://` URL. `isResolved` decides `page` vs `missing`.
    static func markdownReplacingWikiLinks(_ text: String, isResolved: (String) -> Bool) -> String {
        var rewrittenText = ""
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let character = text[currentIndex]

            // Inline code is copied verbatim so `[[example]]` in backticks stays text.
            if character == "`" {
                let afterBacktick = text.index(after: currentIndex)
                if let closingBacktick = text[afterBacktick...].firstIndex(of: "`") {
                    rewrittenText += text[currentIndex...closingBacktick]
                    currentIndex = text.index(after: closingBacktick)
                    continue
                }
            }

            if text[currentIndex...].hasPrefix("[["),
               let closingRange = text.range(of: "]]", range: text.index(currentIndex, offsetBy: 2)..<text.endIndex) {
                let innerText = String(text[text.index(currentIndex, offsetBy: 2)..<closingRange.lowerBound])
                let target = BrainLinkParser.linkTarget(fromInnerText: innerText)
                if !target.isEmpty, !innerText.contains("["), !innerText.contains("\n") {
                    let shownText = BrainLinkParser.displayText(fromInnerText: innerText)
                    let destination: LinkDestination = isResolved(target) ? .page(target: target) : .missingPage(target: target)
                    rewrittenText += "[\(escapedForMarkdown(shownText))](\(urlString(for: destination)))"
                    currentIndex = closingRange.upperBound
                    continue
                }
            }

            rewrittenText.append(character)
            currentIndex = text.index(after: currentIndex)
        }
        return rewrittenText
    }

    /// One block's inline markdown as styled text. Never fails: text Foundation
    /// can't parse is shown as written.
    static func attributedString(from text: String, isResolved: (String) -> Bool) -> AttributedString {
        let rewrittenMarkdown = markdownReplacingWikiLinks(text, isResolved: isResolved)
        let parsingOptions = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: rewrittenMarkdown, options: parsingOptions)) ?? AttributedString(text)
    }

    /// Every link destination in an attributed string, in order.
    static func linkDestinations(in attributedString: AttributedString) -> [LinkDestination] {
        attributedString.runs.compactMap { run in
            run.link.flatMap(destination(from:))
        }
    }

    private static func escapedForMarkdown(_ text: String) -> String {
        var escapedText = ""
        for character in text {
            if "\\`*_[]<>".contains(character) {
                escapedText.append("\\")
            }
            escapedText.append(character)
        }
        return escapedText
    }
}

// MARK: - Backlink context

enum BrainBacklinkContext {
    /// The first line of `body` that links to a page answering to any of
    /// `pageNames`, without its bullet marker — shown under a backlink so the
    /// user sees *why* the other page mentions this one.
    static func mentioningLine(in body: String, linkingToAnyOf pageNames: [String]) -> String? {
        let comparablePageNames = Set(pageNames.map(BrainSlug.comparableName))
        for line in body.components(separatedBy: "\n") where line.contains("[[") {
            let linksToPage = BrainLinkParser.linkTargets(in: line).contains { target in
                comparablePageNames.contains(BrainSlug.comparableName(target))
            }
            guard linksToPage else { continue }
            var trimmedLine = line.trimmingCharacters(in: .whitespaces)
            for bulletMarker in ["- ", "* ", "+ "] where trimmedLine.hasPrefix(bulletMarker) {
                trimmedLine = String(trimmedLine.dropFirst(bulletMarker.count))
            }
            return trimmedLine
        }
        return nil
    }
}
