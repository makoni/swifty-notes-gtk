#if !os(macOS)
import Adwaita
import CAdwaita
import CRaTeXBridge
import CSpelling
import Foundation
@testable import SwiftyNotes
import Testing

/// The accessible label GTK itself holds for `label` when it differs from
/// `expected`, or nil. swift-adwaita's `accessibleLabel` is its own stored
/// copy, which GTK's resets never touch.
@MainActor
private func gtkAccessibleLabelMismatch(of label: Label, expected: String) -> String? {
    guard let mismatch = swifty_notes_accessible_label_mismatch(UnsafeMutableRawPointer(label.widgetPointer), expected) else {
        return nil
    }
    defer { g_free(mismatch) }
    return String(cString: mismatch)
}

/// Labels finalized since the count was reset (``g_object_weak_ref``).
private nonisolated(unsafe) var finalizedLabelCount = 0

/// Formulas drawn inside the preview's labels (``PreviewMath``).
struct MathPreviewWidgetTests {
    @Test("Inline formulas are drawn over their markers in the paragraph label") @MainActor
    func inlineFormulasAreDrawnOverTheirMarkers() throws {
        let fixture = try Fixture(suffix: "inline", markdown: "Roots $x^*$ and $\\frac{a}{b}$ here.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(label.text == "Roots \u{FFFC} and \u{FFFC} here.")
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["x^*", "\\frac{a}{b}"])
        #expect(PreviewMath.debugShapeAttributeCount(on: label) == 2)
        #expect(PreviewMath.drawsFormulas(label.opaquePointer))
    }

    @Test("Formulas sit in headings, lists and quotes too") @MainActor
    func formulasSitInHeadingsListsAndQuotes() throws {
        let fixture = try Fixture(suffix: "contexts", markdown: """
        # Euler $e^{i\\pi}$

        - item $a$
        - item $b$

        > quote $c$
        """)
        let drawn = fixture.labels().flatMap { PreviewMath.debugFormulas(on: $0).map(\.tex) }
        #expect(drawn == ["e^{i\\pi}", "a", "b", "c"])
    }

    @Test("A formula the engine cannot draw shows its TeX source") @MainActor
    func formulaTheEngineCannotDrawShowsItsSource() throws {
        let fixture = try Fixture(suffix: "fallback", markdown: "Good $x$ and bad $\\undefinedmacro{y}$ end.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(label.text == "Good \u{FFFC} and bad $\\undefinedmacro{y}$ end.")
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["x"])
    }

    @Test("A fallback formula's source is escaped for markup") @MainActor
    func fallbackFormulaSourceIsEscaped() throws {
        let fixture = try Fixture(suffix: "fallback-escape", markdown: "See $a < b \\undefinedmacro & c$ here.\n\n$$\n\\undefinedmacro{y} < 1\n$$")
        let paragraph = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(paragraph.text == "See $a < b \\undefinedmacro & c$ here.")
        let block = try #require(fixture.firstLabel(withCSSClass: "preview-math-label"))
        #expect(block.text == "$$\\undefinedmacro{y} < 1$$")
    }

    @Test("A display formula wider than the preview scrolls instead of widening it") @MainActor
    func wideDisplayFormulaScrolls() throws {
        let wide = (0..<60).map { "x_{\($0)}" }.joined(separator: " + ")
        let fixture = try Fixture(suffix: "wide", markdown: "$$\n\(wide)\n$$")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-math-label"))
        let formula = try #require(PreviewMath.debugFormulas(on: label).first)
        let scroller = try #require(label.parent?.tryCast(ScrolledWindow.self) ?? label.parent?.parent?.tryCast(ScrolledWindow.self))
        #expect(scroller.hasCSSClass("preview-math-block"))
        let minimumWidth = scroller.measure(orientation: .horizontal, forSize: -1).minimum
        #expect(Double(minimumWidth) < formula.width / 2, "block minimum \(minimumWidth) for a \(formula.width) px formula")
    }

    @Test("A display formula is a centred block of its own") @MainActor
    func displayFormulaIsCentredBlock() throws {
        let fixture = try Fixture(suffix: "display", markdown: "Before\n\n$$\n\\int_0^1 x\\,dx = \\frac{1}{2}\n$$\n\nAfter")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-math-label"))
        #expect(label.text == "\u{FFFC}")
        let formula = try #require(PreviewMath.debugFormulas(on: label).first)
        #expect(formula.isDisplay)
        #expect(label.halign == .center)
        // Display style sets the integral and fraction at full size.
        let inline = try #require(MathRenderer.formula(tex: formula.tex, isDisplay: false, pixelSize: formula.pixelSize))
        #expect(formula.height > inline.height)
    }

    @Test("Copying a selection puts the TeX source on the clipboard") @MainActor
    func copyingSelectionPutsTexSourceOnClipboard() throws {
        let fixture = try Fixture(suffix: "copy", markdown: "Area $\\pi r^2$ of a circle.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.sourceText(of: label) == "Area $\\pi r^2$ of a circle.")
        #expect(PreviewMath.sourceText(of: label, selection: 5..<11) == "$\\pi r^2$ of a")

        gtk_label_select_region(label.opaquePointer, 0, -1)
        // The label's built-in clipboard.copy action emits copy-clipboard.
        gtk_widget_activate_action_variant(label.widgetPointer, "clipboard.copy", nil)
        let clipboard = gtk_widget_get_clipboard(label.widgetPointer)
        #expect(readClipboardText(clipboard) == "Area $\\pi r^2$ of a circle.")
    }

    @Test("Copying part of a line counts in characters, after non-Latin text") @MainActor
    func copyingPartOfALineCountsInCharacters() throws {
        let fixture = try Fixture(suffix: "copy-part", markdown: "Площадь 👍🏽 $\\pi r^2$ круга")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        // GTK counts code points: "Площадь " is 8, the emoji with its
        // modifier 2 more, then a space, the formula and " кр".
        gtk_label_select_region(label.opaquePointer, 8, 15)
        gtk_widget_activate_action_variant(label.widgetPointer, "clipboard.copy", nil)
        #expect(readClipboardText(gtk_widget_get_clipboard(label.widgetPointer)) == "👍🏽 $\\pi r^2$ кр")
    }

    @Test("Copying a display formula gives its $$ source") @MainActor
    func copyingDisplayFormulaGivesItsSource() throws {
        let fixture = try Fixture(suffix: "copy-display", markdown: "$$\n\\sum_{k=1}^n k\n$$")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-math-label"))
        gtk_label_select_region(label.opaquePointer, 0, -1)
        gtk_widget_activate_action_variant(label.widgetPointer, "clipboard.copy", nil)
        #expect(readClipboardText(gtk_widget_get_clipboard(label.widgetPointer)) == "$$\\sum_{k=1}^n k$$")
    }

    @Test("Screen readers get the TeX source instead of the marker") @MainActor
    func screenReadersGetTheTexSource() throws {
        let fixture = try Fixture(suffix: "a11y", markdown: "Energy $E = mc^2$ here.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(gtkAccessibleLabelMismatch(of: label, expected: "Energy $E = mc^2$ here.") == nil)
    }

    @Test("Search highlights keep the TeX in the accessible label") @MainActor
    func searchHighlightsKeepTheTexInTheAccessibleLabel() throws {
        let fixture = try Fixture(suffix: "a11y-search", markdown: "Energy $E = mc^2$ here.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "here", options: .init())
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["here"])
        #expect(gtkAccessibleLabelMismatch(of: label, expected: "Energy $E = mc^2$ here.") == nil)
        preview.clearSearchHighlights()
        #expect(gtkAccessibleLabelMismatch(of: label, expected: "Energy $E = mc^2$ here.") == nil)
    }

    @Test("Zooming the preview lays the formulas out at the new size") @MainActor
    func zoomingLaysFormulasOutAtNewSize() throws {
        let fixture = try Fixture(suffix: "zoom", markdown: "Zoom $\\frac{a}{b}$ test.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let before = try #require(PreviewMath.debugFormulas(on: label).first).pixelSize
        defer {
            fixture.preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 100)
            MainContext.pump(for: .milliseconds(40))
        }
        fixture.preview.applyTypography(zoomPercent: 150, lineSpacingPercent: 100)
        // Laid out at the new size at once, and never back at the old one
        // on a later frame while GTK restyles the label.
        let zoomed = try #require(PreviewMath.debugFormulas(on: label).first).pixelSize
        var smallestSeen = zoomed
        var ticks = 0
        _ = label.addTickCallback {
            ticks += 1
            smallestSeen = min(smallestSeen, PreviewMath.debugFormulas(on: label).first?.pixelSize ?? 0)
            return fixture.preview.debugMathFontRefreshPending
        }
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        #expect(ticks > 0, "frames ran while GTK restyled")
        #expect(!fixture.preview.debugMathFontRefreshPending)
        let after = try #require(PreviewMath.debugFormulas(on: label).first).pixelSize
        #expect(abs(after / before - 1.5) < 0.05, "formula size \(before) → \(after)")
        #expect(smallestSeen > before * 1.3, "a frame showed \(smallestSeen), the old size was \(before)")
    }

    @Test("Search highlights keep the formulas and land on the right words") @MainActor
    func searchHighlightsKeepFormulas() throws {
        let fixture = try Fixture(suffix: "search", markdown: "First $\\alpha + \\beta$ then needle.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        #expect(matches.count == 1)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["needle"])
        #expect(PreviewMath.debugShapeAttributeCount(on: label) == 1)
        preview.clearSearchHighlights()
        #expect(PreviewMath.debugShapeAttributeCount(on: label) == 1)
    }

    @Test("A search hit inside a formula's TeX highlights the formula") @MainActor
    func searchHitInsideFormulaHighlightsTheFormula() throws {
        let fixture = try Fixture(suffix: "search-inside", markdown: "First $\\alpha + \\beta$ then needle after $\\undefinedmacro x$ needle.")
        let preview = fixture.preview
        let inside = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "alpha", options: .init())
        preview.applySearchHighlights(matches: inside, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["\u{FFFC}"])
        // After a formula that fell back to source the label spells it out,
        // so later hits still land on their own words.
        let after = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: after, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["needle", "needle"])
    }

    @Test("Zooming keeps the search highlights") @MainActor
    func zoomingKeepsSearchHighlights() throws {
        let fixture = try Fixture(suffix: "search-zoom", markdown: "Formula $x^2$ then needle.")
        let preview = fixture.preview
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        let before = attributeCount(on: label)
        defer { preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 100) }
        preview.applyTypography(zoomPercent: 150, lineSpacingPercent: 100)
        // The immediate rescale already put them back…
        #expect(attributeCount(on: label) == before, "highlight attributes survive the immediate rescale")
        // …and so does the refresh once GTK has restyled the label.
        let zoomed = try #require(PreviewMath.debugFormulas(on: label).first).pixelSize
        pumpUntil(timeout: .seconds(2)) { !preview.debugMathFontRefreshPending }
        #expect(!preview.debugMathFontRefreshPending)
        #expect(try #require(PreviewMath.debugFormulas(on: label).first).pixelSize >= zoomed * 0.95)
        #expect(attributeCount(on: label) == before, "highlight attributes survive the relayout")
        #expect(PreviewMath.debugShapeAttributeCount(on: label) == 1)
    }

