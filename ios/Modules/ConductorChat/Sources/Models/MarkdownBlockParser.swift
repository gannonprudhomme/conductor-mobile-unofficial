//
//  MarkdownBlockParser.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/11/26.
//  Entirely written (and optimized) by Codex. Reviewed by me (mostly)
//

import Foundation
@preconcurrency import Markdown

/// Splits one assistant response into top-level Markdown block groups that SwiftUI can
/// create lazily. Chunking only at AST block boundaries keeps constructs such as lists,
/// tables, and code fences intact; if those boundaries cannot be recovered exactly, the
/// parser returns the original source as one safe fallback chunk.
enum MarkdownBlockParser {
    // NOTE: This was determined by Codex through repeated experiments on reducing hitches & hangs on the Chat screen
    //
    // If we split EVERY chunk possible the performance actually got worse, but if we don't split them at all really big chunks
    // give terrible performance
    //
    // Thus we only split markdown messages into chunks over 2k characters
    //
    // (Codex-written portion:)
    /// A chunk is kept near this size so one SwiftUI row does not have to lay out an arbitrarily large Markdown document.
    // A single indivisible Markdown block may exceed the budget because preserving its structure is more important than size.
    private static let maximumCharactersPerRenderChunk = 2_000

    struct Chunk: Equatable {
        let source: String
        /// Used to reconstruct the margin before this chunk after it becomes its own row.
        let firstBlockKind: BoundaryKind
        /// Used when choosing the margin before the following chunk.
        let lastBlockKind: BoundaryKind
    }

    /// The Markdown block categories that affect spacing across a chunk boundary.
    enum BoundaryKind: Equatable {
        /// A block that uses MarkdownUI's normal one-em separation.
        case standard
        /// A heading whose larger leading margin must be restored between lazy rows.
        case heading
        /// A horizontal rule whose two-em margin must be restored between lazy rows.
        case thematicBreak
    }

