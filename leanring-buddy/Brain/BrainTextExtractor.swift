//
//  BrainTextExtractor.swift
//  leanring-buddy
//
//  Turns a file or a web page into plain text for ingest. Markdown, text, JSON
//  and CSV are read as they are; PDFs through PDFKit; HTML through a small
//  readable-text converter (below); RTF and Word documents through
//  `NSAttributedString`. Everything is on-device — the only network use is
//  `fetchWebPage`, a single GET of a link the user explicitly asked to ingest.
//
//  Extracted text is capped (`maximumExtractedCharacters`): the chunker only
//  samples a long source anyway, and an unbounded read of a huge file would
//  sit in memory for nothing. A capped text ends with a note saying so.
//

import AppKit
import Foundation
import PDFKit

nonisolated struct BrainExtractedText: Equatable, Sendable {
    /// A short title for the source (a page's <title>, a PDF's title, else the file name).
    var title: String
    var text: String
    /// Words for the prompt ("a PDF document").
    var materialDescription: String
    var wasTruncated: Bool
}

nonisolated enum BrainTextExtractionError: LocalizedError, Equatable {
    case unsupportedFileType(fileExtension: String)
    case unreadableFile(fileName: String)
    case noTextFound(sourceName: String)
    case notAWebAddress
    case downloadFailed(reason: String)
    case webPageTooLarge
    case unsupportedWebContent(contentType: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let fileExtension):
            return fileExtension.isEmpty ? "can't read files without an extension" : "can't read .\(fileExtension) files"
        case .unreadableFile(let fileName):
            return "couldn't open \(fileName)"
        case .noTextFound(let sourceName):
            return "found no text in \(sourceName) (a scanned PDF has none to read)"
        case .notAWebAddress:
            return "only http and https links can be read"
        case .downloadFailed(let reason):
            return "couldn't download the page: \(reason)"
        case .webPageTooLarge:
            return "the page is larger than \(BrainTextExtractor.maximumWebPageBytes / 1_000_000) MB"
        case .unsupportedWebContent(let contentType):
            return "the link isn't a web page or document (\(contentType))"
        }
    }
}