    @Test("Zooming after a rebuilt row had search hits does not touch the freed label") @MainActor
    func zoomingAfterARebuiltRowHadSearchHitsDoesNotTouchTheFreedLabel() throws {
        let fixture = try Fixture(suffix: "rebuilt-highlight", markdown: "A needle $x$ here.\n\n```\nc\n```")
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["needle"])
        // Paragraph → heading rebuilds the row, freeing its label.
        fixture.render("# A needle $x$ here.\n\n```\nc\n```")
        // The overlay forgets the freed label…
        #expect(preview.debugHighlightedLabelPointers.isEmpty)
        defer { preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 100) }
        // Re-applies the last highlights; reaching the freed label crashed.
        preview.applyTypography(zoomPercent: 150, lineSpacingPercent: 100)
        MainContext.pump(for: .milliseconds(100))
        let heading = try #require(fixture.labels().first { $0.text.hasPrefix("A needle") })
        #expect(PreviewMath.debugFormulas(on: heading).map(\.tex) == ["x"])
        // …and the same matches apply afresh to the new one.
        let again = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: again, activeIndex: 0)
        #expect(preview.debugHighlightedLabelPointers == [heading.opaquePointer])
    }

    @Test("A formula refused at the memory limit is drawn after the next edit") @MainActor
    func aFormulaRefusedAtTheMemoryLimitIsDrawnAfterTheNextEdit() throws {
        let fixture = try Fixture(suffix: "retry-limit", markdown: "")
        let previous = ratex_bridge_set_live_bytes_limit(0)
        defer { ratex_bridge_set_live_bytes_limit(previous) }
        fixture.render("Text $m_{retry}$ here.")
        ratex_bridge_set_live_bytes_limit(previous)
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: label).isEmpty)
        fixture.render("Text $m_{retry}$ here!")
        let edited = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(edited.widgetPointer == label.widgetPointer, "updated in place")
        #expect(PreviewMath.debugFormulas(on: edited).map(\.tex) == ["m_{retry}"])
    }

    @Test("Broken formulas are not parsed again on the next edit") @MainActor
    func brokenFormulasAreNotParsedAgainOnTheNextEdit() throws {
        let fixture = try Fixture(suffix: "broken-no-reparse", markdown: "")
        // Leave the engine's "transient" flag set, as a memory refusal would:
        // the label must not take it for its own formulas.
        let previous = ratex_bridge_set_live_bytes_limit(0)
        defer { ratex_bridge_set_live_bytes_limit(previous) }
        _ = MathRenderer.formula(tex: "t_{flag}", isDisplay: false, pixelSize: 20)
        ratex_bridge_set_live_bytes_limit(previous)
        // More than the formula cache holds, so only the label remembers.
        let formulas = (0..<(MathRenderer.cacheLimit + 88)).map { "$\\nosuchmacro{e\($0)}$" }.joined(separator: " ")
        MathRenderer.withParseBudget(.seconds(30)) {
            fixture.preview.render(blocks: MarkdownRenderer().blocks(for: "Broken \(formulas) end.", darkAppearance: false))
        }
        let before = MathRenderer.parseCount
        fixture.render("Broken \(formulas) end!")
        #expect(MathRenderer.parseCount == before, "\(MathRenderer.parseCount - before) formulas parsed again")
    }

    @Test("Changing a heading's level in a single-label note resizes its formula") @MainActor
    func changingAHeadingsLevelInASingleLabelNoteResizesItsFormula() throws {
        let fixture = try Fixture(suffix: "custom-heading-level", markdown: "", configure: { $0.debugForceCustomTextLayout = true })
        fixture.render("# Title $a$\n\nBody $b$ text.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let large = try #require(PreviewMath.debugFormulas(on: label).first).pixelSize
        fixture.render("### Title $a$\n\nBody $b$ text.")
        let small = try #require(PreviewMath.debugFormulas(on: label).first).pixelSize
        #expect(small < large * 0.9, "\(large) → \(small)")
    }

    @Test("A search hit after display math inside a sentence lands on its word") @MainActor
    func aSearchHitAfterDisplayMathInsideASentenceLandsOnItsWord() throws {
        let fixture = try Fixture(suffix: "search-after-display-inline", markdown: "a $$\\frac{1}{2}$$ c needle.")
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["needle"])
    }

    @Test("Text with formulas keeps a label of its own") @MainActor
    func textWithFormulasKeepsALabelOfItsOwn() throws {
        // GTK draws each formula over its whole label, so such labels stay small.
        let fixture = try Fixture(suffix: "own-label", markdown: "# Head\n\nPlain one.\n\nWith $x$ math.\n\nPlain two.")
        let texts = fixture.labels().map(\.text)
        #expect(texts.contains("With \u{FFFC} math."), "\(texts)")
        #expect(!texts.contains { $0.contains("\u{FFFC}") && $0.contains("Plain") }, "\(texts)")
        // In every order and kind of run: a heading with a formula, plain
        // text before a formula, quotes.
        for markdown in [
            "# Head $y$\n\nPlain after heading.",
            "```\nc\n```\n\nPlain first.\n\nWith $x$ math.",
            "> plain quote\n\n> quote with $q$",
        ] {
            fixture.render(markdown)
            let labels = fixture.labels().map(\.text)
            #expect(!labels.contains { $0.contains("\u{FFFC}") && ($0.contains("Plain") || $0.contains("plain")) }, "\(labels)")
        }
    }

    @Test("A rebuilt row is highlighted again by the same matches") @MainActor
    func aRebuiltRowIsHighlightedAgainByTheSameMatches() throws {
        let fixture = try Fixture(suffix: "rebuilt-rehighlight", markdown: "A needle $x$ here.\n\n```\nc\n```")
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        fixture.render("# A needle $x$ here.\n\n```\nc\n```")
        // The search finds the same matches; they must not be skipped as
        // already applied — they were applied to a label that is gone.
        let again = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: again, activeIndex: 0)
        let heading = try #require(fixture.labels().first { $0.text.hasPrefix("A needle") })
        #expect(preview.debugHighlightedLabelPointers == [heading.opaquePointer])
    }

    @Test("A label draws only the formulas its budget allows") @MainActor
    func aLabelDrawsOnlyTheFormulasItsBudgetAllows() throws {
        let formulas = (0..<600).map { "$\\frac{a_{\($0)}}{b}$" }.joined(separator: " ")
        let fixture = try Fixture(suffix: "budget", markdown: "")
        MathRenderer.withParseBudget(.seconds(60)) {
            fixture.preview.render(blocks: MarkdownRenderer().blocks(for: "Many \(formulas) end.", darkAppearance: false))
        }
        MainContext.pump(for: .milliseconds(100))
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        let drawn = PreviewMath.debugFormulas(on: label).count
        #expect(drawn > 0)
        #expect(drawn < 600, "\(drawn) drawn")
        // …and not far fewer than the code's own model allows (a node at
        // most the monitor's size, which the window may grow to).
        let layout = try #require(gtk_label_get_layout(label.opaquePointer))
        var ink = PangoRectangle()
        var logical = PangoRectangle()
        pango_layout_get_pixel_extents(layout, &ink, &logical)
        let modelArea = min(Double(logical.width) * Double(logical.height), monitorArea(of: label))
        let allowed = PreviewMath.drawnFormulaBudget / (modelArea * 4)
        #expect(Double(drawn) >= allowed / 2, "\(drawn) drawn, about \(Int(allowed)) allowed")
        // The rest show their source.
        #expect(label.text.contains("$\\frac{a_{599}}{b}$"))
    }

    @Test("The budget goes by the label as its formulas leave it") @MainActor
    func theBudgetGoesByTheLabelAsItsFormulasLeaveIt() throws {
        // Zero-width but tall: each adds a line of its own height, which the
        // text alone does not show.
        let formulas = (0..<300).map { "$\\rule{0pt}{60em}_{\($0)}$" }.joined(separator: " ")
        let fixture = try Fixture(suffix: "budget-tall", markdown: "")
        MathRenderer.withParseBudget(.seconds(60)) {
            fixture.preview.render(blocks: MarkdownRenderer().blocks(for: "Tall \(formulas) end.", darkAppearance: false))
        }
        // Measured once GTK has sized the label.
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let drawn = PreviewMath.debugFormulas(on: label).count
        let layout = try #require(gtk_label_get_layout(label.opaquePointer))
        var ink = PangoRectangle()
        var logical = PangoRectangle()
        pango_layout_get_pixel_extents(layout, &ink, &logical)
        #expect(drawn > 0)
        // Within the budget as GTK draws it…
        #expect(Double(drawn) * nodeArea(of: label) * 4 <= PreviewMath.drawnFormulaBudget * 1.05, "\(drawn) drawn")
        // …and not far under it by the code's own model (a node at most the
        // monitor's size, which the window may grow to).
        let modelArea = min(Double(logical.width) * Double(logical.height), monitorArea(of: label))
        #expect(Double(drawn) * modelArea * 4 >= PreviewMath.drawnFormulaBudget / 2, "\(drawn) drawn in \(logical.width)×\(logical.height)")
    }

    @Test(
        "The budget holds for wide and for many small formulas, the same after an edit",
        arguments: ["sums", "rules", "fractions", "empty-rules", "double-spaced"]
    ) @MainActor
    func theBudgetHoldsForWideAndManySmallFormulas(kind: String) throws {
        let formulas = switch kind {
        case "sums": (0..<200).map { n in "$" + (0..<40).map { "x_{\($0)}" }.joined(separator: "+") + "+n_{\(n)}$" }
        // Each wider than half the label: a line of its own.
        case "rules": (0..<150).map { "$\\rule{60em}{0.5em}_{\($0)}$" }
        // Next to nothing drawn, but long as source: the label grows as
        // formulas are dropped.
        case "empty-rules": (0..<520).map { _ in "$\\rule{0pt}{0pt}$" }
        default: (0..<300).map { "$\\frac{a_{\($0)}}{b}$" }
        }
        let fixture = try Fixture(suffix: "budget-\(kind)", markdown: "")
        if kind == "double-spaced" {
            // CSS line-height, which the estimate has to take from the label.
            fixture.preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 200)
        }
        defer { fixture.preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 100) }
        func render(_ end: String) {
            MathRenderer.withParseBudget(.seconds(60)) {
                fixture.preview.render(blocks: MarkdownRenderer().blocks(
                    for: "Start " + formulas.joined(separator: " ") + end, darkAppearance: false
                ))
            }
            pumpUntil(timeout: .seconds(3)) { !fixture.preview.debugMathFontRefreshPending }
        }
        func cost() throws -> (drawn: Int, bytes: Double) {
            let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
            let drawn = PreviewMath.debugFormulas(on: label).count
            return (drawn, Double(drawn) * nodeArea(of: label) * 4)
        }
        render(" end.")
        let first = try cost()
        #expect(first.drawn > 0)
        #expect(first.bytes <= PreviewMath.drawnFormulaBudget * 1.1, "\(first.drawn) drawn, \(Int(first.bytes / 1_048_576)) MiB")
        // The decision depends on the note, not on what the label showed before.
        render(" end!")
        let edited = try cost()
        #expect(edited.drawn == first.drawn)
    }

    @Test("A window grown after the render stays within the budget") @MainActor
    func aWindowGrownAfterTheRenderStaysWithinTheBudget() throws {
        // Fits easily in a small window; maximised, each formula's node may
        // cover far more.
        let prose = (0..<170).map { "$x_{\($0)}$ and some words between them" }.joined(separator: " ")
        let fixture = try Fixture(suffix: "budget-grow", markdown: prose, size: (400, 300))
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        // Without a window manager (CI's xvfb) maximising does nothing; a
        // size request grows the window anywhere.
        fixture.preview.rootScroll.setSizeRequest(width: 1000, height: 700)
        defer { fixture.preview.rootScroll.setSizeRequest(width: -1, height: -1) }
        MainContext.pump(for: .milliseconds(200))
        pumpUntil(timeout: .seconds(3)) { !fixture.preview.debugMathFontRefreshPending }
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(label.width > 600, "the window grew: label \(label.width) px wide")
        let drawn = PreviewMath.debugFormulas(on: label).count
        #expect(Double(drawn) * nodeArea(of: label) * 4 <= PreviewMath.drawnFormulaBudget * 1.1, "\(drawn) drawn")
    }

    @Test("Zooming in keeps a label within the budget") @MainActor
    func zoomingInKeepsALabelWithinTheBudget() throws {
        let prose = (0..<90).map { "$\\frac{a_{\($0)}}{b}$ with some prose" }.joined(separator: " ")
        let fixture = try Fixture(suffix: "budget-zoom-in", markdown: prose)
        let preview = fixture.preview
        pumpUntil(timeout: .seconds(2)) { !preview.debugMathFontRefreshPending }
        defer { preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 100) }
        preview.applyTypography(zoomPercent: 200, lineSpacingPercent: 100)
        pumpUntil(timeout: .seconds(3)) { !preview.debugMathFontRefreshPending }
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let drawn = PreviewMath.debugFormulas(on: label).count
        #expect(Double(drawn) * nodeArea(of: label) * 4 <= PreviewMath.drawnFormulaBudget * 1.1, "\(drawn) drawn")
    }

    @Test("Text inking far past its box draws no formulas") @MainActor
    func textInkingFarPastItsBoxDrawsNoFormulas() throws {
        // A stack of combining marks inks thousands of pixels above one line,
        // and GTK sizes every formula's node by the label's ink.
        // A few formulas are within budget even if each costs the whole
        // visible area; many next to the stack are not drawn at all.
        let stack = "a" + String(repeating: "\u{352}", count: 1000)
        let many = (0..<200).map { "$x_{\($0)}$" }.joined(separator: " ")
        let fixture = try Fixture(suffix: "ink-stack", markdown: "\(stack) \(many) \(stack)")
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let drawn = PreviewMath.debugFormulas(on: label).count
        // Within budget whatever the font does with the marks…
        #expect(Double(drawn) * nodeArea(of: label) * 4 <= PreviewMath.drawnFormulaBudget * 1.1, "\(drawn) drawn")
        // …and where it stacks them far above the line (fonts differ), none.
        let layout = try #require(gtk_label_get_layout(label.opaquePointer))
        var ink = PangoRectangle()
        var logical = PangoRectangle()
        pango_layout_get_pixel_extents(layout, &ink, &logical)
        if Double(ink.height) > 8 * Double(max(1, logical.height)) {
            #expect(drawn == 0, "ink \(ink.height) px over a \(logical.height) px box")
            #expect(label.text.contains("$x_{1}$"))
        }
        // Ordinary accents are fine.
        fixture.render("Café naïve $x_0$ $x_1$ résumé")
        let plain = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: plain).count == 2)
    }

    @Test("A long ordinary paragraph draws all its formulas") @MainActor
    func aLongOrdinaryParagraphDrawsAllItsFormulas() throws {
        // Laid out before GTK sizes it, the label is one character wide; the
        // budget must not go by that.
        let words = String(repeating: "lorem ipsum dolor sit amet ", count: 45)
        let formulas = (0..<10).map { $0 == 3 ? "$\\alpha+\\beta+\\gamma+\\delta+\\epsilon+\\kappa$" : "$x_{\($0)}$" }
        let fixture = try Fixture(suffix: "long-ordinary", markdown: words + formulas.joined(separator: " " + words.prefix(80)))
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: label).count == 10)
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        #expect(PreviewMath.debugFormulas(on: label).count == 10)
    }

    @Test("Zooming in and back out keeps the formulas a label draws") @MainActor
    func zoomingInAndBackOutKeepsTheFormulasALabelDraws() throws {
        let fixture = try Fixture(suffix: "budget-zoom", markdown: "Many " + (0..<120).map { "$\\frac{a_{\($0)}}{b}$" }.joined(separator: " "))
        let preview = fixture.preview
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        pumpUntil(timeout: .seconds(2)) { !preview.debugMathFontRefreshPending }
        let before = PreviewMath.debugFormulas(on: label).count
        defer { preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 100) }
        preview.applyTypography(zoomPercent: 200, lineSpacingPercent: 100)
        pumpUntil(timeout: .seconds(2)) { !preview.debugMathFontRefreshPending }
        preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 100)
        pumpUntil(timeout: .seconds(2)) { !preview.debugMathFontRefreshPending }
        #expect(PreviewMath.debugFormulas(on: label).count == before)
    }

    @Test("A tall formula while typing does not cut the paragraph for good") @MainActor
    func aTallFormulaWhileTypingDoesNotCutTheParagraphForGood() throws {
        let formulas = (0..<40).map { "$y_{\($0)}$" }.joined(separator: " ")
        let fixture = try Fixture(suffix: "budget-edit", markdown: "Edit $\\rule{1pt}{1em}$ \(formulas)")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        let before = PreviewMath.debugFormulas(on: label).count
        fixture.render("Edit $\\rule{1pt}{100em}$ \(formulas)")
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        fixture.render("Edit $\\rule{1pt}{1em}$ \(formulas)")
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
        #expect(PreviewMath.debugFormulas(on: label).count == before)
    }

    @Test("Inline formulas taller than the cap show their source") @MainActor
    func inlineFormulasTallerThanTheCapShowTheirSource() throws {
        let fixture = try Fixture(suffix: "too-tall", markdown: "Tall $\\rule{0pt}{200em}$ and $y$.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["y"])
    }

    @Test("Editing a paragraph re-installs its formulas") @MainActor
    func editingParagraphReinstallsFormulas() throws {
        let fixture = try Fixture(suffix: "edit", markdown: "Text $a$ here.\n\nSecond paragraph.")
        fixture.render("Text $a$ and $b$ here.\n\nSecond paragraph.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["a", "b"])
        #expect(PreviewMath.debugShapeAttributeCount(on: label) == 2)
        // A paragraph with formulas is a label of its own.
        #expect(gtkAccessibleLabelMismatch(of: label, expected: "Text $a$ and $b$ here.") == nil)
        fixture.render("Text without math.\n\nSecond paragraph.")
        let plain = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: plain).isEmpty)
        #expect(PreviewMath.debugShapeAttributeCount(on: plain) == 0)
        // The accessible label no longer spells out formulas that are gone.
        #expect(gtkAccessibleLabelMismatch(of: plain, expected: "Text without math.\n\nSecond paragraph.") == nil)
    }

    @Test("Editing a formula's TeX in place draws the new formula") @MainActor
    func editingAFormulasTexInPlaceDrawsTheNewFormula() throws {
        let fixture = try Fixture(suffix: "edit-tex", markdown: "Text $a$ here.\n\nSecond paragraph.")
        fixture.render("Text $b$ here.\n\nSecond paragraph.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["b"])
    }

    @Test("Search highlights come back after postponed formulas are drawn") @MainActor
    func searchHighlightsComeBackAfterPostponedFormulasAreDrawn() throws {
        let fixture = try Fixture(suffix: "postponed-search", markdown: "")
        // No main-loop run inside the budget: the follow-up pass would draw it.
        MathRenderer.withParseBudget(.zero) {
            fixture.preview.render(blocks: MarkdownRenderer().blocks(for: "Late $q_{searched}$ formula needle.", darkAppearance: false))
        }
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        let highlighted = attributeCount(on: label)
        #expect(highlighted > 0)
        pumpUntil(timeout: .milliseconds(800)) { !PreviewMath.debugFormulas(on: label).isEmpty }
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["q_{searched}"])
        #expect(attributeCount(on: label) == highlighted + 1, "the highlight and the formula shape")
    }

    @Test("Formulas postponed by the parse budget are drawn on the next frames") @MainActor
    func postponedFormulasAreDrawnLater() throws {
        let fixture = try Fixture(suffix: "postponed", markdown: "")
        // No main-loop run inside the budget: the follow-up pass would draw it.
        MathRenderer.withParseBudget(.zero) {
            fixture.preview.render(blocks: MarkdownRenderer().blocks(for: "Late $q_{postponed}$ formula.", darkAppearance: false))
        }
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: label).isEmpty)
        pumpUntil(timeout: .milliseconds(800)) { !PreviewMath.debugFormulas(on: label).isEmpty }
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["q_{postponed}"])
        #expect(label.text == "Late \u{FFFC} formula.")
    }

    @Test("Formulas too wide or too large to draw show their source") @MainActor
    func formulasTooWideOrTooLargeToDrawShowTheirSource() throws {
        let fixture = try Fixture(suffix: "too-wide", markdown: "Wide $x\\hspace{600em}x$ and $y$.\n\n$$\n\\rule{300em}{300em}\n$$")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["y"])
        #expect(label.text.contains("$x\\hspace{600em}x$"))
        let block = try #require(fixture.firstLabel(withCSSClass: "preview-math-label"))
        #expect(PreviewMath.debugFormulas(on: block).isEmpty)
        #expect(block.text.contains("\\rule{300em}{300em}"))
    }

    @Test("A long label is shown again only once all its postponed formulas are ready") @MainActor
    func aLongLabelIsShownAgainOnlyOnceAllItsPostponedFormulasAreReady() throws {
        let fixture = try Fixture(suffix: "postponed-deferred", markdown: "")
        let markdown = "Many " + (0..<12).map { "$d_{\($0)}$" }.joined(separator: " ") + " end."
        MathRenderer.withParseBudget(.zero) {
            fixture.preview.render(blocks: MarkdownRenderer().blocks(for: markdown, darkAppearance: false))
        }
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let textBefore = label.text
        #expect(PreviewMath.debugFormulas(on: label).isEmpty)
        // One formula per pass: the label stays as it was until the last one.
        var passes = 0
        while MathRenderer.withParseBudget(.zero, guaranteeingProgress: true, {
            PreviewMath.layOutPostponedFormulas(under: fixture.preview.rootScroll)
        }) {
            passes += 1
            #expect(label.text == textBefore)
            #expect(PreviewMath.debugFormulas(on: label).isEmpty)
            if passes > 20 { break }
        }
        #expect(passes == 11)
        #expect(PreviewMath.debugFormulas(on: label).count == 12)
    }

    @Test("Postponed passes end on a label with more broken formulas than the cache holds") @MainActor
    func postponedPassesEndOnALabelWithMoreBrokenFormulasThanTheCacheHolds() throws {
        let fixture = try Fixture(suffix: "postponed-broken", markdown: "")
        let count = MathRenderer.cacheLimit + 188
        let markdown = "Broken " + (0..<count).map { "$\\nosuchmacro{\($0)}$" }.joined(separator: " ") + " end."
        MathRenderer.withParseBudget(.zero) {
            fixture.preview.render(blocks: MarkdownRenderer().blocks(for: markdown, darkAppearance: false))
        }
        var passes = 0
        while passes <= count * 2, MathRenderer.withParseBudget(.zero, guaranteeingProgress: true, {
            PreviewMath.layOutPostponedFormulas(under: fixture.preview.rootScroll)
        }) {
            passes += 1
        }
        #expect(passes < count, "one formula per pass, each decided once: \(passes) passes")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(label.text.contains("$\\nosuchmacro{\(count - 1)}$"))
    }

    @Test("Formulas are still drawn after the preview is moved to another parent") @MainActor
    func formulasAreStillDrawnAfterThePreviewIsMovedToAnotherParent() throws {
        // Switching Split ↔ Preview moves the preview between containers; GTK
        // then gives its labels a new Pango context.
        let fixture = try Fixture(suffix: "reparent", markdown: "$\\blacksquare\\blacksquare\\blacksquare$")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        func ink() -> Int {
            var count = 0
            forEachRenderedPixel(of: label) { _, _, _, a in
                if a > 200 { count += 1 }
            }
            return count
        }
        pumpUntil(timeout: .milliseconds(500)) { ink() > 150 }
        #expect(ink() > 150, "drawn before the move")
        let box = Box(orientation: .vertical)
        fixture.window.setContent(box)
        box.append(fixture.preview.rootScroll)
        MainContext.pump(for: .milliseconds(100))
        box.remove(fixture.preview.rootScroll)
        fixture.window.setContent(fixture.preview.rootScroll)
        pumpUntil(timeout: .milliseconds(500)) { ink() > 150 }
        #expect(ink() > 150, "drawn after the move")
    }

    @Test("Formulas stay drawn when the main window switches between view modes") @MainActor
    func formulasStayDrawnWhenTheMainWindowSwitchesBetweenViewModes() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let repository = NotesRepository(notesDirectory: temp)
        _ = try repository.createNote(initialContent: "# Squares\n\n$\\blacksquare\\blacksquare\\blacksquare$")
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.math.viewmodes")
        try app.register()
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )
        window.debugLoadInitialNotes()
        // Wide enough for the editor and the preview side by side.
        window.window.setDefaultSize(width: 1400, height: 900)
        window.present()
        // Closed after, so its labels stop reacting to later tests' changes.
        defer { window.window.close() }
        window.debugSelectDisplayedNote(at: 0)

        func formulaInk() -> Int {
            _ = window.debugPreviewText // renders a pending refresh
            var labels: [Label] = []
            var stack: [Widget] = [window.preview.rootScroll]
            while let widget = stack.popLast() {
                if let label = widget.tryCast(Label.self), label.hasCSSClass("preview-paragraph-label") {
                    labels.append(label)
                }
                stack.append(contentsOf: widget.children())
            }
            var count = 0
            for label in labels where !PreviewMath.debugFormulas(on: label).isEmpty {
                forEachRenderedPixel(of: label) { _, _, _, a in
                    if a > 200 { count += 1 }
                }
            }
            return count
        }
        for (step, mode) in [EditorViewMode.split, .preview, .split, .editor, .split, .preview].enumerated() {
            window.setViewMode(mode, animated: false)
            guard mode != .editor else {
                MainContext.pump(for: .milliseconds(100))
                continue
            }
            pumpUntil(timeout: .seconds(2)) { formulaInk() > 150 }
            #expect(formulaInk() > 150, "formulas drawn in \(mode) (step \(step))")
        }
        // Other changes around the preview: the sidebars, the colour scheme.
        let styleManager = StyleManager.default
        let originalScheme = styleManager.colorScheme
        defer { styleManager.colorScheme = originalScheme }
        let changes: [(String, () -> Void)] = [
            ("sidebar hidden", { window.toggleSidebarVisibility() }),
            ("sidebar shown", { window.toggleSidebarVisibility() }),
            ("outline toggled", { window.toggleOutlineVisibility() }),
            ("outline toggled back", { window.toggleOutlineVisibility() }),
            ("dark scheme", { styleManager.colorScheme = .forceDark }),
            ("light scheme", { styleManager.colorScheme = .forceLight }),
        ]
        for (name, change) in changes {
            change()
            MainContext.pump(for: .milliseconds(100))
            pumpUntil(timeout: .seconds(2)) { formulaInk() > 150 }
            #expect(formulaInk() > 150, "formulas drawn after \(name)")
        }
    }

    @Test("A note title's formulas are drawn in the sidebar, outline and breadcrumb, and read in the subtitle") @MainActor
    func aNoteTitlesFormulasAreDrawnOutsideThePreview() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let repository = NotesRepository(notesDirectory: temp)
        _ = try repository.createNote(initialContent: "# Formulas $e^{i\\pi} + 1 = 0$\n\nBody.")
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.math.titles")
        try app.register()
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )
        window.debugLoadInitialNotes()
        window.window.setDefaultSize(width: 1400, height: 900)
        window.present()
        // Closed after, so its labels stop reacting to later tests' changes.
        defer { window.window.close() }
        window.debugSelectDisplayedNote(at: 0)
        _ = window.debugPreviewText
        MainContext.pump(for: .milliseconds(200))

        func drawnTeX(under root: Widget) -> [String] {
            var found: [String] = []
            var stack: [Widget] = [root]
            while let widget = stack.popLast() {
                if let label = widget.tryCast(Label.self) {
                    found += PreviewMath.debugFormulas(on: label).map(\.tex)
                }
                stack.append(contentsOf: widget.children())
            }
            return found
        }
        let tex = "e^{i\\pi} + 1 = 0"
        // Formulas past the shared parse budget come a pass later.
        pumpUntil(timeout: .seconds(2)) {
            drawnTeX(under: window.sidebar.root) == [tex] && drawnTeX(under: window.outlineSidebar.root) == [tex]
                && drawnTeX(under: window.breadcrumb.root).contains(tex)
        }
        #expect(drawnTeX(under: window.sidebar.root) == [tex], "sidebar")
        #expect(drawnTeX(under: window.outlineSidebar.root) == [tex], "outline")
        #expect(drawnTeX(under: window.breadcrumb.root).contains(tex), "breadcrumb")
        var tooltips: [String] = []
        var stack: [Widget] = [window.outlineSidebar.root]
        while let widget = stack.popLast() {
            if let label = widget.tryCast(Label.self), let tooltip = label.tooltipText { tooltips.append(tooltip) }
            stack.append(contentsOf: widget.children())
        }
        #expect(tooltips.contains("Formulas e^(iπ) + 1 = 0"), "\(tooltips)")
        // Screen readers hear the title's formula as text, not TeX.
        var sidebarTitles: [Label] = []
        var sidebarStack: [Widget] = [window.sidebar.root]
        while let widget = sidebarStack.popLast() {
            if let label = widget.tryCast(Label.self), !PreviewMath.debugFormulas(on: label).isEmpty { sidebarTitles.append(label) }
            sidebarStack.append(contentsOf: widget.children())
        }
        let sidebarTitle = try #require(sidebarTitles.first)
        #expect(gtkAccessibleLabelMismatch(of: sidebarTitle, expected: "Formulas e^(iπ) + 1 = 0") == nil)
        // Formulas are sized like the text around them (KaTeX's 1.21 em),
        // also after the desktop font changes.
        func formulaSizes() -> [(label: Double, formula: Double)] {
            var found: [(Double, Double)] = []
            for root in [window.sidebar.root, window.outlineSidebar.root, window.breadcrumb.root] {
                var stack: [Widget] = [root]
                while let widget = stack.popLast() {
                    if let label = widget.tryCast(Label.self) {
                        for formula in PreviewMath.debugFormulas(on: label) {
                            found.append((PreviewMath.debugFontPixels(of: label) * PreviewMath.formulaScale, formula.pixelSize))
                        }
                    }
                    stack.append(contentsOf: widget.children())
                }
            }
            return found
        }
        func expectSizedLikeText(_ step: String) {
            let sizes = formulaSizes()
            #expect(sizes.count >= 3, "\(step)")
            for size in sizes {
                #expect(abs(size.label - size.formula) < 0.5, "\(step): \(sizes)")
            }
        }
        pumpUntil(timeout: .seconds(2)) { formulaSizes().allSatisfy { abs($0.label - $0.formula) < 0.5 } }
        expectSizedLikeText("shown")
        // Well after any refresh that showing the labels started.
        MainContext.pump(for: .milliseconds(600))
        let originalFont = desktopFontName
        defer { desktopFontName = originalFont }
        desktopFontName = "Sans 21"
        pumpUntil(timeout: .seconds(2)) { formulaSizes().allSatisfy { abs($0.label - $0.formula) < 0.5 } && (formulaSizes().first?.formula ?? 0) > 30 }
        expectSizedLikeText("after a desktop font change")

        // Filtering keeps the formula drawn, the match on it highlighted.
        window.outlineSidebar.setQuery("pi")
        pumpUntil(timeout: .seconds(2)) { drawnTeX(under: window.outlineSidebar.root) == [tex] }
        #expect(drawnTeX(under: window.outlineSidebar.root) == [tex], "filtered outline")
        window.outlineSidebar.setQuery("")
        #expect(window.debugHeaderSubtitle.hasPrefix("Formulas e^(iπ) + 1 = 0"), "\(window.debugHeaderSubtitle)")
    }

    @Test("Command palette rows draw their headings' formulas, filtered or not, and the parent's") @MainActor
    func commandPaletteRowsDrawFormulas() throws {
        let fixture = try Fixture(suffix: "palette", markdown: "")
        let palette = CommandPaletteWindow(
            transientFor: fixture.window,
            headings: [
                Heading(id: "area", level: 2, text: "Area $\\pi r^2$", blockIndex: 0, line: 1),
                Heading(id: "angle", level: 3, text: "Angle $\\alpha$", blockIndex: 1, line: 3),
            ],
            currentID: nil,
            recents: [],
            onPick: { _ in },
            onClosed: {},
        )
        func drawnTeX() -> [String] {
            var found: [String] = []
            var stack: [Widget] = [palette.debugList]
            while let widget = stack.popLast() {
                if let label = widget.tryCast(Label.self) {
                    found += PreviewMath.debugFormulas(on: label).map(\.tex)
                }
                stack.append(contentsOf: widget.children())
            }
            return found.sorted()
        }
        // The H3 row names its H2 parent, formula and all. (Formulas past
        // the shared parse budget come a pass later.)
        pumpUntil(timeout: .seconds(2)) { drawnTeX().count == 3 }
        #expect(drawnTeX() == ["\\alpha", "\\pi r^2", "\\pi r^2"])
        // Filtered, the matching rows still draw (the match on the formula
        // highlighted), rather than show their TeX. "pi" keeps both: the H3
        // matches through its parent.
        palette.debugSetQuery("pi")
        #expect(Set(palette.debugItems.map(\.id)) == ["area", "angle"])
        pumpUntil(timeout: .seconds(2)) { drawnTeX().count == 3 }
        #expect(drawnTeX() == ["\\alpha", "\\pi r^2", "\\pi r^2"])
    }

    @Test("A title label draws its formula's ink") @MainActor
    func aTitleLabelDrawsItsFormulasInk() throws {
        let fixture = try Fixture(suffix: "title-ink", markdown: "")
        let box = Box(orientation: .vertical, spacing: 0)
        fixture.window.setContent(box)
        let label = Label("")
        PreviewMath.show("$\\blacksquare\\blacksquare\\blacksquare$", in: label)
        box.append(label)
        func ink() -> Int {
            var count = 0
            forEachRenderedPixel(of: label) { _, _, _, a in
                if a > 200 { count += 1 }
            }
            return count
        }
        pumpUntil(timeout: .seconds(2)) { ink() > 150 }
        #expect(ink() > 150)
    }

    @Test("Title labels with formulas are freed when removed right after they are shown or the font changes") @MainActor
    func titleLabelsWithFormulasAreFreedWhenRemovedEarly() throws {
        let fixture = try Fixture(suffix: "title-free", markdown: "")
        let box = Box(orientation: .vertical, spacing: 0)
        fixture.window.setContent(box)
        let notify: GWeakNotify = { _, _ in finalizedLabelCount += 1 }

        /// Shows `count` title labels, runs `between` once they are mapped,
        /// removes them at once and returns how many were freed.
        func freedLabels(count: Int, between: () -> Void) -> Int {
            finalizedLabelCount = 0
            do {
                var labels: [Label] = []
                for index in 0..<count {
                    let label = Label("")
                    PreviewMath.show("Row $x_{\(index)}$", in: label)
                    g_object_weak_ref(UnsafeMutablePointer<GObject>(label.opaquePointer), notify, nil)
                    box.append(label)
                    labels.append(label)
                }
                pumpUntil(timeout: .seconds(1)) { labels.allSatisfy { gtk_widget_get_mapped($0.widgetPointer) != 0 } }
                between()
                for label in labels {
                    box.remove(label)
                }
            }
            pumpUntil(timeout: .seconds(1)) { finalizedLabelCount == count }
            return finalizedLabelCount
        }

        #expect(freedLabels(count: 5) {} == 5, "removed right after being shown")
        let originalFont = desktopFontName
        defer { desktopFontName = originalFont }
        let freedAfterFontChange = freedLabels(count: 5) {
            MainContext.pump(for: .milliseconds(400))
            desktopFontName = "Sans 19"
            MainContext.pump(for: .milliseconds(20))
        }
        #expect(freedAfterFontChange == 5, "removed right after a font change")
    }

    @Test("Formulas outside the preview past the parse budget show their source, then get drawn") @MainActor
    func formulasOutsideThePreviewPastTheParseBudgetGetDrawnLater() throws {
        let fixture = try Fixture(suffix: "outside-budget", markdown: "") // brings GTK up
        _ = fixture
        MathRenderer.removeAllCachedFormulas()
        let budget = PreviewMath.titleScheduler.budget
        PreviewMath.titleScheduler.budget = .zero
        defer { PreviewMath.titleScheduler.budget = budget }
        // Whatever earlier tests postponed in the preview is done with.
        _ = PreviewMath.layOutPostponedFormulas(under: Box(orientation: .vertical, spacing: 0))
        let label = Label("")
        PreviewMath.show("Budget $\\alpha_1$ and $\\beta_2$", in: label)
        // Nothing parsed within the (spent) budget: both wait, as source.
        #expect(PreviewMath.debugFormulas(on: label).isEmpty)
        #expect(label.text.contains("$\\alpha_1$"))
        // The preview's own catch-up is not woken for it: its row binds
        // would walk their tree for nothing.
        #expect(!PreviewMath.debugMayHavePostponedFormulas)
        pumpUntil(timeout: .seconds(2)) { PreviewMath.debugFormulas(on: label).count == 2 }
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["\\alpha_1", "\\beta_2"])
    }

    @Test("One long pass does not renew the parse budget of labels outside the preview") @MainActor
    func oneLongPassDoesNotRenewTheOutsideParseBudget() throws {
        let fixture = try Fixture(suffix: "outside-budget-pass", markdown: "")
        _ = fixture
        MathRenderer.removeAllCachedFormulas()
        // Any earlier period is over and its main-loop pass has ended.
        MainContext.pump(for: .milliseconds(150))
        let first = Label("")
        PreviewMath.show("Start $\\gamma_3$", in: first)
        #expect(PreviewMath.debugFormulas(on: first).count == 1)
        // The same pass keeps working (a long outline rebuild) past a period.
        Thread.sleep(forTimeInterval: 0.15)
        let second = Label("")
        PreviewMath.show("Later $\\delta_4$", in: second)
        #expect(PreviewMath.debugFormulas(on: second).isEmpty, "the budget renewed within one pass")
        pumpUntil(timeout: .seconds(2)) { PreviewMath.debugFormulas(on: second).count == 1 }
        #expect(PreviewMath.debugFormulas(on: second).count == 1)
    }

    @Test("The catch-up pass for labels outside the preview forces at most one formula per period") @MainActor
    func theOutsideCatchUpIsPaced() throws {
        let fixture = try Fixture(suffix: "outside-budget-pace", markdown: "")
        _ = fixture
        MathRenderer.removeAllCachedFormulas()
        let budget = PreviewMath.titleScheduler.budget
        PreviewMath.titleScheduler.budget = .zero
        defer { PreviewMath.titleScheduler.budget = budget }
        let labels = (0..<30).map { _ in Label("") }
        for (index, label) in labels.enumerated() {
            PreviewMath.show("Row $z_{\(index + 100)}$", in: label)
        }
        let before = MathRenderer.parseCount
        MainContext.pump(for: .milliseconds(300))
        let parsed = MathRenderer.parseCount - before
        #expect(parsed >= 1, "postponed formulas still come")
        #expect(parsed <= 6, "forced \(parsed) parses in 300 ms")
        pumpUntil(timeout: .seconds(6)) { labels.allSatisfy { PreviewMath.debugFormulas(on: $0).count == 1 } }
        #expect(labels.allSatisfy { PreviewMath.debugFormulas(on: $0).count == 1 })
    }

    @Test("A parse that overruns the budget leaves the UI its share before the next") @MainActor
    func aParseThatOverrunsTheBudgetLeavesTheUIItsShare() throws {
        let fixture = try Fixture(suffix: "outside-budget-overrun", markdown: "")
        _ = fixture
        MathRenderer.removeAllCachedFormulas()
        MainContext.pump(for: .milliseconds(150))
        // A catch-up pass whose one parse takes longer than a whole period
        // (heavy mhchem on a slow machine).
        PreviewMath.titleScheduler.withBudget(fromCatchUpPass: true) {
            _ = MathRenderer.formula(tex: "\\eta_7", isDisplay: false, pixelSize: 16)
            Thread.sleep(forTimeInterval: 0.12)
        }
        // The next pass, straight after, must not parse again at once.
        var postponed = false
        PreviewMath.titleScheduler.withBudget(fromCatchUpPass: true) {
            _ = MathRenderer.formula(tex: "\\theta_8", isDisplay: false, pixelSize: 16)
            postponed = MathRenderer.lastLookupWasPostponed
        }
        #expect(postponed, "a second forced parse ran back to back")
        // Passes that parse nothing do not hold the period back: once the
        // free share is over, the next pass parses again.
        for _ in 0..<12 {
            PreviewMath.titleScheduler.withBudget(fromCatchUpPass: true) {}
            Thread.sleep(forTimeInterval: 0.016)
        }
        var parsedLater = false
        PreviewMath.titleScheduler.withBudget(fromCatchUpPass: true) {
            _ = MathRenderer.formula(tex: "\\theta_8", isDisplay: false, pixelSize: 16)
            parsedLater = !MathRenderer.lastLookupWasPostponed
        }
        #expect(parsedLater, "the period never renewed")
    }

    @Test("Formulas stay drawn when an opened file's window switches view modes") @MainActor
    func formulasStayDrawnWhenAnOpenedFilesWindowSwitchesViewModes() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Formulas.md", isDirectory: false)
        try "# Squares\n\n$\\blacksquare\\blacksquare\\blacksquare$".write(to: fileURL, atomically: true, encoding: .utf8)
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.math.external")
        try app.register()
        let window = try ExternalDocumentWindow(
            application: app, fileURL: fileURL, renderer: MarkdownRenderer(), autosave: AutosaveCoordinator()
        )
        window.window.setDefaultSize(width: 1400, height: 900)
        window.present()
        // Closed after, so its labels stop reacting to later tests' changes.
        defer { window.window.close() }

        func formulaInk() -> Int {
            var count = 0
            var stack: [Widget] = [window.preview.rootScroll]
            while let widget = stack.popLast() {
                if let label = widget.tryCast(Label.self), !PreviewMath.debugFormulas(on: label).isEmpty {
                    forEachRenderedPixel(of: label) { _, _, _, a in
                        if a > 200 { count += 1 }
                    }
                }
                stack.append(contentsOf: widget.children())
            }
            return count
        }
        for (step, mode) in [EditorViewMode.split, .preview, .split, .editor, .preview].enumerated() {
            window.debugSetViewMode(mode)
            guard mode != .editor else {
                MainContext.pump(for: .milliseconds(100))
                continue
            }
            pumpUntil(timeout: .seconds(2)) { formulaInk() > 150 }
            #expect(formulaInk() > 150, "formulas drawn in \(mode) (step \(step))")
        }
    }

    @Test("Formulas are painted, in the label's colour, and follow a colour change") @MainActor
    func formulasArePaintedInTheLabelsColour() throws {
        // Only a formula: the label's text, drawn in the same colour, must
        // not stand in for formula ink.
        let fixture = try Fixture(suffix: "paint", markdown: "$\\blacksquare\\blacksquare$")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let provider = CSSProvider.loadGlobal(".math-test-red { color: rgb(255, 0, 0); } .math-test-blue { color: rgb(0, 0, 255); }")
        _ = provider
        label.addCSSClass("math-test-red")
        pumpUntil(timeout: .milliseconds(500)) { paintedColours(of: label).red > 0 }
        let red = paintedColours(of: label)
        #expect(red.red > 20, "formula ink in the label colour: \(red)")
        #expect(red.blue == 0)

        // A theme switch restyles the label without re-installing formulas;
        // they must pick the new colour up at draw time.
        label.removeCSSClass("math-test-red")
        label.addCSSClass("math-test-blue")
        pumpUntil(timeout: .milliseconds(500)) { paintedColours(of: label).blue > 0 }
        let blue = paintedColours(of: label)
        #expect(blue.blue > 20, "formula ink after the colour change: \(blue)")
        #expect(blue.red == 0)
    }

    @Test("A formula in a link takes the link's colour") @MainActor
    func aFormulaInALinkTakesTheLinksColour() throws {
        let fixture = try Fixture(suffix: "link-colour", markdown: "[$\\blacksquare\\blacksquare\\blacksquare$](https://example.org)\n\n```\nc\n```\n\nPlain $\\blacksquare\\blacksquare\\blacksquare$")
        let paragraphs = fixture.labels(withCSSClass: "preview-paragraph-label")
        let linked = try #require(paragraphs.first { !$0.text.contains("Plain") })
        let plain = try #require(paragraphs.first { $0.text.contains("Plain") })
        /// The most common opaque colour in the label: the squares' ink.
        func inkColour(of label: Label) -> (Int, Int, Int)? {
            var counts: [Int: Int] = [:]
            forEachRenderedPixel(of: label) { r, g, b, a in
                if a > 200 { counts[(r / 16) << 8 | (g / 16) << 4 | (b / 16), default: 0] += 1 }
            }
            guard let top = counts.max(by: { $0.value < $1.value }), top.value > 100 else { return nil }
            return (top.key >> 8 * 16, (top.key >> 4 & 15) * 16, (top.key & 15) * 16)
        }
        func diagnosis(_ label: Label) -> String {
            var counts: [Int: Int] = [:]
            forEachRenderedPixel(of: label) { r, g, b, a in
                counts[(a / 64) << 12 | (r / 64) << 8 | (g / 64) << 4 | (b / 64), default: 0] += 1
            }
            let top = counts.sorted { $0.value > $1.value }.prefix(6).map { "argb\(String($0.key, radix: 16)):\($0.value)" }
            return "formulas \(PreviewMath.debugFormulas(on: label).count), shapes \(PreviewMath.debugShapeAttributeCount(on: label)), "
                + "size \(gtk_widget_get_width(label.widgetPointer))×\(gtk_widget_get_height(label.widgetPointer)), \(top)"
        }
        let styleManager = StyleManager.default
        let original = styleManager.colorScheme
        defer { styleManager.colorScheme = original }
        for scheme in [AdwColorScheme.forceLight, .forceDark] {
            styleManager.colorScheme = scheme
            MainContext.pump(for: .milliseconds(100))
            pumpUntil(timeout: .seconds(2)) { inkColour(of: linked) != nil && inkColour(of: plain) != nil }
            let link = try #require(inkColour(of: linked), "\(diagnosis(linked))")
            let text = try #require(inkColour(of: plain), "\(diagnosis(plain))")
            // Adwaita draws links in an accent colour, text in a grey.
            let difference = abs(link.0 - text.0) + abs(link.1 - text.1) + abs(link.2 - text.2)
            #expect(difference > 80, "scheme \(scheme): link ink \(link), text ink \(text)")
        }
    }

    @Test("A search hit after a formula starting with a combining mark lands on its word") @MainActor
    func aSearchHitAfterAFormulaStartingWithACombiningMarkLandsOnItsWord() throws {
        // `$` and the mark make one character in the plain text.
        let fixture = try Fixture(suffix: "combining-search", markdown: "a $\u{301}x$ c needle.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        try #require(PreviewMath.debugFormulas(on: label).count == 1)
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "needle", options: .init())
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["needle"])
    }

    @Test("A long note with formulas keeps one label per block") @MainActor
    func aLongNoteWithFormulasKeepsOneLabelPerBlock() throws {
        let markdown = (0..<170).map { "Row \($0) $x_{\($0)}$." }.joined(separator: "\n\n")
        let fixture = try Fixture(suffix: "long-math-note", markdown: "")
        MathRenderer.withParseBudget(.seconds(60)) {
            fixture.preview.render(blocks: MarkdownRenderer().blocks(for: markdown, darkAppearance: false))
        }
        MainContext.pump(for: .milliseconds(200))
        // Not the single-label layout, whose label would be the whole note.
        #expect(!fixture.labels().contains { $0.text.contains("Row 0") && $0.text.contains("Row 1 ") })
    }

    @Test("Formulas in a heading are sized like the heading") @MainActor
    func formulasInCoalescedHeadingAreSizedLikeTheHeading() throws {
        let fixture = try Fixture(suffix: "heading-size", markdown: "# Euler $e^x$\n\nBody $e^x$ text.\n\n- item $e^x$")
        let formulas = fixture.labels().flatMap { PreviewMath.debugFormulas(on: $0) }
        #expect(formulas.count == 3)
        if formulas.count == 3 {
            #expect(formulas[0].pixelSize > formulas[1].pixelSize * 1.3, "\(formulas.map(\.pixelSize))")
            #expect(abs(formulas[1].pixelSize - formulas[2].pixelSize) < 0.5)
        }
    }

    @Test("A virtualized note draws the formulas of the rows it shows") @MainActor
    func virtualizedNoteDrawsFormulas() throws {
        let markdown = (0..<40).map { "## Section \($0)\n\nRow \($0) with $x_{\($0)}$." }.joined(separator: "\n\n")
        let fixture = try Fixture(suffix: "virtualized", markdown: "", configure: { $0.debugForceVirtualizedRows = true })
        fixture.render(markdown)
        MainContext.pump(for: .milliseconds(200))
        #expect(fixture.preview.rootScroll.child?.tryCast(ListView.self) != nil, "expected the virtualized list")
        pumpUntil(timeout: .milliseconds(800)) {
            fixture.labels().contains { !PreviewMath.debugFormulas(on: $0).isEmpty }
        }
        // Every shown row draws its own formula, not a recycled row's.
        var checked = 0
        for label in fixture.labels() {
            // A label may hold a heading and its row ("Section 3\n\nRow 3 with ￼.").
            let numbers = label.text.components(separatedBy: "Row ").dropFirst().compactMap { $0.split(separator: " ").first }
            guard !numbers.isEmpty else { continue }
            #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == numbers.map { "x_{\($0)}" }, "\(label.text)")
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test("Editing a display formula rebuilds its row with the new formula") @MainActor
    func editingADisplayFormulaRebuildsItsRow() throws {
        let fixture = try Fixture(suffix: "edit-display", markdown: "Intro.\n\n$$\na\n$$")
        #expect(fixture.labels(withCSSClass: "preview-math-label").flatMap { PreviewMath.debugFormulas(on: $0).map(\.tex) } == ["a"])
        fixture.render("Intro.\n\n$$\nb\n$$")
        #expect(fixture.labels(withCSSClass: "preview-math-label").flatMap { PreviewMath.debugFormulas(on: $0).map(\.tex) } == ["b"])
    }

    @Test("A new row with a formula after a code block draws it") @MainActor
    func aNewRowWithAFormulaAfterACodeBlockDrawsIt() throws {
        let fixture = try Fixture(suffix: "append-row", markdown: "Intro.\n\n```\ncode\n```")
        fixture.render("Intro.\n\n```\ncode\n```\n\nNew $y$ row.")
        let label = try #require(fixture.labels().first { $0.text.hasPrefix("New ") })
        #expect(label.text == "New \u{FFFC} row.")
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["y"])
    }

    @Test("Display math inside a sentence is set inline and copies as written") @MainActor
    func displayMathInsideASentenceIsSetInline() throws {
        let fixture = try Fixture(suffix: "display-inline", markdown: "a $$\\frac{1}{2}$$ c")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let formula = try #require(PreviewMath.debugFormulas(on: label).first)
        #expect(!formula.isDisplay)
        gtk_label_select_region(label.opaquePointer, 0, -1)
        gtk_widget_activate_action_variant(label.widgetPointer, "clipboard.copy", nil)
        #expect(readClipboardText(gtk_widget_get_clipboard(label.widgetPointer)) == "a $$\\frac{1}{2}$$ c")
    }

    @Test("A search hit inside a display formula highlights it") @MainActor
    func aSearchHitInsideADisplayFormulaHighlightsIt() throws {
        let fixture = try Fixture(suffix: "search-display", markdown: "Intro.\n\n$$\n\\alpha + \\beta\n$$")
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "beta", options: .init())
        #expect(matches.count == 1)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["\u{FFFC}"])
    }

    @Test("A search hit inside a display formula that cannot draw lands on its words") @MainActor
    func aSearchHitInsideADisplayFormulaThatCannotDrawLandsOnItsWords() throws {
        let fixture = try Fixture(suffix: "search-display-fallback", markdown: "Intro.\n\n$$\n\\undefinedmacro{beta}\n$$")
        let preview = fixture.preview
        let matches = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "beta", options: .init())
        #expect(matches.count == 1)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["beta"])
    }

    @Test("Changing a heading's level resizes its formula") @MainActor
    func changingAHeadingsLevelResizesItsFormula() throws {
        let fixture = try Fixture(suffix: "heading-level", markdown: "# Title $x$\n\n```\ncode\n```")
        let label = try #require(fixture.labels().first { $0.text.hasPrefix("Title") })
        let large = try #require(PreviewMath.debugFormulas(on: label).first).pixelSize
        fixture.render("### Title $x$\n\n```\ncode\n```")
        let resized = try #require(fixture.labels().first { $0.text.hasPrefix("Title") })
        pumpUntil(timeout: .milliseconds(800)) {
            (PreviewMath.debugFormulas(on: resized).first?.pixelSize ?? large) < large * 0.9
        }
        let small = try #require(PreviewMath.debugFormulas(on: resized).first).pixelSize
        #expect(small < large * 0.9, "\(large) → \(small)")
    }

    @Test("A note shown as one label draws its formulas, sized per segment") @MainActor
    func singleLabelNoteDrawsFormulas() throws {
        let fixture = try Fixture(suffix: "custom-text", markdown: "", configure: { $0.debugForceCustomTextLayout = true })
        fixture.render("# Title $a$\n\nBody $b$ text.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        let formulas = PreviewMath.debugFormulas(on: label)
        #expect(formulas.map(\.tex) == ["a", "b"])
        if formulas.count == 2 {
            #expect(formulas[0].pixelSize > formulas[1].pixelSize * 1.3)
        }
        fixture.render("# Title $a$\n\nBody $b$ and $c$ text.")
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["a", "b", "c"])
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let app: Application
        let preview: MarkdownPreview
        let window: ApplicationWindow

        init(
            suffix: String,
            markdown: String,
            size: (width: Int, height: Int) = (700, 600),
            configure: (MarkdownPreview) -> Void = { _ in }
        ) throws {
            app = Application(id: "me.spaceinbox.swiftynotes.tests.math.\(suffix)")
            try app.register()
            preview = MarkdownPreview(remoteImageLoader: { _, _ in })
            configure(preview)
            window = ApplicationWindow(application: app)
            window.setDefaultSize(width: size.width, height: size.height)
            window.setContent(preview.rootScroll)
            preview.attach(to: window)
            window.present()
            if !markdown.isEmpty {
                render(markdown)
            }
        }

        func render(_ markdown: String) {
            preview.render(blocks: MarkdownRenderer().blocks(for: markdown, darkAppearance: false))
            MainContext.pump(for: .milliseconds(60))
        }

        func labels(in widget: Widget? = nil) -> [Label] {
            let root = widget ?? preview.rootScroll
            var result: [Label] = []
            if let label = root.tryCast(Label.self) {
                result.append(label)
            }
            for child in root.children() {
                result += labels(in: child)
            }
            return result
        }

        func labels(withCSSClass cssClass: String) -> [Label] {
            labels().filter { $0.hasCSSClass(cssClass) }
        }

        func firstLabel(withCSSClass cssClass: String) -> Label? {
            labels().first { $0.hasCSSClass(cssClass) }
        }

        deinit {
            MainActor.assumeIsolated {
                window.close()
            }
        }
    }

    /// GtkSettings' `gtk-font-name`, the desktop's interface font. Setting
    /// it marks it set by the app for the rest of the process, so the real
    /// desktop's font changes no longer reach these tests.
    @MainActor
    private var desktopFontName: String? {
        get {
            let settings = UnsafeMutableRawPointer(gtk_settings_get_default()!).assumingMemoryBound(to: GObject.self)
            var value = GValue()
            g_value_init(&value, g_type_from_name("gchararray"))
            defer { g_value_unset(&value) }
            g_object_get_property(settings, "gtk-font-name", &value)
            return g_value_get_string(&value).map { String(cString: $0) }
        }
        nonmutating set {
            let settings = UnsafeMutableRawPointer(gtk_settings_get_default()!).assumingMemoryBound(to: GObject.self)
            var value = GValue()
            g_value_init(&value, g_type_from_name("gchararray"))
            defer { g_value_unset(&value) }
            g_value_set_string(&value, newValue)
            g_object_set_property(settings, "gtk-font-name", &value)
        }
    }

    @MainActor
    private func pumpUntil(timeout: Duration, _ condition: () -> Bool) {
        let step = Duration.milliseconds(20)
        var elapsed: Duration = .zero
        while elapsed < timeout, !condition() {
            MainContext.pump(for: step)
            elapsed += step
        }
    }

    /// Counts strongly red and blue pixels in `label` as GTK renders it.
    @MainActor
    private func paintedColours(of label: Label) -> (red: Int, blue: Int) {
        var counts = (red: 0, blue: 0)
        forEachRenderedPixel(of: label) { r, g, b, a in
            guard a > 200, g < 60 else { return }
            if r > 200, b < 60 { counts.red += 1 }
            if b > 200, r < 60 { counts.blue += 1 }
        }
        return counts
    }

    /// Renders `widget` the way GTK does (its snapshot through GSK's cairo
    /// renderer) and visits every pixel, straight alpha not applied.
    @MainActor
    private func forEachRenderedPixel(of widget: Widget, _ visit: (Int, Int, Int, Int) -> Void) {
        let width = gtk_widget_get_width(widget.widgetPointer)
        let height = gtk_widget_get_height(widget.widgetPointer)
        guard width > 0, height > 0, let paintable = gtk_widget_paintable_new(widget.widgetPointer) else { return }
        defer { g_object_unref(UnsafeMutableRawPointer(paintable)) }
        let snapshot = gtk_snapshot_new()
        gdk_paintable_snapshot(paintable, snapshot, Double(width), Double(height))
        guard let node = gtk_snapshot_free_to_node(snapshot) else { return }
        defer { gsk_render_node_unref(node) }
        guard let renderer = gsk_cairo_renderer_new() else { return }
        defer { g_object_unref(UnsafeMutableRawPointer(renderer)) }
        guard gsk_renderer_realize_for_display(renderer, gdk_display_get_default(), nil) != 0 else { return }
        defer { gsk_renderer_unrealize(renderer) }
        guard let texture = gsk_renderer_render_texture(renderer, node, nil) else { return }
        defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
        let textureWidth = Int(gdk_texture_get_width(texture))
        let textureHeight = Int(gdk_texture_get_height(texture))
        let stride = textureWidth * 4
        var bytes = [UInt8](repeating: 0, count: stride * textureHeight)
        // GDK_MEMORY_DEFAULT: B, G, R, A in memory on little-endian machines.
        gdk_texture_download(texture, &bytes, gsize(stride))
        for y in 0..<textureHeight {
            for x in 0..<textureWidth {
                let i = y * stride + x * 4
                visit(Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]), Int(bytes[i + 3]))
            }
        }
    }

    /// The area of the monitor `widget`'s window is on (what a renderer
    /// rasterises of a node at most).
    @MainActor
    private func monitorArea(of widget: Widget) -> Double {
        guard let native = gtk_widget_get_native(widget.widgetPointer),
              let surface = gtk_native_get_surface(native),
              let monitor = gdk_display_get_monitor_at_surface(gdk_surface_get_display(surface), surface)
        else { return 3840 * 2160 }
        var geometry = GdkRectangle()
        gdk_monitor_get_geometry(monitor, &geometry)
        return Double(geometry.width) * Double(geometry.height)
    }

    /// What one formula's node costs in pixels, measured independently of
    /// the code's model: the label's own layout (ink included — GTK sizes
    /// the node by it), clipped to the preview's visible area.
    @MainActor
    private func nodeArea(of label: Label) -> Double {
        guard let layout = gtk_label_get_layout(label.opaquePointer) else { return 0 }
        var ink = PangoRectangle()
        var logical = PangoRectangle()
        pango_layout_get_pixel_extents(layout, &ink, &logical)
        let width = max(Double(label.width), Double(max(ink.x + ink.width, logical.x + logical.width) - min(ink.x, logical.x)))
        let height = Double(max(ink.y + ink.height, logical.y + logical.height) - min(ink.y, logical.y))
        var scroller: Widget = label
        while let parent = scroller.parent, scroller.tryCast(ScrolledWindow.self) == nil || scroller.widgetPointer == label.widgetPointer {
            scroller = parent
        }
        let visible = Double(scroller.width) * Double(scroller.height)
        return min(width * height, visible)
    }

    @MainActor
    private func attributeCount(on label: Label) -> Int {
        guard let list = gtk_label_get_attributes(label.opaquePointer),
              let attributes = pango_attr_list_get_attributes(list)
        else {
            return 0
        }
        defer { g_slist_free_full(attributes) { pango_attribute_destroy($0?.assumingMemoryBound(to: PangoAttribute.self)) } }
        return Int(g_slist_length(attributes))
    }

    @MainActor
    private func readClipboardText(_ clipboard: OpaquePointer?) -> String? {
        final class Result: @unchecked Sendable {
            var text: String?
            var done = false
        }
        let result = Result()
        let box = Unmanaged.passRetained(result)
        gdk_clipboard_read_text_async(clipboard, nil, { source, asyncResult, userData in
            guard let userData else { return }
            let result = Unmanaged<Result>.fromOpaque(userData).takeRetainedValue()
            if let text = gdk_clipboard_read_text_finish(OpaquePointer(source), asyncResult, nil) {
                result.text = String(cString: text)
                g_free(text)
            }
            result.done = true
        }, box.toOpaque())
        pumpUntil(timeout: .seconds(2)) { result.done }
        return result.text
    }
}
#endif
