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
}
