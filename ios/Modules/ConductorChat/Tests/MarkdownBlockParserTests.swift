//
//  MarkdownBlockParserTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import CustomDump
import Foundation
@testable import ConductorChat
import Testing

@Suite("Markdown block parser")
struct MarkdownBlockParserTests {
    private let characterBudget = 2_000

    @Test("Empty Markdown has no chunks")
    func emptyMarkdown() {
        expectNoDifference(MarkdownBlockParser.calculateRenderChunks(forMarkdown: ""), [])
    }

    @Test("Sources at or below the character budget stay whole")
    func sourcesWithinCharacterBudget() {
        for source in [
            "A short paragraph.",
            String(repeating: "a", count: characterBudget),
        ] {
            expectNoDifference(
                MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
                [standardChunk(source)]
            )
        }
    }

    @Test("Oversized Markdown without AST blocks falls back to its exact source")
    func oversizedWhitespaceFallback() {
        let source = String(repeating: " ", count: characterBudget + 1)

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
            [standardChunk(source)]
        )
    }

    @Test("Whole blocks are packed greedily through the exact character budget")
    func exactCharacterBudgetBoundary() {
        let first = String(repeating: "a", count: 999)
        let second = String(repeating: "b", count: 999)
        let third = "Tail"
        let source = [first, second, third].joined(separator: "\n\n")

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
            [
                standardChunk(first + "\n\n" + second),
                standardChunk(third),
            ]
        )
    }

    @Test("A candidate one character over budget starts a new chunk")
    func overCharacterBudgetBoundary() {
        let first = String(repeating: "a", count: 999)
        let second = String(repeating: "b", count: 1_000)
        let third = "Tail"
        let source = [first, second, third].joined(separator: "\n\n")

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
            [
                standardChunk(first),
                standardChunk(second + "\n\n" + third),
            ]
        )
    }

    @Test("A single oversized block remains intact")
    func oversizedAtomicBlock() {
        let source = "```swift\n"
            + String(repeating: "let value = 1\n", count: 200)
            + "```"

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
            [standardChunk(source)]
        )
    }

    @Test(
        "Structured blocks remain intact at chunk boundaries",
        arguments: [
            "- First\n- Second",
            "> Quoted paragraph",
            "| Name | Value |\n| --- | --- |\n| One | Two |",
            "```swift\nlet value = 1\n```",
        ]
    )
    func structuredBlocksRemainAtomic(_ block: String) {
        let oversizedParagraph = String(repeating: "a", count: characterBudget + 1)
        let source = [oversizedParagraph, block, oversizedParagraph]
            .joined(separator: "\n\n")
        let extractedBlock = block.hasPrefix("- ") ? block + "\n" : block

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source).map(\.source),
            [oversizedParagraph, extractedBlock, oversizedParagraph]
        )
    }

    @Test("Oversized structured blocks are never split internally")
    func oversizedStructuredBlocks() throws {
        let blocks = [
            "```swift\n" + String(repeating: "let value = 1\n", count: 200) + "```",
            (1...250).map { "- Item \($0) with content" }.joined(separator: "\n"),
            (1...250).map { "> Quoted line \($0)" }.joined(separator: "\n"),
            "| Name | Value |\n| --- | --- |\n"
                + (1...150).map { "| Row \($0) | Value \($0) |" }.joined(separator: "\n"),
        ]

        for block in blocks {
            let trailingParagraph = "After the structured block."
            let source = block + "\n\n" + trailingParagraph
            let chunks = MarkdownBlockParser.calculateRenderChunks(forMarkdown: source)
            let firstChunk = try #require(chunks.first)

            #expect(block.count > characterBudget)
            #expect(chunks.count == 2)
            #expect(firstChunk.source.hasPrefix(block))
            #expect(source.hasPrefix(firstChunk.source))
            #expect(try #require(chunks.last).source == trailingParagraph)
        }
    }

    @Test("An unclosed oversized code fence safely remains one block")
    func malformedOversizedCodeFence() {
        let source = "```swift\n"
            + Array(repeating: "let value = 1", count: 200).joined(separator: "\n")

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
            [standardChunk(source)]
        )
    }

    @Test("Authored whitespace and hard line breaks are preserved byte for byte")
    func authoredWhitespace() {
        let firstBlock = "First line.  \nSecond line."
        let separator = "\n \n"
        let secondBlock = "    indented code"
        let oversizedParagraph = String(repeating: "a", count: characterBudget + 1)
        let source = firstBlock + separator + secondBlock + "\n\n" + oversizedParagraph

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source).map(\.source),
            [firstBlock + separator + secondBlock + "\n", oversizedParagraph]
        )
    }

    @Test("UTF-8 source ranges preserve multibyte characters exactly")
    func multibyteSourceRanges() {
        let first = "😀" + String(repeating: "é", count: 1_998)
        let second = "漢字"
        let source = first + "\n\n" + second

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source).map(\.source),
            [first, second]
        )
    }

    @Test("The character budget counts graphemes while extraction uses UTF-8 offsets")
    func graphemeBudgetWithMultibyteSourceRanges() {
        let grapheme = "e\u{301}"
        let first = String(repeating: grapheme, count: 900)
        let second = String(repeating: grapheme, count: 900)
        let third = String(repeating: grapheme, count: 300)
        let source = [first, second, third].joined(separator: "\n\n")

        #expect((first + "\n\n" + second).utf8.count > characterBudget)
        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source).map(\.source),
            [first + "\n\n" + second, third]
        )
    }

    @Test("CRLF line endings survive chunk extraction")
    func carriageReturnLineFeedSourceRanges() {
        let first = "😀" + String(repeating: "é", count: 1_998)
        let second = "漢字"
        let source = first + "\r\n\r\n" + second

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source).map(\.source),
            [first, second]
        )
    }

    @Test("Unsupported lone-CR line ranges safely fall back to the original source")
    func loneCarriageReturnFallback() {
        let first = String(repeating: "a", count: 1_100)
        let second = String(repeating: "b", count: 1_100)
        let source = first + "\r\r" + second

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
            [standardChunk(source)]
        )
    }

    @Test("Oversized definition-only Markdown safely falls back to the original source")
    func definitionOnlyFallback() {
        let source = (1...100)
            .map { "[key\($0)]: https://example.com/\($0)" }
            .joined(separator: "\n")

        #expect(source.count > characterBudget)
        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
            [standardChunk(source)]
        )
    }

    @Test("Reference definitions are copied into every detached chunk that needs them")
    func referenceDefinitions() throws {
        let definition = "[docs]: https://example.com"
        let firstLink = "Read [the first page][docs]."
        let secondLink = "Read [the second page][docs]."
        let oversizedParagraph = String(repeating: "a", count: characterBudget + 1)
        let source = [definition, firstLink, oversizedParagraph, secondLink]
            .joined(separator: "\n\n")
        let chunks = MarkdownBlockParser.calculateRenderChunks(forMarkdown: source)

        expectNoDifference(
            chunks.map(\.source).map { $0.contains(definition) },
            [true, false, true]
        )
        expectNoDifference(
            chunks.map(\.source).map { $0.components(separatedBy: definition).count - 1 },
            [1, 0, 1]
        )
        #expect(try #require(chunks.first).source.hasPrefix(firstLink))
        #expect(try #require(chunks.last).source.hasPrefix(secondLink))
    }

    @Test("A trailing reference definition is copied into its detached link chunk")
    func trailingReferenceDefinition() throws {
        let definition = "[docs]: https://example.com \"Documentation\""
        let link = "Read [documentation][docs]."
        let oversizedParagraph = String(repeating: "a", count: characterBudget + 1)
        let source = [oversizedParagraph, link, definition].joined(separator: "\n\n")
        let chunks = MarkdownBlockParser.calculateRenderChunks(forMarkdown: source)
        let linkChunk = try #require(chunks.last)

        #expect(linkChunk.source.hasPrefix(link))
        #expect(linkChunk.source.contains(definition))
        #expect(linkChunk.source.components(separatedBy: definition).count - 1 == 1)
    }

    @Test("Unrelated definitions do not pollute independently valid chunks")
    func unrelatedReferenceDefinition() throws {
        let definition = "[unused]: https://example.com"
        let inlineLink = "Read [documentation](https://example.com)."
        let oversizedParagraph = String(repeating: "a", count: characterBudget + 1)
        let source = [definition, inlineLink, oversizedParagraph].joined(separator: "\n\n")
        let inlineLinkChunk = try #require(MarkdownBlockParser.calculateRenderChunks(forMarkdown: source).first)

        #expect(inlineLinkChunk.source == inlineLink)
        #expect(!inlineLinkChunk.source.contains(definition))
    }

    @Test("Unrecoverable nested reference support falls back without data loss")
    func unrecoverableNestedReferenceDefinition() {
        let nestedDefinition = "> [docs]: https://example.com"
        let oversizedParagraph = String(repeating: "a", count: characterBudget + 1)
        let link = "Read [documentation][docs]."
        let source = [nestedDefinition, oversizedParagraph, link].joined(separator: "\n\n")

        expectNoDifference(
            MarkdownBlockParser.calculateRenderChunks(forMarkdown: source),
            [standardChunk(source)]
        )
    }

    @Test("Nested headings and thematic breaks retain their block kinds")
    func recursiveBlockKinds() {
        let oversizedParagraph = String(repeating: "a", count: characterBudget + 1)
        let nestedHeading = "> ## Nested heading"
        let nestedThematicBreak = "> ---"
        let source = [
            oversizedParagraph,
            nestedHeading,
            oversizedParagraph,
            nestedThematicBreak,
            oversizedParagraph,
        ].joined(separator: "\n\n")
        let chunks = MarkdownBlockParser.calculateRenderChunks(forMarkdown: source)

        expectNoDifference(
            chunks.map(\.firstBlockKind),
            [.standard, .heading, .standard, .thematicBreak, .standard]
        )
        expectNoDifference(chunks.map(\.lastBlockKind), chunks.map(\.firstBlockKind))
    }

    @Test("Coalesced chunks retain different first and last block kinds")
    func coalescedBlockKinds() {
        let oversizedParagraph = String(repeating: "a", count: characterBudget + 1)
        let headingThenParagraph = "## Heading\n\nParagraph"
        let paragraphThenThematicBreak = "Paragraph\n\n---"
        let source = [
            oversizedParagraph,
            headingThenParagraph,
            oversizedParagraph,
            paragraphThenThematicBreak,
            oversizedParagraph,
        ].joined(separator: "\n\n")
        let chunks = MarkdownBlockParser.calculateRenderChunks(forMarkdown: source)

        expectNoDifference(
            chunks.map { BlockKinds(first: $0.firstBlockKind, last: $0.lastBlockKind) },
            [
                BlockKinds(first: .standard, last: .standard),
                BlockKinds(first: .heading, last: .standard),
                BlockKinds(first: .standard, last: .standard),
                BlockKinds(first: .standard, last: .thematicBreak),
                BlockKinds(first: .standard, last: .standard),
            ]
        )
    }

    private struct BlockKinds: Equatable {
        let first: MarkdownBlockParser.BoundaryKind
        let last: MarkdownBlockParser.BoundaryKind
    }

    private func standardChunk(_ source: String) -> MarkdownBlockParser.Chunk {
        .init(source: source, firstBlockKind: .standard, lastBlockKind: .standard)
    }
}
