import Foundation
import Testing
@testable import LocalTutor

struct MarkdownParserTests {
    @Test
    func boldOnlyLinesBecomeHeadings() {
        let blocks = MarkdownParser.parse("""
        **mHC: Key Concepts**

        - **mHC**: This is the main topic.
        **Observed Problem (Instability)**
        Text.
        """)

        guard case .heading(let firstLevel, let firstText, _) = blocks.first else {
            Issue.record("Expected first block to be a heading")
            return
        }

        #expect(firstLevel == 2)
        #expect(firstText == "mHC: Key Concepts")
        #expect(blocks.contains { block in
            if case .heading(let level, let text, _) = block {
                return level == 2 && text == "Observed Problem (Instability)"
            }
            return false
        })
    }

    @Test
    func boldHeadingDoesNotMergeIntoPreviousParagraph() {
        let blocks = MarkdownParser.parse("""
        Intro text.
        **Model Parameters Compared**
        More text.
        """)

        #expect(blocks.count == 3)

        guard case .heading(let level, let text, _) = blocks[1] else {
            Issue.record("Expected middle block to be a heading")
            return
        }

        #expect(level == 2)
        #expect(text == "Model Parameters Compared")
    }

    @Test
    func inlineLatexRendersInsideMarkdownBlocks() {
        let blocks = MarkdownParser.parse("""
        # $\\text{mHC Deepseek.pdf}$ Study Summary

        - **$\\text{mHC}$** ($\\mathrm{HC}$): Uses $x_i^2 = \\frac{\\alpha}{2}$.
        - $\\square$ Define **$\\operatorname{mHC}$**.
        """)

        guard case .heading(_, let heading, _) = blocks.first else {
            Issue.record("Expected first block to be a heading")
            return
        }

        #expect(heading == "mHC Deepseek.pdf Study Summary")

        guard blocks.count > 1, case .bulletList(let items, _) = blocks[1] else {
            Issue.record("Expected second block to be a bullet list")
            return
        }

        let first = plainText(items[0].text)
        let second = plainText(items[1].text)

        #expect(first.contains("mHC (HC): Uses xᵢ² = α/2."))
        #expect(second.contains("☐ Define mHC."))
        #expect(first.contains("$") == false)
        #expect(first.contains("\\") == false)
        #expect(second.contains("$") == false)
        #expect(second.contains("\\") == false)
    }

    @Test
    func nestedBulletsKeepIndentationLevel() {
        let blocks = MarkdownParser.parse("""
        - Parent
            - Four-space child
          - Two-space child
        """)

        guard case .bulletList(let items, _) = blocks.first else {
            Issue.record("Expected bullet list")
            return
        }

        #expect(items.map(\.level) == [0, 1, 1])
    }

    private func plainText(_ attributed: AttributedString) -> String {
        String(attributed.characters)
    }

    @Test
    func streamingHealerClosesOrHidesUnfinishedInlineMarkup() {
        #expect(MarkdownStreamHealer.heal("The **pulmo") == "The **pulmo**")
        #expect(MarkdownStreamHealer.heal("The **pulmones** and *alv") == "The **pulmones** and *alv*")
        #expect(MarkdownStreamHealer.heal("Use `print(") == "Use `print(`")
        #expect(MarkdownStreamHealer.heal("Gas exchange **") == "Gas exchange")
        #expect(MarkdownStreamHealer.heal("Gas exchange [8") == "Gas exchange")
        #expect(MarkdownStreamHealer.heal("See [docs](https://exa") == "See")
        #expect(MarkdownStreamHealer.heal("Energy $E = mc") == "Energy")
        #expect(MarkdownStreamHealer.heal("Area is 2 * 3 and **bo") == "Area is 2 * 3 and **bo**")
        #expect(MarkdownStreamHealer.heal("- **Alveoli**: tiny sacs") == "- **Alveoli**: tiny sacs")
        #expect(MarkdownStreamHealer.heal("Intro\n-") == "Intro\n")
        #expect(MarkdownStreamHealer.heal("| Organ | Role |\n|---") == "")
        #expect(MarkdownStreamHealer.heal("| Organ | Role |\n|---|---|\n| Lungs | Ga") == "| Organ | Role |\n|---|---|\n")
        #expect(MarkdownStreamHealer.heal("```swift\nlet a = **b") == "```swift\nlet a = **b")
    }

    @Test
    func streamingRendererMatchesFullParseAndKeepsBlockIdentity() {
        let answer = """
        ## Lungs

        The **lungs** exchange gases [1].

        1. Oxygen enters
        2. Carbon dioxide leaves

        ```text
        a

        b
        ```

        | Part | Role |
        |---|---|
        | Alveoli | Exchange |
        """
        let renderer = MarkdownStreamRenderer()
        var previousIDs: [String] = []
        for length in stride(from: 1, through: answer.count, by: 3) {
            let blocks = renderer.blocks(for: String(answer.prefix(length)), isStreaming: true, citationCount: 1)
            let ids = blocks.map(\.id)
            let stableCount = max(0, min(previousIDs.count, ids.count) - 1)
            #expect(Array(ids.prefix(stableCount)) == Array(previousIDs.prefix(stableCount)))
            for block in blocks {
                if case .paragraph(let text, _) = block {
                    #expect(!String(text.characters).contains("**"))
                }
            }
            previousIDs = ids
        }

        let streamedEnd = renderer.blocks(for: answer + "\n", isStreaming: true, citationCount: 1)
        let final = MarkdownStreamRenderer().blocks(for: answer, isStreaming: false, citationCount: 1)
        #expect(streamedEnd == final)
        #expect(final.map(\.id) == MarkdownParser.parse(CitationLinker.linkify(answer, validRange: 1...1)).map(\.id))
    }

    @Test
    func stableBoundaryIgnoresBlankLinesInsideCodeFences() {
        let text = "Intro\n\n```\na\n\nb"
        let boundary = MarkdownStreamRenderer.stableBoundary(in: text)
        #expect(String(text[..<boundary]) == "Intro\n\n")
    }

    @Test
    func numberedItemsKeepTheirWrittenNumbersAcrossBlankLines() {
        let blocks = MarkdownParser.parse("1. First\n\n2. Second")
        let numbers = blocks.compactMap { block -> Int? in
            if case .numberedList(let items, _) = block { return items.first?.number }
            return nil
        }
        #expect(numbers == [1, 2])
    }

    @Test
    func revealPacerSmoothsBurstsAndAlwaysCatchesUp() {
        var pacer = RevealPacer()
        var backlog = 120
        var perFrame: [Int] = []
        for _ in 0..<120 where backlog > 0 {
            let count = pacer.charactersToReveal(backlog: backlog, elapsed: 1.0 / 60)
            perFrame.append(count)
            backlog -= count
        }
        #expect(backlog == 0)
        #expect(perFrame.first! < 120 / 4)
        #expect(perFrame.count < 60)
        #expect(perFrame.allSatisfy { $0 >= 0 })
    }
}
