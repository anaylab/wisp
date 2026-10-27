//
//  BrainTextChunker.swift
//  leanring-buddy
//
//  Splits a source's text into pieces small enough for one model call each.
//  Pure, so it is testable without a model.
//
//  The default model is a local 3B with an 8k context, and the system prompt
//  (SCHEMA.md + the edit rules) already takes a good part of it, so a chunk is
//  ~2500 characters. Chunks follow the text's own structure — a heading starts
//  a new chunk when the current one is already reasonably full, paragraphs are
//  kept whole, and an overlong paragraph is split between sentences — because
//  a fact cut in half is a fact the model can't read.
//
//  A very long source (a book-length PDF) would mean dozens of model calls in
//  a row at background priority. Past `maximumChunkCount` the chunks are
//  sampled evenly across the whole text instead, and the result says so, so
//  the user is told the brain skimmed rather than read it.
//

import Foundation

nonisolated struct BrainTextChunk: Equatable, Sendable {
    /// Position among all the chunks the text split into (before sampling), 0-based.
    var index: Int
    var text: String
    /// The nearest markdown heading above the chunk's start, if the chunk
    /// doesn't begin with one — tells the model what a mid-section chunk is about.
    var continuedHeading: String?
}

nonisolated struct BrainTextChunkingResult: Equatable, Sendable {
    /// The chunks to read, in text order.
    var chunks: [BrainTextChunk]
    /// How many chunks the whole text split into.
    var totalChunkCount: Int

    /// True when only an even sample of the chunks is being read.
    var wasSampled: Bool { chunks.count < totalChunkCount }
}