nonisolated enum BrainTextExtractor {
    static let maximumExtractedCharacters = 200_000
    static let maximumWebPageBytes = 5_000_000
    static let webPageTimeoutSeconds: TimeInterval = 20
    /// A normal browser user agent: many sites serve a stripped or blocked
    /// page to unknown clients, and this is a person's own request for a page.
    static let webPageUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    // MARK: Files

    /// Reads a file's text off the main actor (PDF and DOCX parsing can take a
    /// noticeable moment on a big file).
    static func extractTextInBackground(fromFileAt fileURL: URL) async throws -> BrainExtractedText {
        try await Task.detached(priority: .utility) {
            try extractText(fromFileAt: fileURL)
        }.value
    }

    static func extractText(fromFileAt fileURL: URL) throws -> BrainExtractedText {
        let fileExtension = fileURL.pathExtension.lowercased()
        let fileName = fileURL.lastPathComponent
        guard let readingMethod = BrainIngestFileRules.textReadingMethod(forFileExtension: fileExtension) else {
            throw BrainTextExtractionError.unsupportedFileType(fileExtension: fileExtension)
        }
        let materialDescription = BrainIngestFileRules.materialDescription(forFileExtension: fileExtension)
        var title = fileName
        let rawText: String

        switch readingMethod {
        case .plainText:
            guard let data = try? Data(contentsOf: fileURL) else {
                throw BrainTextExtractionError.unreadableFile(fileName: fileName)
            }
            rawText = decodedText(from: data)
            // A markdown note's own `# Heading` names it better than its file name.
            if ["md", "markdown"].contains(fileExtension),
               let firstHeadingLine = rawText.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               firstHeadingLine.hasPrefix("# ") {
                let headingTitle = firstHeadingLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if isUsableDocumentTitle(headingTitle) { title = headingTitle }
            }

        case .pdf:
            guard let pdfDocument = PDFDocument(url: fileURL) else {
                throw BrainTextExtractionError.unreadableFile(fileName: fileName)
            }
            if let documentTitle = pdfDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
               isUsableDocumentTitle(documentTitle) {
                title = documentTitle
            }
            rawText = text(of: pdfDocument)

        case .html:
            guard let data = try? Data(contentsOf: fileURL) else {
                throw BrainTextExtractionError.unreadableFile(fileName: fileName)
            }
            let convertedPage = BrainHTMLTextConverter.convert(html: decodedText(from: data))
            if let pageTitle = convertedPage.title, isUsableDocumentTitle(pageTitle) { title = pageTitle }
            rawText = convertedPage.text

        case .attributedDocument:
            let documentType: NSAttributedString.DocumentType = fileExtension == "docx" ? .officeOpenXML : .rtf
            guard let attributedDocument = try? NSAttributedString(
                url: fileURL,
                options: [.documentType: documentType],
                documentAttributes: nil
            ) else {
                throw BrainTextExtractionError.unreadableFile(fileName: fileName)
            }
            rawText = attributedDocument.string
        }

        let cleanedText = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            throw BrainTextExtractionError.noTextFound(sourceName: fileName)
        }
        let (cappedText, wasTruncated) = capped(cleanedText)
        return BrainExtractedText(
            title: BrainHTMLTextConverter.collapsedWhitespace(title),
            text: cappedText,
            materialDescription: materialDescription,
            wasTruncated: wasTruncated
        )
    }

    /// Text past the cap is dropped, with a note the model (and the raw copy) can see.
    static func capped(_ text: String, maximumCharacters: Int = BrainTextExtractor.maximumExtractedCharacters) -> (text: String, wasTruncated: Bool) {
        guard text.count > maximumCharacters else { return (text, false) }
        let keptText = String(text.prefix(maximumCharacters))
        return (keptText + "\n\n[… the rest of this source was not read: it is longer than \(maximumCharacters / 1000)k characters.]", true)
    }

    /// UTF-8 first; then UTF-16 (with a BOM) and Latin-1, so an old export
    /// in another encoding still reads rather than failing.
    static func decodedText(from data: Data) -> String {
        if let utf8Text = String(data: data, encoding: .utf8) { return utf8Text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let utf16Text = String(data: data, encoding: .utf16) {
            return utf16Text
        }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    private static func text(of pdfDocument: PDFDocument) -> String {
        var pageTexts: [String] = []
        var characterCount = 0
        for pageIndex in 0..<pdfDocument.pageCount {
            // Stop reading pages once past the cap — a 900-page PDF shouldn't
            // be fully parsed to keep its first 200k characters.
            guard characterCount <= maximumExtractedCharacters else { break }
            guard let pageText = pdfDocument.page(at: pageIndex)?.string else { continue }
            pageTexts.append(pageText)
            characterCount += pageText.count
        }
        return pageTexts.joined(separator: "\n\n")
    }

    private static func isUsableDocumentTitle(_ title: String) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.count >= 3, trimmedTitle.count <= 160 else { return false }
        // Word processors often leave a placeholder title behind.
        let placeholderTitles = ["untitled", "microsoft word", "document", "slide 1"]
        return !placeholderTitles.contains { trimmedTitle.lowercased().hasPrefix($0) }
    }

    // MARK: Web pages

    /// Downloads a link the user asked to ingest and returns its readable text.
    /// One GET, http(s) only, capped at `maximumWebPageBytes` — the body stops
    /// being read past the cap rather than being downloaded and then refused.
    static func fetchWebPage(_ webPageURL: URL) async throws -> BrainExtractedText {
        guard let scheme = webPageURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              webPageURL.host?.isEmpty == false else {
            throw BrainTextExtractionError.notAWebAddress
        }
        var request = URLRequest(url: webPageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: webPageTimeoutSeconds)
        request.setValue(webPageUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain,text/markdown,application/pdf;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        // Ephemeral: no cookies or cache from this fetch are kept around.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = webPageTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = webPageTimeoutSeconds * 2
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }

        let (byteStream, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (byteStream, response) = try await session.bytes(for: request)
        } catch {
            throw BrainTextExtractionError.downloadFailed(reason: error.localizedDescription)
        }
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw BrainTextExtractionError.downloadFailed(reason: "the site answered \(httpResponse.statusCode)")
        }
        if response.expectedContentLength > Int64(maximumWebPageBytes) {
            throw BrainTextExtractionError.webPageTooLarge
        }

        var bodyData = Data()
        bodyData.reserveCapacity(min(Int(max(response.expectedContentLength, 64_000)), maximumWebPageBytes))
        do {
            for try await byte in byteStream {
                bodyData.append(byte)
                if bodyData.count > maximumWebPageBytes { throw BrainTextExtractionError.webPageTooLarge }
            }
        } catch let extractionError as BrainTextExtractionError {
            throw extractionError
        } catch {
            throw BrainTextExtractionError.downloadFailed(reason: error.localizedDescription)
        }

        let finalURL = response.url ?? webPageURL
        let mimeType = (response.mimeType ?? "").lowercased()
        let fallbackTitle = finalURL.host.map { host in
            finalURL.path.count > 1 ? host + finalURL.path : host
        } ?? webPageURL.absoluteString

        let convertedTitle: String?
        let convertedText: String
        let materialDescription: String
        if mimeType == "application/pdf" || finalURL.pathExtension.lowercased() == "pdf" {
            guard let pdfDocument = PDFDocument(data: bodyData) else {
                throw BrainTextExtractionError.downloadFailed(reason: "the PDF couldn't be opened")
            }
            convertedTitle = pdfDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            convertedText = text(of: pdfDocument)
            materialDescription = "a PDF document from the web"
        } else if mimeType.isEmpty || mimeType.contains("html") || mimeType.contains("xml") {
            let convertedPage = BrainHTMLTextConverter.convert(html: decodedText(from: bodyData))
            convertedTitle = convertedPage.title
            convertedText = convertedPage.text
            materialDescription = "a web page"
        } else if mimeType.hasPrefix("text/") || mimeType == "application/json" {
            convertedTitle = nil
            convertedText = decodedText(from: bodyData)
            materialDescription = "a text file from the web"
        } else {
            throw BrainTextExtractionError.unsupportedWebContent(contentType: mimeType)
        }

        let trimmedText = convertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw BrainTextExtractionError.noTextFound(sourceName: fallbackTitle)
        }
        let (cappedText, wasTruncated) = capped(trimmedText)
        let title = convertedTitle.flatMap { isUsableDocumentTitle($0) ? $0 : nil } ?? fallbackTitle
        return BrainExtractedText(
            title: BrainHTMLTextConverter.collapsedWhitespace(title),
            text: cappedText,
            materialDescription: materialDescription,
            wasTruncated: wasTruncated
        )
    }
}