    /// Calculates the independently renderable rows for one assistant Markdown message.
    ///
    /// This function greedily packs complete top-level AST blocks into chunks near the
    /// character budget. It never splits inside a list, table, block quote, or code fence.
    /// Each candidate chunk is then reparsed on its own to prove that detaching it from the
    /// full document did not change its Markdown meaning.
    static func calculateRenderChunks(forMarkdown source: String) -> [Chunk] {
        guard source.count > maximumCharactersPerRenderChunk else {
            // Small messages do not benefit from chunking. Keeping their original source in
            // one row also avoids paying for an AST traversal solely to rediscover that fact.
            return chunksWithoutSplitting(for: source)
        }

        let fullDocument = Markdown.Document(
            parsing: source,
            options: [.disableSmartOpts]
        )
        let topLevelBlocks = Array(fullDocument.children)
        guard !topLevelBlocks.isEmpty else {
            // A document made only of whitespace or reference definitions has no visible
            // top-level blocks. Preserve its exact source instead of silently returning no rows.
            return chunksWithoutSplitting(for: source)
        }

        // Swift Markdown reports a block's location as one-based line and UTF-8 byte-column
        // values. Build a lookup from each line number to its byte offset in the original
        // source so those locations can become safe ArraySlice ranges.
        let sourceUTF8Bytes = Array(source.utf8)
        let lineFeedByte = UInt8(ascii: "\n")
        let lineStartByteOffsets = sourceUTF8Bytes.indices.reduce(into: [0]) { offsets, index in
            // LF also terminates CRLF lines. A document using lone CR line endings cannot
            // produce a complete lookup and will deliberately take the safe fallback below.
            if sourceUTF8Bytes[index] == lineFeedByte {
                offsets.append(index + 1)
            }
        }

        let blockByteRanges = topLevelBlocks.compactMap { block in
            block.range.flatMap { sourceRange in
                utf8ByteRange(
                    for: sourceRange,
                    lineStartByteOffsets: lineStartByteOffsets,
                    sourceByteCount: sourceUTF8Bytes.count
                )
            }
        }
        guard blockByteRanges.count == topLevelBlocks.count,
              let documentSupportingSource = collectSupportingSourceOutsideBlocks(
                blockByteRanges,
                in: sourceUTF8Bytes
              ) else {
            // Never slice with incomplete, overlapping, or out-of-bounds parser metadata.
            // Rendering the original message eagerly is slower but cannot lose user content.
            return chunksWithoutSplitting(for: source)
        }

        var renderChunks: [Chunk] = []
        var firstBlockIndex = 0

        // This is a `while`, not a `for`, because one output chunk consumes a variable number
        // of input blocks. After greedily finding that group, the loop must jump directly to
        // the first block not consumed by the chunk rather than advance by exactly one block.
        while firstBlockIndex < topLevelBlocks.count {
            // `endBlockIndex` is exclusive. Starting one position after `firstBlockIndex`
            // guarantees progress and keeps one oversized block intact instead of splitting it.
            var endBlockIndex = firstBlockIndex + 1

            // Grow the candidate one complete block at a time. This inner `while` stops at the
            // first block that would exceed the budget, leaving it for the next outer iteration.
            while endBlockIndex < topLevelBlocks.count {
                let candidateByteRange = blockByteRanges[firstBlockIndex].lowerBound..<blockByteRanges[endBlockIndex].upperBound
                let candidateSource = String(
                    decoding: sourceUTF8Bytes[candidateByteRange],
                    as: UTF8.self
                )
                // The performance budget uses user-visible Swift characters. UTF-8 offsets
                // are used only to extract an exact, encoding-safe slice of the source.
                guard candidateSource.count <= maximumCharactersPerRenderChunk else {
                    break
                }
                endBlockIndex += 1
            }

            let originalBlocks = topLevelBlocks[firstBlockIndex..<endBlockIndex]
            let chunkByteRange = blockByteRanges[firstBlockIndex].lowerBound..<blockByteRanges[endBlockIndex - 1].upperBound
            let exactChunkSource = String(
                decoding: sourceUTF8Bytes[chunkByteRange],
                as: UTF8.self
            )

            // A detached source range can parse differently from the same range inside the full
            // document. The common example is `[text][label]` losing a reference definition.
            let independentlyParsedBlocks = Array(
                Markdown.Document(
                    parsing: exactChunkSource,
                    options: [.disableSmartOpts]
                ).children
            )
            let chunkSource: String
            if hasSameBlockStructure(originalBlocks, independentlyParsedBlocks) {
                // The exact authored slice is already self-contained, so use it unchanged.
                chunkSource = exactChunkSource
            } else {
                // Reference definitions are semantically important but do not appear as top-level
                // AST blocks. Append source found outside the visible block ranges, then reparse.
                let chunkWithSupportingSource =
                    exactChunkSource + "\n\n" + documentSupportingSource
                let blocksWithSupportingSource = Array(
                    Markdown.Document(
                        parsing: chunkWithSupportingSource,
                        options: [.disableSmartOpts]
                    ).children
                )
                guard hasSameBlockStructure(originalBlocks, blocksWithSupportingSource) else {
                    // If supporting source cannot restore the original structure, this algorithm
                    // cannot prove the split is safe. Keep the message whole instead of changing it.
                    return chunksWithoutSplitting(for: source)
                }
                chunkSource = chunkWithSupportingSource
            }

            renderChunks.append(
                .init(
                    source: chunkSource,
                    firstBlockKind: boundaryKind(for: topLevelBlocks[firstBlockIndex]),
                    lastBlockKind: boundaryKind(for: topLevelBlocks[endBlockIndex - 1])
                )
            )
            firstBlockIndex = endBlockIndex
        }
        return renderChunks
    }

    /// Converts Swift Markdown's one-based line/UTF-8-column range into a flat byte range.
    ///
    /// This is used before slicing the original source so chunks preserve the user's exact
    /// Markdown spelling and whitespace instead of regenerating source from the AST.
    private static func utf8ByteRange(
        for sourceRange: SourceRange,
        lineStartByteOffsets: [Int],
        sourceByteCount: Int
    ) -> Range<Int>? {
        // Array indices are zero-based, while SourceLocation line numbers are one-based.
        let lowerLineIndex = sourceRange.lowerBound.line - 1
        let upperLineIndex = sourceRange.upperBound.line - 1

        // Validate line and column metadata before indexing the line-offset table. Returning
        // `nil` makes the caller choose the unsplit fallback instead of risking a bad slice.
        guard lowerLineIndex >= 0,
              upperLineIndex >= 0,
              lowerLineIndex < lineStartByteOffsets.count,
              upperLineIndex < lineStartByteOffsets.count,
              sourceRange.lowerBound.column > 0,
              sourceRange.upperBound.column > 0 else {
            return nil
        }

        let lowerByteOffset = lineStartByteOffsets[lowerLineIndex] + sourceRange.lowerBound.column - 1
        let upperByteOffset = lineStartByteOffsets[upperLineIndex] + sourceRange.upperBound.column - 1

        // The upper location is exclusive. These checks ensure the resulting range is ordered
        // and fully contained in the original UTF-8 source before it is used as a subscript.
        guard lowerByteOffset >= 0,
              upperByteOffset >= lowerByteOffset,
              upperByteOffset <= sourceByteCount else {
            return nil
        }

        return lowerByteOffset..<upperByteOffset
    }