nonisolated enum BrainTextChunker {
    static let targetChunkCharacters = 2500
    static let maximumChunkCount = 24
    /// A heading only starts a new chunk once the current one is at least this
    /// full, so a run of short sections isn't spread over many tiny calls.
    static let minimumFillBeforeHeadingBreak = 0.4

    static func chunk(
        _ text: String,
        targetChunkCharacters: Int = BrainTextChunker.targetChunkCharacters,
        maximumChunkCount: Int = BrainTextChunker.maximumChunkCount
    ) -> BrainTextChunkingResult {
        let blocks = textBlocks(in: text, targetChunkCharacters: targetChunkCharacters)
        guard !blocks.isEmpty else { return BrainTextChunkingResult(chunks: [], totalChunkCount: 0) }

        var allChunks: [BrainTextChunk] = []
        var currentChunkBlocks: [String] = []
        var currentChunkCharacterCount = 0
        var headingAtCurrentChunkStart: String?
        var mostRecentHeading: String?

        func flushCurrentChunk() {
            guard !currentChunkBlocks.isEmpty else { return }
            let chunkText = currentChunkBlocks.joined(separator: "\n\n")
            let startsWithHeading = headingText(ofBlock: currentChunkBlocks[0]) != nil
            allChunks.append(BrainTextChunk(
                index: allChunks.count,
                text: chunkText,
                continuedHeading: startsWithHeading ? nil : headingAtCurrentChunkStart
            ))
            currentChunkBlocks = []
            currentChunkCharacterCount = 0
        }

        for block in blocks {
            let blockHeading = headingText(ofBlock: block)
            let separatorCharacterCount = currentChunkBlocks.isEmpty ? 0 : 2
            let wouldOverflow = currentChunkCharacterCount + separatorCharacterCount + block.count > targetChunkCharacters
            let isFullEnoughForHeadingBreak = Double(currentChunkCharacterCount)
                >= Double(targetChunkCharacters) * minimumFillBeforeHeadingBreak
            if !currentChunkBlocks.isEmpty && (wouldOverflow || (blockHeading != nil && isFullEnoughForHeadingBreak)) {
                flushCurrentChunk()
            }
            if currentChunkBlocks.isEmpty {
                headingAtCurrentChunkStart = mostRecentHeading
            }
            currentChunkBlocks.append(block)
            currentChunkCharacterCount += (currentChunkBlocks.count > 1 ? 2 : 0) + block.count
            if let blockHeading { mostRecentHeading = blockHeading }
        }
        flushCurrentChunk()

        return BrainTextChunkingResult(
            chunks: evenlySampled(allChunks, maximumCount: maximumChunkCount),
            totalChunkCount: allChunks.count
        )
    }

    /// At most `maximumCount` items spread evenly from first to last, in order.
    static func evenlySampled<Element>(_ items: [Element], maximumCount: Int) -> [Element] {
        guard items.count > maximumCount else { return items }
        guard maximumCount > 1 else { return Array(items.prefix(max(0, maximumCount))) }
        var sampledIndices: [Int] = []
        let lastIndex = Double(items.count - 1)
        for sampleNumber in 0..<maximumCount {
            let index = Int((Double(sampleNumber) * lastIndex / Double(maximumCount - 1)).rounded())
            if sampledIndices.last != index { sampledIndices.append(index) }
        }
        return sampledIndices.map { items[$0] }
    }

    // MARK: Blocks

    /// Paragraphs and headings, each no longer than the target (overlong
    /// paragraphs are split between sentences).
    static func textBlocks(in text: String, targetChunkCharacters: Int) -> [String] {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [String] = []
        var currentParagraphLines: [String] = []

        func flushParagraph() {
            let paragraph = currentParagraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            currentParagraphLines = []
            guard !paragraph.isEmpty else { return }
            if paragraph.count <= targetChunkCharacters {
                blocks.append(paragraph)
            } else {
                blocks.append(contentsOf: splitOverlongParagraph(paragraph, targetChunkCharacters: targetChunkCharacters))
            }
        }

        for line in normalizedText.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                flushParagraph()
            } else if headingText(ofBlock: trimmedLine) != nil {
                // A heading is its own block, so a chunk can start on it.
                flushParagraph()
                blocks.append(trimmedLine)
            } else {
                currentParagraphLines.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// The heading text if the block is a markdown heading line (`# …` to `###### …`).
    static func headingText(ofBlock block: String) -> String? {
        guard block.hasPrefix("#"), !block.contains("\n") else { return nil }
        let hashCount = block.prefix(while: { $0 == "#" }).count
        guard hashCount <= 6 else { return nil }
        let remainder = block.dropFirst(hashCount)
        guard remainder.first == " " else { return nil }
        let heading = remainder.trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    /// Splits a paragraph longer than the target between sentences; a single
    /// sentence that is still too long is split at the last space that fits.
    static func splitOverlongParagraph(_ paragraph: String, targetChunkCharacters: Int) -> [String] {
        var pieces: [String] = []
        var currentPiece = ""
        for sentence in sentences(in: paragraph) {
            if currentPiece.count + sentence.count <= targetChunkCharacters {
                currentPiece += sentence
                continue
            }
            if !currentPiece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(currentPiece.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            currentPiece = ""
            var remainingSentence = Substring(sentence)
            while remainingSentence.count > targetChunkCharacters {
                let window = remainingSentence.prefix(targetChunkCharacters)
                let splitIndex = window.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? window.endIndex
                let piece = remainingSentence[remainingSentence.startIndex..<splitIndex]
                let trimmedPiece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPiece.isEmpty { pieces.append(trimmedPiece) }
                remainingSentence = remainingSentence[splitIndex...].drop(while: { $0 == " " || $0 == "\n" })
                if piece.isEmpty { break }
            }
            currentPiece = String(remainingSentence)
        }
        let finalPiece = currentPiece.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalPiece.isEmpty { pieces.append(finalPiece) }
        return pieces
    }

    /// Sentences with their trailing punctuation and whitespace kept, so
    /// joining them back reproduces the paragraph. A line break also ends a
    /// "sentence" (lists and tables have no full stops).
    static func sentences(in paragraph: String) -> [String] {
        var sentences: [String] = []
        var currentSentence = ""
        let characters = Array(paragraph)
        for (index, character) in characters.enumerated() {
            currentSentence.append(character)
            let nextCharacter: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            let isSentenceEnd = (character == "." || character == "!" || character == "?" || character == "。")
                && (nextCharacter == nil || nextCharacter == " " || nextCharacter == "\n")
            if character == "\n" || isSentenceEnd {
                // Keep the following space with this sentence.
                sentences.append(currentSentence)
                currentSentence = ""
            } else if character == " ", let lastSentence = sentences.last, currentSentence == " " {
                sentences[sentences.count - 1] = lastSentence + " "
                currentSentence = ""
            }
        }
        if !currentSentence.isEmpty { sentences.append(currentSentence) }
        return sentences
    }
}