// MARK: - HTML → readable text

/// Converts HTML into readable, markdown-flavoured text: page chrome (scripts,
/// styles, navigation, site header/footer, sidebars, forms) is dropped,
/// headings become `#` lines, list items become `- ` bullets, table cells are
/// separated by ` | `, and entities are decoded. A hand-rolled scanner rather
/// than `NSAttributedString(html:)`, which needs the main thread, loads remote
/// resources, and keeps all the chrome.
nonisolated enum BrainHTMLTextConverter {
    struct ConvertedPage: Equatable, Sendable {
        /// The page's <title>, else its first <h1>.
        var title: String?
        var text: String
    }

    /// Elements whose whole content is page chrome, not the page's text.
    static let droppedElementNames: Set<String> = [
        "nav", "aside", "form", "svg", "template", "iframe", "button", "select",
        "dialog", "canvas", "video", "audio", "object", "map", "picture"
    ]
    /// Dropped only outside an <article>/<main>: there, a <header> usually
    /// holds the headline and byline rather than the site's menu.
    static let siteChromeElementNames: Set<String> = ["header", "footer"]
    /// Elements whose content is raw text up to their closing tag.
    static let rawTextElementNames: Set<String> = ["script", "style", "noscript", "textarea", "title", "xmp"]
    static let voidElementNames: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"
    ]
    static let paragraphBreakElementNames: Set<String> = [
        "p", "div", "section", "article", "main", "blockquote", "table", "ul", "ol", "dl", "figure",
        "figcaption", "address", "details", "summary", "hr", "pre"
    ]
    static let lineBreakElementNames: Set<String> = ["br", "tr", "dt", "dd", "li", "caption"]

    /// Below this, a dropped-element pass is assumed to have eaten the page
    /// (an unclosed <nav>, say) and the conversion runs again keeping chrome.
    static let minimumReadableCharacters = 200

    static func convert(html: String) -> ConvertedPage {
        let readablePage = convert(html: html, dropsPageChrome: true)
        if readablePage.text.count >= minimumReadableCharacters { return readablePage }
        let pageWithChrome = convert(html: html, dropsPageChrome: false)
        return pageWithChrome.text.count > readablePage.text.count ? pageWithChrome : readablePage
    }

    private struct ParsedTag {
        var name: String
        var isClosing: Bool
        var isSelfClosing: Bool
        var attributesText: String
    }

    static func convert(html: String, dropsPageChrome: Bool) -> ConvertedPage {
        let scalars = Array(html.unicodeScalars)
        var output = ReadableTextBuilder()
        var pageTitle: String?
        var firstHeadingText: String?
        var isCapturingFirstHeading = false
        var capturedHeadingText = ""
        var skippedElementName: String?
        var skippedElementNestingDepth = 0
        var articleOrMainDepth = 0
        var listDepth = 0
        var preformattedDepth = 0
        var position = 0

        while position < scalars.count {
            if scalars[position] == "<" {
                if hasPrefix("<!--", in: scalars, at: position) {
                    position = indexAfter("-->", in: scalars, from: position + 4) ?? scalars.count
                    continue
                }
                if hasPrefix("<!", in: scalars, at: position) || hasPrefix("<?", in: scalars, at: position) {
                    position = indexAfter(">", in: scalars, from: position + 2) ?? scalars.count
                    continue
                }
                guard let (tag, positionAfterTag) = parseTag(in: scalars, at: position) else {
                    // A bare "<" in text ("a < b").
                    if skippedElementName == nil { output.appendText("<", isPreformatted: preformattedDepth > 0) }
                    position += 1
                    continue
                }
                position = positionAfterTag

                // Raw-text elements: jump straight to their closing tag.
                if !tag.isClosing && !tag.isSelfClosing && rawTextElementNames.contains(tag.name) {
                    let closingTag = "</" + tag.name
                    let contentEnd = indexOfCaseInsensitive(closingTag, in: scalars, from: position) ?? scalars.count
                    if tag.name == "title" && pageTitle == nil && skippedElementName == nil {
                        var titleScalars = String.UnicodeScalarView()
                        titleScalars.append(contentsOf: scalars[position..<contentEnd])
                        let decodedTitle = collapsedWhitespace(decodeEntities(String(titleScalars)))
                        if !decodedTitle.isEmpty { pageTitle = decodedTitle }
                    }
                    position = contentEnd < scalars.count ? (indexAfter(">", in: scalars, from: contentEnd) ?? scalars.count) : scalars.count
                    continue
                }

                // Inside a dropped element: only track its own nesting.
                if let currentlySkippedName = skippedElementName {
                    if tag.name == currentlySkippedName && !tag.isSelfClosing {
                        skippedElementNestingDepth += tag.isClosing ? -1 : 1
                        if skippedElementNestingDepth <= 0 { skippedElementName = nil }
                    }
                    continue
                }

                if !tag.isClosing && !tag.isSelfClosing && !voidElementNames.contains(tag.name)
                    && dropsPageChrome && shouldDrop(tag, articleOrMainDepth: articleOrMainDepth) {
                    skippedElementName = tag.name
                    skippedElementNestingDepth = 1
                    continue
                }

                let isHeading = tag.name.count == 2 && tag.name.hasPrefix("h")
                    && ("1"..."6").contains(String(tag.name.last!))
                if tag.name == "article" || tag.name == "main" {
                    articleOrMainDepth = max(0, articleOrMainDepth + (tag.isClosing ? -1 : 1))
                }

                if isHeading {
                    output.requestBreak(newlineCount: 2)
                    if tag.isClosing {
                        if isCapturingFirstHeading {
                            isCapturingFirstHeading = false
                            let heading = collapsedWhitespace(capturedHeadingText)
                            if !heading.isEmpty { firstHeadingText = heading }
                        }
                    } else {
                        let headingLevel = Int(String(tag.name.last!)) ?? 2
                        output.setLinePrefix(String(repeating: "#", count: headingLevel) + " ")
                        if headingLevel == 1 && firstHeadingText == nil {
                            isCapturingFirstHeading = true
                            capturedHeadingText = ""
                        }
                    }
                    continue
                }

                switch tag.name {
                case "ul", "ol":
                    listDepth = max(0, listDepth + (tag.isClosing ? -1 : 1))
                    output.requestBreak(newlineCount: listDepth > 0 ? 1 : 2)
                case "li":
                    output.requestBreak(newlineCount: 1)
                    if !tag.isClosing {
                        let indentation = String(repeating: "  ", count: max(0, listDepth - 1))
                        output.setLinePrefix(indentation + "- ")
                    }
                case "pre":
                    preformattedDepth = max(0, preformattedDepth + (tag.isClosing ? -1 : 1))
                    output.requestBreak(newlineCount: 2)
                case "td", "th":
                    if !tag.isClosing && output.currentLineHasContent {
                        output.appendRaw(" | ")
                    }
                default:
                    if paragraphBreakElementNames.contains(tag.name) {
                        output.requestBreak(newlineCount: 2)
                    } else if lineBreakElementNames.contains(tag.name) {
                        output.requestBreak(newlineCount: 1)
                    }
                }
                continue
            }

            // A run of text up to the next tag.
            let textStart = position
            while position < scalars.count && scalars[position] != "<" { position += 1 }
            guard skippedElementName == nil else { continue }
            var textScalars = String.UnicodeScalarView()
            textScalars.append(contentsOf: scalars[textStart..<position])
            let decodedText = decodeEntities(String(textScalars))
            output.appendText(decodedText, isPreformatted: preformattedDepth > 0)
            if isCapturingFirstHeading { capturedHeadingText += decodedText }
        }

        return ConvertedPage(title: pageTitle ?? firstHeadingText, text: cleanedUp(output.text))
    }

    private static func shouldDrop(_ tag: ParsedTag, articleOrMainDepth: Int) -> Bool {
        if droppedElementNames.contains(tag.name) { return true }
        if siteChromeElementNames.contains(tag.name) && articleOrMainDepth == 0 { return true }
        let lowercasedAttributes = tag.attributesText.lowercased()
        if lowercasedAttributes.contains("aria-hidden=\"true\"") { return true }
        if lowercasedAttributes.contains("role=\"navigation\"") || lowercasedAttributes.contains("role=\"banner\"")
            || lowercasedAttributes.contains("role=\"contentinfo\"") {
            return true
        }
        // A bare `hidden` attribute (not `data-hidden`, not inside a value).
        let attributeWords = lowercasedAttributes.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        return attributeWords.contains { $0 == "hidden" || $0.hasPrefix("hidden=") }
    }

    // MARK: Tag scanning

    private static func parseTag(in scalars: [Unicode.Scalar], at openIndex: Int) -> (ParsedTag, Int)? {
        var position = openIndex + 1
        var isClosing = false
        if position < scalars.count && scalars[position] == "/" {
            isClosing = true
            position += 1
        }
        var name = ""
        while position < scalars.count {
            let scalar = scalars[position]
            let isNameCharacter = (scalar.properties.isAlphabetic && scalar.isASCII) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == ":"
            guard isNameCharacter else { break }
            name.unicodeScalars.append(scalar)
            position += 1
        }
        guard !name.isEmpty, name.first?.isLetter == true else { return nil }

        // Attributes up to the closing ">", respecting quoted values.
        var attributesScalars = String.UnicodeScalarView()
        var activeQuote: Unicode.Scalar?
        while position < scalars.count {
            let scalar = scalars[position]
            if let quote = activeQuote {
                if scalar == quote { activeQuote = nil }
            } else if scalar == "\"" || scalar == "'" {
                activeQuote = scalar
            } else if scalar == ">" {
                break
            }
            attributesScalars.append(scalar)
            position += 1
        }
        let attributesText = String(attributesScalars)
        let isSelfClosing = attributesText.trimmingCharacters(in: .whitespaces).hasSuffix("/")
        let positionAfterTag = min(position + 1, scalars.count)
        return (ParsedTag(name: name.lowercased(), isClosing: isClosing, isSelfClosing: isSelfClosing, attributesText: attributesText), positionAfterTag)
    }

    private static func hasPrefix(_ prefix: String, in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var position = index
        for prefixScalar in prefix.unicodeScalars {
            guard position < scalars.count, scalars[position] == prefixScalar else { return false }
            position += 1
        }
        return true
    }

    private static func indexAfter(_ marker: String, in scalars: [Unicode.Scalar], from startIndex: Int) -> Int? {
        let markerScalars = Array(marker.unicodeScalars)
        guard !markerScalars.isEmpty, startIndex <= scalars.count - markerScalars.count else { return nil }
        var index = startIndex
        while index <= scalars.count - markerScalars.count {
            if scalars[index] == markerScalars[0] && hasPrefix(marker, in: scalars, at: index) {
                return index + markerScalars.count
            }
            index += 1
        }
        return nil
    }

    private static func indexOfCaseInsensitive(_ marker: String, in scalars: [Unicode.Scalar], from startIndex: Int) -> Int? {
        let markerScalars = Array(marker.lowercased().unicodeScalars)
        guard !markerScalars.isEmpty, startIndex <= scalars.count - markerScalars.count else { return nil }
        var index = startIndex
        outer: while index <= scalars.count - markerScalars.count {
            for (offset, markerScalar) in markerScalars.enumerated() {
                let candidate = scalars[index + offset]
                let lowercasedCandidate = candidate.isASCII ? Unicode.Scalar(UInt8(ascii: candidate) | (("A"..."Z").contains(candidate) ? 0x20 : 0)) : candidate
                if lowercasedCandidate != markerScalar {
                    index += 1
                    continue outer
                }
            }
            return index
        }
        return nil
    }

    // MARK: Entities and whitespace

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•", "laquo": "«", "raquo": "»",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "times": "×", "divide": "÷", "deg": "°",
        "shy": "", "zwj": "", "zwnj": "", "thinsp": " ", "ensp": " ", "emsp": " ", "rarr": "→", "larr": "←",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "ouml": "ö", "uuml": "ü", "auml": "ä",
        "szlig": "ß", "ccedil": "ç", "ntilde": "ñ", "iacute": "í", "oacute": "ó", "uacute": "ú"
    ]

    /// Decodes `&amp;`, `&#39;`, `&#x2014;` and the common named entities.
    /// Unknown entities are left as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var decodedText = ""
        var remainder = Substring(text)
        while let ampersandIndex = remainder.firstIndex(of: "&") {
            decodedText += remainder[remainder.startIndex..<ampersandIndex]
            let afterAmpersand = remainder[remainder.index(after: ampersandIndex)...]
            guard let semicolonIndex = afterAmpersand.prefix(12).firstIndex(of: ";") else {
                decodedText += "&"
                remainder = afterAmpersand
                continue
            }
            let entityName = String(afterAmpersand[afterAmpersand.startIndex..<semicolonIndex])
            if let replacement = replacement(forEntityNamed: entityName) {
                decodedText += replacement
                remainder = afterAmpersand[afterAmpersand.index(after: semicolonIndex)...]
            } else {
                decodedText += "&"
                remainder = afterAmpersand
            }
        }
        decodedText += remainder
        return decodedText
    }

    private static func replacement(forEntityNamed entityName: String) -> String? {
        if entityName.hasPrefix("#") {
            let numberText = entityName.dropFirst()
            let codePoint: UInt32?
            if numberText.first == "x" || numberText.first == "X" {
                codePoint = UInt32(numberText.dropFirst(), radix: 16)
            } else {
                codePoint = UInt32(numberText, radix: 10)
            }
            guard let codePoint, codePoint != 0, let scalar = Unicode.Scalar(codePoint) else { return nil }
            return codePoint == 0xA0 ? " " : String(Character(scalar))
        }
        return namedEntities[entityName] ?? namedEntities[entityName.lowercased()]
    }

    static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Right-trims lines, removes empty bullets/headings, collapses blank runs.
    static func cleanedUp(_ text: String) -> String {
        var cleanedLines: [String] = []
        var previousLineWasBlank = true
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            while line.last?.isWhitespace == true { line.removeLast() }
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let isEmptyMarker = trimmedLine == "-" || (!trimmedLine.isEmpty && trimmedLine.allSatisfy { $0 == "#" }) || trimmedLine == "|"
            if isEmptyMarker { continue }
            let isBlank = trimmedLine.isEmpty
            if isBlank && previousLineWasBlank { continue }
            cleanedLines.append(line)
            previousLineWasBlank = isBlank
        }
        while cleanedLines.last?.isEmpty == true { cleanedLines.removeLast() }
        return cleanedLines.joined(separator: "\n")
    }
}

