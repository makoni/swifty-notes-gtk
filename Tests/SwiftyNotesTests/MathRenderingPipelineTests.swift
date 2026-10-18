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

    @Test("Display math quoted over several lines keeps the quote")
    func displayMathQuotedOverSeveralLinesKeepsTheQuote() {
        let blocks = blocks(for: "> before\n> $$\n> x^2 + y^2\n> $$\n> after")
        #expect(MathSpanExtractor.extract(from: "> $$\n> x^2 + y^2\n> $$").spans
            == [MathSpan(tex: "x^2 + y^2", isDisplay: true)])
        let quotes = blocks.compactMap { block -> RenderedText? in
            if case let .blockquote(text) = block { return text }
            return nil
        }
        #expect(quotes.count == blocks.count, "nothing leaks out of the quote: \(blocks)")
        let quoted = quotes.map(\.plainText).joined(separator: "\n")
        #expect(quoted.contains("$x^2 + y^2$"))
        #expect(quoted.contains("after"))
        #expect(!quoted.contains(">"))
    }

    @Test("Inline math wrapped inside a nested quote")
    func inlineMathWrappedInsideANestedQuote() {
        let extraction = MathSpanExtractor.extract(from: "> > a $x +\n> > y$ b")
        #expect(extraction.spans == [MathSpan(tex: "x + y", isDisplay: false)])
        #expect(extraction.markdown == "> > a \(MathSpanExtractor.placeholder(for: 0))\n> >  b")
    }

    @Test("A link in a table cell keeps its dollars in the URL")
    func aLinkInATableCellKeepsItsDollarsInTheURL() {
        let blocks = blocks(for: "| A |\n| --- |\n| [a](x/$q\" foo=\"z$) and $y$ |")
        guard blocks.count == 1, case let .table(_, rows, _) = blocks[0], let cell = rows.first?.first else {
            Issue.record("expected one table, got \(blocks)")
            return
        }
        #expect(!cell.markup.contains("foo=\"z"))
        #expect(cell.plainText.hasSuffix("and $y$"))
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

    @Test("TeX in a table cell is escaped for the markup")
    func texInATableCellIsEscapedForTheMarkup() {
        let blocks = blocks(for: "| A |\n| --- |\n| $a<b \\& c$ |")
        guard blocks.count == 1, case let .table(_, rows, _) = blocks[0], let cell = rows.first?.first else {
            Issue.record("expected one table, got \(blocks)")
            return
        }
        #expect(cell.markup == "$a&lt;b \\&amp; c$")
        #expect(cell.plainText == "$a<b \\& c$")
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
        #expect(blocks.count == 2)
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
    @Test("Dollars in a link destination stay in the URL")
    func dollarsInALinkDestinationStayInTheURL() {
        let url = "https://graph.microsoft.com/v1.0/me/messages?$select=subject&$top=5"
        let blocks = blocks(for: "[Graph](\(url)) where $x^2$ grows")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.markup.contains("href=\"\(pangoEscapeAttribute(url))\""))
        #expect(text.plainText == "Graph where $x^2$ grows")
        #expect(text.mathSpans == [MathSpan(tex: "x^2", isDisplay: false)])
        #expect(text.markup.unicodeScalars.filter { $0 == "\u{FFFC}" }.count == 1)
    }

    @Test("Text in parentheses after a bracket is not a link destination")
    func textInParenthesesAfterABracketIsNotALinkDestination() {
        #expect(MathSpanExtractor.extract(from: "[note](see $x$)").spans == [MathSpan(tex: "x", isDisplay: false)])
        #expect(MathSpanExtractor.extract(from: "[a](<x $y$>) and [b](u \"t $z$\")").spans.isEmpty)
    }

    @Test("A placeholder in an href comes back with its own delimiters")
    func aPlaceholderInAnHrefComesBackWithItsOwnDelimiters() {
        let blocks = blocks(for: "[r][ref]\n\n[ref]: /x?$$a$$")
        guard let first = blocks.first, case let .paragraph(text) = first else {
            Issue.record("expected a paragraph, got \(blocks)")
            return
        }
        #expect(text.markup.contains("href=\"/x?$$a$$\""), "\(text.markup)")
    }

    @Test("A link destination pairs its own dollars with none outside")
    func aLinkDestinationPairsItsOwnDollarsWithNoneOutside() {
        let blocks = blocks(for: "[a](x?$p) b$ c")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.mathSpans.isEmpty)
        #expect(text.plainText == "a b$ c")
    }

    @Test("TeX put back into an href is escaped for the attribute")
    func texPutBackIntoAnHrefIsEscapedForTheAttribute() {
        let blocks = blocks(for: "[docs][ref] and $x$\n\n[ref]: /q?$a&b$")
        guard let first = blocks.first, case let .paragraph(text) = first else {
            Issue.record("expected a paragraph, got \(blocks)")
            return
        }
        #expect(text.markup.contains("href=\"/q?$a&amp;b$\""), "\(text.markup)")
    }

    @Test("Image titles and image groups put math back as source")
    func imageTitlesAndImageGroupsPutMathBackAsSource() {
        let titled = blocks(for: "![alt][img]\n\n[img]: pic.png \"Title $t$\"")
        if case let .image(_, _, title, _) = titled.first {
            #expect(title == "Title $t$")
        } else {
            Issue.record("expected an image, got \(titled)")
        }
        let group = blocks(for: "![A $a$](a.png) ![B $b$](b.png)")
        if case let .imageGroup(items, _) = group.first {
            #expect(items.map(\.alt) == ["A $a$", "B $b$"])
        } else {
            Issue.record("expected an image group, got \(group)")
        }
        let linked = blocks(for: "[![i](a.png)][l] [![j](b.png)][l]\n\n[l]: /p?$q$")
        if case let .imageGroup(items, _) = linked.first {
            #expect(items.map(\.linkDestination) == ["/p?$q$", "/p?$q$"])
        } else {
            Issue.record("expected an image group, got \(linked)")
        }
    }

    @Test("A bare URL with dollars is not math")
    func aBareURLWithDollarsIsNotMath() {
        let url = "https://example.com/api?$select=a&$top=5"
        let blocks = blocks(for: "See \(url) and $y$")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.plainText == "See \(url) and $y$")
        #expect(text.mathSpans == [MathSpan(tex: "y", isDisplay: false)])
    }

    @Test("Dollars in a raw HTML attribute are not math")
    func dollarsInARawHTMLAttributeAreNotMath() {
        let extraction = MathSpanExtractor.extract(from: "<a title=\"$a$ and $b$\">x</a> then $c$")
        #expect(extraction.spans == [MathSpan(tex: "c", isDisplay: false)])
        #expect(extraction.markdown.hasPrefix("<a title=\"$a$ and $b$\">x</a> then "))
    }

    @Test("Prose with a less-than sign keeps its math")
    func proseWithALessThanSignKeepsItsMath() {
        let extraction = MathSpanExtractor.extract(from: "if x <y, $z$ > 1")
        #expect(extraction.spans == [MathSpan(tex: "z", isDisplay: false)])
    }

    @Test("Math in image alt text comes back as source")
    func mathInImageAltTextComesBackAsSource() {
        let blocks = blocks(for: "![Area $A=r^2$](pic.png \"Title $t$\")")
        guard blocks.count == 1, case let .image(alt, source, title, _) = blocks[0] else {
            Issue.record("expected one image, got \(blocks)")
            return
        }
        #expect(alt == "Area $A=r^2$")
        #expect(source == "pic.png")
        #expect(title == "Title $t$")
    }

    @Test("A placeholder inside a reference link's href comes back as source")
    func aPlaceholderInsideAReferenceLinkHrefComesBackAsSource() {
        let blocks = blocks(for: "[docs][ref] and $x$\n\n[ref]: /search?q=$a$b$")
        guard let first = blocks.first, case let .paragraph(text) = first else {
            Issue.record("expected a paragraph, got \(blocks)")
            return
        }
        #expect(!text.markup.unicodeScalars.contains { (0xE000...0xE019).contains($0.value) })
        #expect(text.markup.contains("href=\"/search?q=$a$b$\""))
        #expect(text.mathSpans == [MathSpan(tex: "x", isDisplay: false)])
        #expect(text.markup.unicodeScalars.filter { $0 == "\u{FFFC}" }.count == 1)
    }

    @Test("Entities for placeholder characters cannot repeat a formula")
    func entitiesForPlaceholderCharactersCannotRepeatAFormula() {
        for markdown in ["$x$ &#xE000;&#xE010;&#xE001;", "$x$ &#57344;&#57360;&#57345;", "$x$ &#x0e000;&#xE010;&#xe001;"] {
            let blocks = blocks(for: markdown)
            guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
                Issue.record("expected one paragraph, got \(blocks)")
                continue
            }
            #expect(text.mathSpans == [MathSpan(tex: "x", isDisplay: false)], "\(markdown)")
            #expect(text.markup.unicodeScalars.filter { $0 == "\u{FFFC}" }.count == 1, "\(markdown)")
        }
        // Same length, so source positions do not move.
        #expect(MathSpanExtractor.extract(from: "&#xE000; $y$").markdown.unicodeScalars.count
            == "&#xFFFD; \(MathSpanExtractor.placeholder(for: 0))".unicodeScalars.count)
    }

    @Test("Entities in a link cannot carry another formula's TeX")
    func entitiesInALinkCannotCarryAnotherFormulasTex() {
        let blocks = blocks(for: "Secret $\\text{PIN 1234}$ [l](http://h/&#xE000;&#xE010;&#xE001;)")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(!text.markup.contains("PIN 1234"), "\(text.markup)")
    }

    @Test("An entity for the formula marker does not become a formula")
    func anEntityForTheFormulaMarkerDoesNotBecomeAFormula() {
        let blocks = blocks(for: "a &#xFFFC; b $x$")
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.mathSpans == [MathSpan(tex: "x", isDisplay: false)])
        #expect(text.markup.unicodeScalars.filter { $0 == "\u{FFFC}" }.count == 1)
    }
}
