//
//  HumanMessageRowViewTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

import CustomDump
@testable import ConductorChat
import Testing

@Suite("Human message row view")
struct HumanMessageRowViewTests {
    @Test("File references preserve encoded paths and strip review line suffixes")
    @MainActor
    func fileReferences() {
        let references = HumanMessageRowView.fileReferences(
            in: "Review @⟦Transcript.md⟧(.context%2Fattachments%2Fabc%2FTranscript.md), @⟦Added.swift +10-12⟧(.context%2Fattachments%2Fcomments%2Fadded.md), and @⟦Removed.swift -10⟧(.context%2Fattachments%2Fcomments%2Fremoved.md)."
        )

        expectNoDifference(
            references.map(\.label),
            ["Transcript.md", "Added.swift", "Removed.swift"]
        )
        expectNoDifference(
            references.map(\.encodedPath),
            [
                ".context%2Fattachments%2Fabc%2FTranscript.md",
                ".context%2Fattachments%2Fcomments%2Fadded.md",
                ".context%2Fattachments%2Fcomments%2Fremoved.md",
            ]
        )
        expectNoDifference(
            references.map(\.kind),
            [.file, .file, .file]
        )
    }

    @Test("Skill Markdown links become skill file references")
    @MainActor
    func skillReferences() {
        let content = """
            Run [update-with-main](/Users/gannonprudomme/.agents/skills/update-with-main/SKILL.md), then review [the docs](https://example.com).
            """
        let references = HumanMessageRowView.fileReferences(in: content)

        expectNoDifference(references.map(\.label), ["update-with-main"])
        expectNoDifference(
            references.map(\.encodedPath),
            ["/Users/gannonprudomme/.agents/skills/update-with-main/SKILL.md"]
        )
        expectNoDifference(references.map(\.kind), [.skill])
        #expect(
            HumanMessageRowView.displayedContent(content) == """
                Run update-with-main, then review [the docs](https://example.com).
                """
        )
    }

    @Test("Displayed content replaces file-reference markup with chip labels")
    @MainActor
    func displayedContent() {
        let content = """
            @⟦Screen Recording.mov⟧(.context%2Fattachments%2Fvideo.mov)

            Review @⟦Chat.swift +10-12⟧(.context%2Fattachments%2Fcomments%2Fchat.md).
            """

        #expect(
            HumanMessageRowView.displayedContent(content) == """
                Screen Recording.mov

                Review Chat.swift.
                """
        )
    }

    @Test("Incomplete markers remain ordinary message text")
    @MainActor
    func incompleteMarkers() {
        let content = "Keep @⟦unfinished.txt⟧ and @⟦missing-path.txt⟧() unchanged."

        #expect(HumanMessageRowView.fileReferences(in: content).isEmpty)
        #expect(HumanMessageRowView.displayedContent(content) == content)
    }
}