    /// Collects source bytes that Swift Markdown did not assign to visible top-level blocks.
    ///
    /// Most of these bytes are separators and outer whitespace, but they can also contain
    /// reference definitions. This source is appended only when a detached chunk fails the
    /// first structural reparse and needs document-level context to retain its meaning.
    private static func collectSupportingSourceOutsideBlocks(
        _ blockByteRanges: [Range<Int>],
        in sourceUTF8Bytes: [UInt8]
    ) -> String? {
        var nextUnclaimedByteOffset = 0
        var supportingBytes: [UInt8] = []

        for blockByteRange in blockByteRanges {
            // Ranges must be sorted and non-overlapping. If parser metadata moves backward,
            // slicing would duplicate or omit bytes, so the caller must use the safe fallback.
            guard blockByteRange.lowerBound >= nextUnclaimedByteOffset else {
                return nil
            }

            // Capture the gap before this visible block, then resume after the block itself.
            supportingBytes.append(
                contentsOf: sourceUTF8Bytes[nextUnclaimedByteOffset..<blockByteRange.lowerBound]
            )
            nextUnclaimedByteOffset = blockByteRange.upperBound
        }

        // Source after the last visible block can contain trailing reference definitions.
        supportingBytes.append(
            contentsOf: sourceUTF8Bytes[nextUnclaimedByteOffset..<sourceUTF8Bytes.count]
        )
        return String(decoding: supportingBytes, as: UTF8.self)
    }

    /// Classifies the margin behavior at a chunk's first or last block boundary.
    ///
    /// The search is recursive because a top-level block quote or list can contain headings
    /// and thematic breaks. The classification is used later to reconstruct MarkdownUI's
    /// collapsed margins after one document has been split into separate SwiftUI rows.
    private static func boundaryKind(for block: Markup) -> BoundaryKind {
        if block is ThematicBreak {
            return .thematicBreak
        }

        var containsHeading = block is Heading
        for child in block.children {
            switch boundaryKind(for: child) {
            case .thematicBreak:
                // A thematic break has the largest margin, so it takes priority over a
                // heading found elsewhere inside the same container block.
                return .thematicBreak
            case .heading:
                // Remember the heading, but keep searching in case a later descendant is
                // a thematic break and needs the higher-priority spacing classification.
                containsHeading = true
            case .standard:
                break
            }
        }
        return containsHeading ? .heading : .standard
    }

    /// Returns whether a detached source reparses into the same block tree as the full document.
    ///
    /// This guards against semantic changes that are invisible in the raw slice. For example,
    /// a reference-style link can become plain text when its definition lives elsewhere.
    private static func hasSameBlockStructure(
        _ originalBlocks: ArraySlice<Markup>,
        _ reparsedBlocks: [Markup]
    ) -> Bool {
        // `zip` silently stops at the shorter collection, so compare counts first to ensure
        // every original block has exactly one reparsed counterpart.
        guard originalBlocks.count == reparsedBlocks.count else {
            return false
        }

        return zip(originalBlocks, reparsedBlocks).allSatisfy { originalBlock, reparsedBlock in
            originalBlock.hasSameStructure(as: reparsedBlock)
        }
    }

    /// Returns the safe result used when chunking is unnecessary or cannot be proven correct.
    ///
    /// A nonempty source stays in one eagerly rendered row, eliminating chunk boundaries and
    /// therefore any need for special boundary spacing. Empty source produces no render row.
    private static func chunksWithoutSplitting(for source: String) -> [Chunk] {
        guard !source.isEmpty else {
            return []
        }

        return [
            .init(
                source: source,
                firstBlockKind: .standard,
                lastBlockKind: .standard
            ),
        ]
    }
}