/// Accumulates readable text with pending line breaks and line prefixes, so
/// block elements produce clean blank lines instead of stray whitespace.
nonisolated struct ReadableTextBuilder {
    private(set) var text = ""
    private var pendingNewlineCount = 0
    private var pendingLinePrefix: String?

    var currentLineHasContent: Bool {
        pendingNewlineCount == 0 && !text.isEmpty && text.last != "\n"
    }

    mutating func requestBreak(newlineCount: Int) {
        guard !text.isEmpty else { return }
        pendingNewlineCount = max(pendingNewlineCount, newlineCount)
    }

    mutating func setLinePrefix(_ linePrefix: String) {
        pendingLinePrefix = linePrefix
    }

    mutating func appendRaw(_ rawText: String) {
        text += rawText
    }

    mutating func appendText(_ newText: String, isPreformatted: Bool) {
        var textToAppend: String
        if isPreformatted {
            textToAppend = newText
        } else {
            textToAppend = newText.replacingOccurrences(of: "\u{00A0}", with: " ")
            let startsWithWhitespace = textToAppend.first?.isWhitespace == true
            let endsWithWhitespace = textToAppend.last?.isWhitespace == true
            let collapsedText = BrainHTMLTextConverter.collapsedWhitespace(textToAppend)
            guard !collapsedText.isEmpty else {
                // Whitespace between inline elements still separates words.
                if startsWithWhitespace && currentLineHasContent && text.last != " " { text += " " }
                return
            }
            textToAppend = (startsWithWhitespace ? " " : "") + collapsedText + (endsWithWhitespace ? " " : "")
        }
        guard !textToAppend.isEmpty else { return }

        let isStartingNewLine = pendingNewlineCount > 0 || text.isEmpty || text.last == "\n"
        if pendingNewlineCount > 0 {
            while text.last == " " { text.removeLast() }
            text += String(repeating: "\n", count: pendingNewlineCount)
            pendingNewlineCount = 0
        }
        if isStartingNewLine && !isPreformatted {
            textToAppend = String(textToAppend.drop(while: { $0 == " " }))
            guard !textToAppend.isEmpty else { return }
        }
        if let linePrefix = pendingLinePrefix {
            text += linePrefix
            pendingLinePrefix = nil
        } else if !isStartingNewLine && text.last == " " && textToAppend.first == " " {
            textToAppend.removeFirst()
        }
        text += textToAppend
    }
}
