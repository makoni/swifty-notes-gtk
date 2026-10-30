import Foundation
import Testing
@testable import SwiftyNotes

struct MathSpanExtractorTests {
    /// Runs the extractor and asserts the line-structure invariant on the
    /// way: the output must have exactly the input's line count.
    private func extract(_ markdown: String) -> MathSpanExtractor.Extraction {
        let result = MathSpanExtractor.extract(from: markdown)
        #expect(
            markdown.components(separatedBy: "\n").count == result.markdown.components(separatedBy: "\n").count,
            "line count must be preserved: \(markdown) -> \(result.markdown)",
        )
        return result
    }

    @Test("A long note read again is not extracted again; another text is")
    func aLongNoteReadAgainIsNotExtractedAgain() {
        let note = String(repeating: "Area $\\pi r^2$ of a circle.\n\n", count: 60)
        #expect(note.utf8.count >= MathSpanExtractor.minimumCachedLength)
        let first = MathSpanExtractor.extract(from: note)
        let passes = MathSpanExtractor.debugLongPassCount
        // The preview, the outline and the spell checker after one edit.
        let again = MathSpanExtractor.extract(from: note)
        _ = MathSpanExtractor.extract(from: "A short title $x$")
        let third = MathSpanExtractor.extract(from: note)
        #expect(MathSpanExtractor.debugLongPassCount == passes)
        #expect(again.spans == first.spans && third.markdown == first.markdown)
        let edited = MathSpanExtractor.extract(from: note + "More $y$.")
        #expect(MathSpanExtractor.debugLongPassCount == passes + 1)
        #expect(edited.spans.count == first.spans.count + 1)
    }

    @Test("Roots produce two inline spans")
    func rootsProduceTwoInlineSpans() {
        let result = extract("Roots $x^*$ and $y^*$ here")
        #expect(result.spans.count == 2)
        #expect(result.spans.map(\.tex) == ["x^*", "y^*"])
        #expect(result.spans.allSatisfy { !$0.isDisplay })
        #expect(
            result.markdown
                == "Roots \(MathSpanExtractor.placeholder(for: 0)) and \(MathSpanExtractor.placeholder(for: 1)) here",
        )
    }

    @Test("Set builder with braces is one inline span")
    func setBuilderIsOneInlineSpan() {
        let result = extract("Set $\\{x \\mid x>0\\}$")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].tex == "\\{x \\mid x>0\\}")
        #expect(!result.spans[0].isDisplay)
    }

    @Test("pmatrix keeps doubled backslashes")
    func pmatrixKeepsDoubledBackslashes() {
        let result = extract("A = $\\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix}$")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].tex == "\\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix}")
    }

    @Test("Two dollars around amounts are not math")
    func twoDollarsAroundAmountsAreNotMath() {
        let result = extract("It costs $5 and $10.")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "It costs $5 and $10.")
    }

    @Test("Thousands with commas are not math")
    func thousandsWithCommasAreNotMath() {
        let result = extract("$20,000 and $30,000")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "$20,000 and $30,000")
    }

    @Test("Escaped dollar is never a delimiter")
    func escapedDollarIsNeverADelimiter() {
        let result = extract("Price is \\$5")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "Price is \\$5")
    }

    @Test("Inline code span is verbatim")
    func inlineCodeSpanIsVerbatim() {
        let result = extract("`code $x$`")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "`code $x$`")
    }

    @Test("Fenced block is verbatim")
    func fencedBlockIsVerbatim() {
        let markdown = "```\n$x$\n```"
        let result = extract(markdown)
        #expect(result.spans.isEmpty)
        #expect(result.markdown == markdown)
    }

    @Test("Indented code is verbatim")
    func indentedCodeIsVerbatim() {
        let markdown = "\n    $x$\n"
        let result = extract(markdown)
        #expect(result.spans.isEmpty)
        #expect(result.markdown == markdown)
    }

    @Test("Multiline display math becomes one display span")
    func multilineDisplayMathBecomesOneDisplaySpan() {
        // Input: `$$\n\int_0^1 f\n$$` (the multiline literal carries no
        // trailing newline), so the span holds two newlines and the output
        // is the placeholder followed by those two (line count preserved).
        let result = extract("""
            $$
            \\int_0^1 f
            $$
            """)
        #expect(result.spans.count == 1)
        #expect(result.spans[0].isDisplay)
        #expect(result.spans[0].tex == "\\int_0^1 f")
        #expect(result.markdown == "\(MathSpanExtractor.placeholder(for: 0))\n\n")
    }

    @Test("Single-line display math becomes one display span")
    func singleLineDisplayMathBecomesOneDisplaySpan() {
        let result = extract("$$a=b$$")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].isDisplay)
        #expect(result.spans[0].tex == "a=b")
        #expect(result.markdown == MathSpanExtractor.placeholder(for: 0))
    }

    @Test("math fence is one display span")
    func mathFenceIsOneDisplaySpan() {
        let result = extract("```math\nx+y\n```")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].isDisplay)
        #expect(result.spans[0].tex == "x+y")
        #expect(result.markdown == "\(MathSpanExtractor.placeholder(for: 0))\n\n")
    }

    @Test("Display math with a blank line inside is not math")
    func displayMathWithBlankLineInsideIsNotMath() {
        let markdown = "$$\na\n\nb\n$$"
        let result = extract(markdown)
        #expect(result.spans.isEmpty)
        #expect(result.markdown == markdown)
    }

    @Test("Unclosed dollar is literal")
    func unclosedDollarIsLiteral() {
        let result = extract("The $x remains")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "The $x remains")
    }

    @Test("Inline span across a line break stores spaces")
    func inlineSpanAcrossLineBreakStoresSpaces() {
        let result = extract("$a\nb$")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].tex == "a b")
        #expect(!result.spans[0].isDisplay)
        #expect(result.markdown == "\(MathSpanExtractor.placeholder(for: 0))\n")
    }

    @Test("Cyrillic and emoji around math")
    func cyrillicAndEmojiAroundMath() {
        let result = extract("Привет $x$ мир 🎉")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].tex == "x")
        #expect(result.markdown == "Привет \(MathSpanExtractor.placeholder(for: 0)) мир 🎉")
    }

    @Test("Placeholder round-trips through spanIndices")
    func placeholderRoundTripsThroughSpanIndices() {
        for index in [0, 1, 5, 9, 10, 100, 999] {
            let placeholder = MathSpanExtractor.placeholder(for: index)
            let text = "a \(placeholder) b \(placeholder) c"
            let found = MathSpanExtractor.spanIndices(in: text)
            #expect(found.count == 2)
            #expect(found.map(\.index) == [index, index])
            let scalars = Array(text.unicodeScalars)
            for occurrence in found {
                #expect(String(String.UnicodeScalarView(scalars[occurrence.range])) == placeholder)
            }
        }
    }
    // MARK: - Each inline delimiter rule on its own

    @Test("A closing dollar after a space does not close")
    func aClosingDollarAfterASpaceDoesNotClose() {
        #expect(extract("$a $b").spans.isEmpty)
    }

    @Test("A closing dollar before a digit does not close")
    func aClosingDollarBeforeADigitDoesNotClose() {
        #expect(extract("$a$1").spans.isEmpty)
    }

    @Test("A dollar before a space does not open")
    func aDollarBeforeASpaceDoesNotOpen() {
        #expect(extract("$ a$").spans.isEmpty)
    }

    @Test("An escaped dollar does not open")
    func anEscapedDollarDoesNotOpen() {
        let result = extract("\\$x$")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "\\$x$")
    }

    @Test("An escaped dollar inside TeX does not close")
    func anEscapedDollarInsideTexDoesNotClose() {
        #expect(extract("$a\\$b$").spans == [MathSpan(tex: "a\\$b", isDisplay: false)])
        #expect(extract("$$\\$100 \\times 2$$").spans == [MathSpan(tex: "\\$100 \\times 2", isDisplay: true)])
    }

    // MARK: - Verbatim regions

    @Test("Verbatim regions keep their dollars", arguments: [
        "$a\n\nb$",
        "<https://example.com/$a$>",
        "<!-- $a$ -->",
        "~~~\n$a$\n~~~",
        "````\n$a$\n```\n$b$\n````",
        "- item\n\n      code $a$",
        "1. item\n\n       code $a$",
        "    $a$",
        "    code\n    $a$",
        "text\n\n    code\n\n    $a$",
    ])
    func verbatimRegionsKeepTheirDollars(markdown: String) {
        let result = extract(markdown)
        #expect(result.spans.isEmpty, "\(markdown)")
        #expect(result.markdown == markdown)
    }

    @Test("A code span cannot cross a blank line, so math after one is math")
    func aCodeSpanCannotCrossABlankLine() {
        #expect(extract("`a\n\n$b$` c`").spans == [MathSpan(tex: "b", isDisplay: false)])
    }

    @Test("An escaped dollar right before the closing pair stays in display TeX")
    func anEscapedDollarRightBeforeTheClosingPairStaysInDisplayTex() {
        #expect(extract("$$\\$$$").spans == [MathSpan(tex: "\\$", isDisplay: true)])
    }

    @Test("A comment at the very end, or right before math")
    func aCommentAtTheVeryEndOrRightBeforeMath() {
        #expect(extract("text <!-- $a$ -->").markdown == "text <!-- $a$ -->")
        #expect(extract("<!-- c -->$x$").spans == [MathSpan(tex: "x", isDisplay: false)])
    }

    @Test("Random Markdown-ish text never crashes and keeps its lines")
    func randomMarkdownIshTextNeverCrashesAndKeepsItsLines() {
        // A fixed linear congruential sequence, so a failure reproduces.
        var state: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let pieces = ["$", "$$", "\\", "`", "```", "~~~", "<", ">", "<!--", "-->", "](", ")", "(", "[", "]",
                      "\n", "\n\n", " ", "    ", "> ", "- ", "a", "x^2", "http://", "www.", "<a ", "&", "\u{FFFC}", "\u{E000}", String(Unicode.Scalar(0xFDD0 as UInt32)!), String(Unicode.Scalar(0xFDE1 as UInt32)!)]
        for _ in 0..<3000 {
            let markdown = (0..<next(24)).map { _ in pieces[next(pieces.count)] }.joined()
            let result = extract(markdown)
            #expect(result.located.map(\.span) == result.spans)
            // Every span starts at a delimiter: `$`, or a fence's backtick or tilde.
            let scalars = Array(markdown.unicodeScalars)
            for range in result.located.map(\.source) {
                #expect(["$", "`", "~"].contains(scalars[range.lowerBound]), "\(markdown.debugDescription)")
            }
            // Code blocks are in order, apart, and start at a line start.
            for (block, next) in zip(result.codeBlocks, result.codeBlocks.dropFirst()) {
                #expect(block.upperBound <= next.lowerBound, "\(markdown.debugDescription)")
            }
            for block in result.codeBlocks {
                #expect(block.upperBound <= scalars.count)
                #expect(block.lowerBound == 0 || scalars[block.lowerBound - 1] == "\n", "\(markdown.debugDescription)")
            }
        }
    }

    @Test("Indented text in a list item is a paragraph, not code")
    func indentedTextInAListItemIsAParagraphNotCode() {
        #expect(extract("- item\n\n    more $a$").spans == [MathSpan(tex: "a", isDisplay: false)])
        #expect(extract("- item\n  - nested\n\n      more $a$").spans == [MathSpan(tex: "a", isDisplay: false)])
        // A paragraph back at the margin ends the code block.
        #expect(extract("    code\n\nafter $a$").spans == [MathSpan(tex: "a", isDisplay: false)])
    }

    @Test("Long lines of link, autolink and tag openers stay fast")
    func longLinesOfLinkAutolinkAndTagOpenersStayFast() {
        // Each opener used to scan to the end of the line: seconds at 100 KB.
        for piece in ["](", "](a (", "](<", "<http://", "<a "] {
            let line = String(repeating: piece, count: 100_000 / piece.count) + " $x$"
            let start = ContinuousClock.now
            let result = MathSpanExtractor.extract(from: line)
            let elapsed = ContinuousClock.now - start
            #expect(result.spans == [MathSpan(tex: "x", isDisplay: false)], "\(piece)")
            #expect(elapsed < .milliseconds(1500), "\(piece): \(elapsed)")
        }
    }

    @Test("A less-than sign before a word in prose is not an HTML tag")
    func aLessThanSignBeforeAWordInProseIsNotAnHtmlTag() {
        #expect(extract("if a <b and $x > y$ then").spans == [MathSpan(tex: "x > y", isDisplay: false)])
        #expect(extract("values <n then $n > 0$ holds").spans == [MathSpan(tex: "n > 0", isDisplay: false)])
        // Real tags still hide their attributes.
        #expect(extract("<img alt='$a$' src=x.png/> and <span title=\"$b$\" data-x>t</span> $c$").spans
            == [MathSpan(tex: "c", isDisplay: false)])
    }

    @Test("Back in an outer list item after a nested one")
    func backInAnOuterListItemAfterANestedOne() {
        let markdown = "- outer\n  - inner\n\n  back in outer\n\n    $x^2$ continuation"
        #expect(extract(markdown).spans == [MathSpan(tex: "x^2", isDisplay: false)])
    }

    @Test("A line of only quote markers ends display math in a quote")
    func aLineOfOnlyQuoteMarkersEndsDisplayMathInAQuote() {
        #expect(extract("> $$a\n>\n> b$$").spans.isEmpty)
        #expect(extract("> > $$a\n> >\n> > b$$").spans.isEmpty)
    }

    @Test("Indented code inside an outer list item after a nested one")
    func indentedCodeInsideAnOuterListItemAfterANestedOne() {
        // Six spaces: four past the outer item's content, so code.
        #expect(extract("- outer\n  - inner\n\n  back in outer\n\n      $x^2$").spans.isEmpty)
    }

    @Test("A lazy continuation line keeps the list open")
    func aLazyContinuationLineKeepsTheListOpen() {
        #expect(extract("- item\nlazy\n\n    $x$").spans == [MathSpan(tex: "x", isDisplay: false)])
    }

    @Test("A long line of formulas extracts in linear time")
    func aLongLineOfFormulasExtractsInLinearTime() {
        let line = String(repeating: "$a$ ", count: 25000)
        let start = ContinuousClock.now
        #expect(MathSpanExtractor.extract(from: line).spans.count == 25000)
        #expect(ContinuousClock.now - start < .milliseconds(1500))
    }

    @Test("The backtick record still finds every code span")
    func theBacktickRecordStillFindsEveryCodeSpan() {
        // An unclosed `` scans the paragraph first; the ` span after it
        // must still be found.
        #expect(extract("`` x ` $a$ `").spans.isEmpty)
        // A closer found early is not a scan of the whole paragraph.
        #expect(extract("`a` `` $b$ ``").spans.isEmpty)
        #expect(extract("`` x ` $a$ ` and $c$").spans == [MathSpan(tex: "c", isDisplay: false)])
    }

    @Test("Backtick runs of many lengths stay fast")
    func backtickRunsOfManyLengthsStayFast() {
        // Each run length used to search to the end of the text.
        let text = (1...2000).map { String(repeating: "`", count: $0) + " a " }.joined() + " $x$"
        let start = ContinuousClock.now
        let result = MathSpanExtractor.extract(from: text)
        #expect(ContinuousClock.now - start < .milliseconds(1500))
        #expect(result.spans == [MathSpan(tex: "x", isDisplay: false)])
    }

    @Test("A fence indented four spaces is code, not a fence")
    func aFenceIndentedFourSpacesIsCodeNotAFence() {
        let result = extract("    ```math\n    x\n    ```")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "    ```math\n    x\n    ```")
    }

    // MARK: - Block boundaries

    @Test("Inline math opened on a heading ends with the heading's line")
    func inlineMathOpenedOnAHeadingEndsWithTheHeadingsLine() {
        let markdown = "# Heading $x\ny$ tail"
        let result = extract(markdown)
        #expect(result.spans.isEmpty)
        #expect(result.markdown == markdown)
        // Display math opened after text on a heading line too.
        #expect(extract("## A $$x\ny$$ b").spans.isEmpty)
        // Math inside the heading's line still counts.
        #expect(extract("# Heading $x$\ny$ tail").spans == [MathSpan(tex: "x", isDisplay: false)])
    }

    @Test("Inline math does not continue into the next list item")
    func inlineMathDoesNotContinueIntoTheNextListItem() {
        let markdown = "- one $a\n- two b$ end"
        let result = extract(markdown)
        #expect(result.spans.isEmpty)
        #expect(result.markdown == markdown)
        #expect(extract("1. one $a\n2. two b$ end").spans.isEmpty)
        #expect(extract("- one\n  - two $a\n  - three b$").spans.isEmpty)
    }

    @Test("Inline math does not continue into a new block of another kind")
    func inlineMathDoesNotContinueIntoANewBlockOfAnotherKind() {
        // A heading, a thematic break, a setext underline, a quote.
        #expect(extract("text $a\n# b$").spans.isEmpty)
        #expect(extract("text $a\n***\nb$").spans.isEmpty)
        #expect(extract("text $a\n===\nb$").spans.isEmpty)
        #expect(extract("text $a\n> b$").spans.isEmpty)
        #expect(extract("> text $a\n> > b$").spans.isEmpty)
        // A list item interrupting a paragraph.
        #expect(extract("text $a\n- b$").spans.isEmpty)
        #expect(extract("> - one $a\n> - two b$").spans.isEmpty)
    }

    @Test("Inline math still spans a paragraph's continuation lines")
    func inlineMathStillSpansAParagraphsContinuationLines() {
        let span = [MathSpan(tex: "a b", isDisplay: false)]
        #expect(extract("text $a\nb$").spans == span)
        // A list item's lazy or indented continuation.
        #expect(extract("- one $a\n  b$").spans == [MathSpan(tex: "a   b", isDisplay: false)])
        #expect(extract("- one $a\nb$").spans == span)
        // Lines that cannot interrupt a paragraph: an ordered item not
        // numbered 1, an empty item, a `#` not followed by a space.
        #expect(extract("text $a\n2. b$").spans == [MathSpan(tex: "a 2. b", isDisplay: false)])
        #expect(extract("text $a\n#b$").spans == [MathSpan(tex: "a #b", isDisplay: false)])
        // A quote's lazy continuation.
        #expect(extract("> text $a\nb$").spans == span)
    }

    @Test("Display math opening its line keeps TeX lines that look like blocks")
    func displayMathOpeningItsLineKeepsTeXLinesThatLookLikeBlocks() {
        #expect(extract("$$\na\n- b\n# c\n$$").spans == [MathSpan(tex: "a\n- b\n# c", isDisplay: true)])
        #expect(extract("> $$\n> a\n> - b\n> $$").spans == [MathSpan(tex: "a\n- b", isDisplay: true)])
        // After text on its line, display math stays in that line's block.
        #expect(extract("- one $$a\n- two b$$").spans.isEmpty)
    }

    @Test("Line numbers survive a span cut at a block boundary")
    func lineNumbersSurviveASpanCutAtABlockBoundary() {
        // The helper checks the line count; the lines themselves are
        // unchanged, so the second item stays an item.
        let result = extract("- one $a\n- two $b$ end")
        #expect(result.spans == [MathSpan(tex: "b", isDisplay: false)])
        #expect(result.markdown.components(separatedBy: "\n").first == "- one $a")
    }

    // MARK: - Code blocks

    @Test("Code blocks are located, fences and indented code alike")
    func codeBlocksAreLocatedFencesAndIndentedCodeAlike() {
        func blocks(_ markdown: String) -> [String] {
            let scalars = Array(markdown.unicodeScalars)
            return extract(markdown).codeBlocks.map { String(String.UnicodeScalarView(scalars[$0])) }
        }
        #expect(blocks("a\n```\nx\n```\nb") == ["```\nx\n```\n"])
        #expect(blocks("a\n~~~js\nx\n~~~") == ["~~~js\nx\n~~~"])
        // Unclosed: to the end.
        #expect(blocks("a\n```\nx $y$") == ["```\nx $y$"])
        // A `math` fence is a block too (and a span).
        #expect(blocks("```math\nx\n```\n") == ["```math\nx\n```\n"])
        // Indented code ends with its last non-blank line.
        #expect(blocks("a\n\n    x\n\n    y\n\nb") == ["    x\n\n    y\n"])
        // Indented four past a list item's content, not past the margin.
        #expect(blocks("- a\n\n    b").isEmpty)
        // A fence inside indented code is code, not a fence.
        #expect(blocks("    ```\n    x\n\ntext") == ["    ```\n    x\n"])
    }
}
