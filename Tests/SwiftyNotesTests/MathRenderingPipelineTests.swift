import Foundation
import Testing
@testable import SwiftyNotes

struct MathRenderingPipelineTests {
    private let renderer = MarkdownRenderer()

    private func blocks(for markdown: String) -> [RenderedBlock] {
        renderer.blocks(for: markdown, darkAppearance: false)
    }

    @Test("Roots render as inline math, no emphasis")
    func rootsRenderAsInlineMathNoEmphasis() {
        let blocks = blocks(for: "Roots $x^*$ and $y^*$ here")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "Roots $x^*$ and $y^*$ here")
        #expect(!text.markup.contains("<i>"))
        // One formula marker per span, in order; the preview draws over them.
        #expect(text.markup == "Roots \u{FFFC} and \u{FFFC} here")
        #expect(text.mathSpans == [
            MathSpan(tex: "x^*", isDisplay: false),
            MathSpan(tex: "y^*", isDisplay: false),
        ])
    }

    @Test("Set builder survives the pipeline")
    func setBuilderSurvivesThePipeline() {
        let blocks = blocks(for: "Set $\\{x \\mid x>0\\}$")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "Set $\\{x \\mid x>0\\}$")
    }

    @Test("pmatrix keeps doubled backslashes")
    func pmatrixKeepsDoubledBackslashes() {
        let blocks = blocks(for: "A = $\\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix}$")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "A = $\\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix}$")
    }

    @Test("Cost amounts are not math")
    func costAmountsAreNotMath() {
        let blocks = blocks(for: "It costs $5 and $10.")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "It costs $5 and $10.")
        #expect(text.mathSpans.isEmpty)
        #expect(!text.markup.contains("\u{FFFC}"))
    }

    @Test("Thousands are not math")
    func thousandsAreNotMath() {
        let blocks = blocks(for: "$20,000 and $30,000")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "$20,000 and $30,000")
        #expect(text.mathSpans.isEmpty)
    }

    @Test("Escaped dollar renders a literal dollar")
    func escapedDollarRendersALiteralDollar() {
        let blocks = blocks(for: "Price is \\$5")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "Price is $5")
        #expect(text.mathSpans.isEmpty)
    }

    @Test("Code span dollars are not math")
    func codeSpanDollarsAreNotMath() {
        let blocks = blocks(for: "`code $x$`")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "code $x$")
        #expect(text.mathSpans.isEmpty)
    }

    @Test("Fenced block dollars are not math")
    func fencedBlockDollarsAreNotMath() {
        let blocks = blocks(for: "```\n$x$\n```")
        guard blocks.count == 1, case let .codeBlock(code, _) = blocks[0] else {
            Issue.record("expected one code block, got \(blocks)")
            return
        }
        #expect(code.trimmingCharacters(in: .whitespacesAndNewlines) == "$x$")
    }

    @Test("Indented code dollars are not math")
    func indentedCodeDollarsAreNotMath() {
        let blocks = blocks(for: "\n    $x$\n")
        guard blocks.count == 1, case let .codeBlock(code, _) = blocks[0] else {
            Issue.record("expected one code block, got \(blocks)")
            return
        }
        #expect(code.trimmingCharacters(in: .whitespacesAndNewlines) == "$x$")
    }

    @Test("Multiline display math becomes a math block")
    func multilineDisplayMathBecomesAMathBlock() {
        let blocks = blocks(for: """
            $$
            \\int_0^1 f
            $$
            """)
        guard blocks.count == 1, case let .math(tex) = blocks[0] else {
            Issue.record("expected one math block, got \(blocks)")
            return
        }
        #expect(tex == "\\int_0^1 f")
        #expect(blocks[0].style == .math)
        #expect(blocks[0].plainText == "\\int_0^1 f")
    }

    @Test("Alone display math becomes a math block")
    func aloneDisplayMathBecomesAMathBlock() {
        let blocks = blocks(for: "$$a=b$$")
        guard blocks.count == 1, case let .math(tex) = blocks[0] else {
            Issue.record("expected one math block, got \(blocks)")
            return
        }
        #expect(tex == "a=b")
    }

    @Test("math fence becomes a math block")
    func mathFenceBecomesAMathBlock() {
        let blocks = blocks(for: "```math\nx+y\n```")
        guard blocks.count == 1, case let .math(tex) = blocks[0] else {
            Issue.record("expected one math block, got \(blocks)")
            return
        }
        #expect(tex == "x+y")
    }

    @Test("Math in a heading")
    func mathInAHeading() {
        let blocks = blocks(for: "# $x$")
        guard blocks.count == 1, case let .heading(level, text) = blocks[0] else {
            Issue.record("expected one heading, got \(blocks)")
            return
        }
        #expect(level == 1)
        #expect(text.plainText == "$x$")
    }

    @Test("Math in a list item")
    func mathInAListItem() {
        let blocks = blocks(for: "- item $x$")
        guard blocks.count == 1, case let .listItem(text, _, marker, _, _) = blocks[0] else {
            Issue.record("expected one list item, got \(blocks)")
            return
        }
        #expect(marker == "-")
        #expect(text.plainText == "item $x$")
    }

    @Test("Math in a nested list item")
    func mathInANestedListItem() {
        let blocks = blocks(for: "- a\n  - b $x$")
        guard blocks.count == 2,
              case let .listItem(first, firstDepth, _, _, _) = blocks[0],
              case let .listItem(second, secondDepth, _, _, _) = blocks[1]
        else {
            Issue.record("expected two list items, got \(blocks)")
            return
        }
        #expect(first.plainText == "a")
        #expect(firstDepth == 0)
        #expect(second.plainText == "b $x$")
        #expect(secondDepth == 1)
    }

    @Test("Math in a blockquote")
    func mathInABlockquote() {
        let blocks = blocks(for: "> $x$")
        guard blocks.count == 1, case let .blockquote(text) = blocks[0] else {
            Issue.record("expected one blockquote, got \(blocks)")
            return
        }
        #expect(text.plainText == "$x$")
    }

    @Test("Math in a table cell")
    func mathInATableCell() {
        let blocks = blocks(for: "| A |\n| --- |\n| $x$ |")
        guard blocks.count == 1, case let .table(headers, rows, _) = blocks[0] else {
            Issue.record("expected one table, got \(blocks)")
            return
        }
        #expect(headers.map(\.plainText) == ["A"])
        #expect(rows.count == 1)
        #expect(rows[0].map(\.plainText) == ["$x$"])
        // Tables align columns in monospace characters, so cells keep the
        // TeX source instead of a drawn formula.
        #expect(rows[0].map(\.markup) == ["$x$"])
        let cellsHaveNoFormulas = rows[0].allSatisfy { $0.mathSpans.isEmpty }
        #expect(cellsHaveNoFormulas)
    }

    @Test("Characters that combine across several code points before a formula do not break it")
    func multiScalarCharactersBeforeAFormula() {
        // An emoji with a skin-tone modifier, a flag and decomposed accents
        // are several code points per character; placeholder positions are
        // code points, so mixing the two used to trap.
        for prefix in ["Thumbs 👍🏽 🇺🇸 ", "Cafe\u{301} cre\u{300}me ", "\u{600}"] {
            let blocks = blocks(for: "\(prefix)$x$ and $y$")
            guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
                Issue.record("expected one paragraph for \(prefix.debugDescription), got \(blocks)")
                continue
            }
            #expect(text.mathSpans.map(\.tex) == ["x", "y"])
            // Compared by code point: U+0600 prepends itself to the "$".
            #expect(String(String.UnicodeScalarView(text.plainText.unicodeScalars.suffix(11))) == "$x$ and $y$")
        }
    }

    @Test("Placeholder code points typed into a note stay plain text")
    func placeholderCodePointsTypedIntoANoteStayPlainText() {
        let typed = "\u{E000}\u{E010}\u{E001}"
        let overflowing = "\u{E000}" + String(repeating: "\u{E019}", count: 30) + "\u{E001}"
        let blocks = blocks(for: "Typed \(typed) and \(overflowing) then $z$")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.mathSpans == [MathSpan(tex: "z", isDisplay: false)])
        #expect(!text.plainText.unicodeScalars.contains { (0xE000...0xE019).contains($0.value) })
    }

    @Test("An object replacement character inside TeX cannot shift the formulas")
    func objectReplacementCharacterInsideTexCannotShiftFormulas() {
        let blocks = blocks(for: "First $a\u{FFFC}b$ then $c$")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.mathSpans.map(\.tex) == ["a\u{FFFD}b", "c"])
        #expect(text.markup.unicodeScalars.filter { $0 == "\u{FFFC}" }.count == 2)
    }

    @Test("Markup escaping catches markup characters followed by combining marks")
    func markupEscapingCatchesMarkupCharactersFollowedByCombiningMarks() {
        // "≮" decomposes into "<" + U+0338; matching whole characters missed it.
        #expect(pangoEscape("a <\u{338} b &\u{301} c >\u{301}") == "a &lt;\u{338} b &amp;\u{301} c &gt;\u{301}")
        #expect(pangoEscapeAttribute("\"\u{301}") == "&quot;\u{301}")
        let blocks = blocks(for: "Not less: a <\u{338} b")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(!text.markup.unicodeScalars.contains("<"))
    }

    @Test("A literal object replacement character is not taken for a formula")
    func literalObjectReplacementCharacterIsNotTakenForAFormula() {
        let blocks = blocks(for: "Odd \u{FFFC} character and $x$")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.markup == "Odd \u{FFFD} character and \u{FFFC}")
        #expect(text.mathSpans == [MathSpan(tex: "x", isDisplay: false)])
    }

    @Test("Math inside bold")
    func mathInsideBold() {
        let blocks = blocks(for: "**bold $x$**")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "bold $x$")
        #expect(text.markup == "<b>bold \u{FFFC}</b>")
    }

    @Test("Math inside a link")
    func mathInsideALink() {
        let blocks = blocks(for: "[link $x$](https://e.com)")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "link $x$")
        #expect(text.markup == "<a href=\"https://e.com\">link \u{FFFC}</a>")
    }

    @Test("Task list keeps task indices and toggles on the source")
    func taskListKeepsTaskIndicesAndTogglesOnTheSource() {
        let markdown = "- [ ] item $x$\n- [x] done"
        let blocks = blocks(for: markdown)
        guard blocks.count == 2,
              case let .listItem(firstText, _, firstMarker, _, firstIndex) = blocks[0],
              case let .listItem(secondText, _, secondMarker, _, secondIndex) = blocks[1]
        else {
            Issue.record("expected two list items, got \(blocks)")
            return
        }
        #expect(firstIndex == 0)
        #expect(firstMarker == "[ ]")
        #expect(firstText.plainText == "item $x$")
        #expect(secondIndex == 1)
        #expect(secondMarker == "[x]")
        #expect(secondText.plainText == "done")
        #expect(
            TaskListToggle.toggle(in: markdown, atTaskIndex: 1)
                == "- [ ] item $x$\n- [ ] done",
        )
    }

    @Test("Math at line start and end")
    func mathAtLineStartAndEnd() {
        let blocks = blocks(for: "$x$ at start\nat end $y$")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "$x$ at start\nat end $y$")
    }

    @Test("Display math with a blank line inside is not math")
    func displayMathWithBlankLineInsideIsNotMath() {
        let markdown = "$$\na\n\nb\n$$"
        let blocks = blocks(for: markdown)
        // The blank line inside `$$ … $$` disqualifies it as display math, so
        // the dollars are literal and the text falls through as two ordinary
        // paragraphs.
        for block in blocks {
            guard case let .paragraph(text) = block else {
                Issue.record("expected paragraphs, got \(blocks)")
                return
            }
            #expect(text.mathSpans.isEmpty)
            #expect(!text.plainText.contains("\u{E000}"))
        }
    }

    @Test("Unclosed dollar is literal text")
    func unclosedDollarIsLiteralText() {
        let blocks = blocks(for: "The $x remains")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "The $x remains")
        #expect(text.mathSpans.isEmpty)
    }

    @Test("Cyrillic and emoji around math")
    func cyrillicAndEmojiAroundMath() {
        let blocks = blocks(for: "Привет $x$ мир 🎉")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "Привет $x$ мир 🎉")
    }
}
