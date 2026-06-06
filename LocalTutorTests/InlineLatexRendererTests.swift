import Foundation
import Testing
@testable import LocalTutor

struct InlineLatexRendererTests {
    @Test
    func currencyDollarIsPreserved() {
        #expect(InlineLatexRenderer.render("Costs $5 today") == "Costs $5 today")
    }

    @Test
    func emptyMathDelimitersProduceNothing() {
        #expect(InlineLatexRenderer.render("before $$after") == "before after")
        #expect(InlineLatexRenderer.render("before $$ after") == "before  after")
    }

    @Test
    func leftRightBracesArePreserved() {
        let result = InlineLatexRenderer.render("$\\left\\{x\\right\\}$")
        #expect(result == "{x}")
    }

    @Test
    func leftParenPreserved() {
        let result = InlineLatexRenderer.render("$\\left(a+b\\right)$")
        #expect(result.contains("("))
        #expect(result.contains(")"))
    }

    @Test
    func bareBackslashInNonMathTextIsPreserved() {
        #expect(InlineLatexRenderer.render("C:\\Users\\notes") == "C:\\Users\\notes")
    }

    @Test
    func knownBareSymbolIsRendered() {
        #expect(InlineLatexRenderer.render("Use \\alpha value") == "Use α value")
    }

    @Test
    func fractionRendersAsSlash() {
        #expect(InlineLatexRenderer.render("$\\frac{a}{b}$") == "a/b")
    }

    @Test
    func superscriptRendersUnicode() {
        #expect(InlineLatexRenderer.render("$x^2$") == "x²")
    }

    @Test
    func subscriptRendersUnicode() {
        #expect(InlineLatexRenderer.render("$x_i$") == "xᵢ")
    }

    @Test
    func nestedGroupsRender() {
        #expect(InlineLatexRenderer.render("$\\sqrt{\\frac{a}{b}}$") == "√a/b")
    }

    @Test
    func invisibleLeftDotDelimiterIsDropped() {
        let result = InlineLatexRenderer.render("$\\left.x\\right|$")
        #expect(result == "x|")
    }
}
