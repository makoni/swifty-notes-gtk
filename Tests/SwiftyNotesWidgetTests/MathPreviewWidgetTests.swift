#if !os(macOS)
import Adwaita
import CAdwaita
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
        _ = label.addTickCallback {
            smallestSeen = min(smallestSeen, PreviewMath.debugFormulas(on: label).first?.pixelSize ?? 0)
            return fixture.preview.debugMathFontRefreshPending
        }
        pumpUntil(timeout: .seconds(2)) { !fixture.preview.debugMathFontRefreshPending }
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
        defer { preview.applyTypography(zoomPercent: 100, lineSpacingPercent: 100) }
        // Re-applies the last highlights; reaching the freed label crashed.
        preview.applyTypography(zoomPercent: 150, lineSpacingPercent: 100)
        MainContext.pump(for: .milliseconds(100))
        let heading = try #require(fixture.labels().first { $0.text.hasPrefix("A needle") })
        #expect(PreviewMath.debugFormulas(on: heading).map(\.tex) == ["x"])
    }

    @Test("Editing a paragraph re-installs its formulas") @MainActor
    func editingParagraphReinstallsFormulas() throws {
        let fixture = try Fixture(suffix: "edit", markdown: "Text $a$ here.\n\nSecond paragraph.")
        fixture.render("Text $a$ and $b$ here.\n\nSecond paragraph.")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        #expect(PreviewMath.debugFormulas(on: label).map(\.tex) == ["a", "b"])
        #expect(PreviewMath.debugShapeAttributeCount(on: label) == 2)
        #expect(gtkAccessibleLabelMismatch(of: label, expected: "Text $a$ and $b$ here.\n\nSecond paragraph.") == nil)
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

    @Test("Formulas are painted, in the label's colour, and follow a colour change") @MainActor
    func formulasArePaintedInTheLabelsColour() throws {
        let fixture = try Fixture(suffix: "paint", markdown: "Square $\\blacksquare\\blacksquare$ here.")
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
        let fixture = try Fixture(suffix: "link-colour", markdown: "[$\\blacksquare\\blacksquare\\blacksquare$](https://example.org)")
        let label = try #require(fixture.firstLabel(withCSSClass: "preview-paragraph-label"))
        // Ink far from the label's own (text) colour is the link colour.
        var labelColor = GdkRGBA()
        gtk_widget_get_color(label.widgetPointer, &labelColor)
        let text = (Int(labelColor.red * 255), Int(labelColor.green * 255), Int(labelColor.blue * 255))
        var linkColoured = 0
        pumpUntil(timeout: .milliseconds(500)) {
            linkColoured = 0
            forEachRenderedPixel(of: label) { r, g, b, a in
                if a > 200, abs(r - text.0) + abs(g - text.1) + abs(b - text.2) > 120 { linkColoured += 1 }
            }
            return linkColoured > 150
        }
        #expect(linkColoured > 150, "\(linkColoured) pixels not in the text colour")
    }

    @Test("Formulas in a coalesced heading are sized like the heading") @MainActor
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
        // The code block keeps the heading a row of its own, sized by CSS.
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

        init(suffix: String, markdown: String, configure: (MarkdownPreview) -> Void = { _ in }) throws {
            app = Application(id: "me.spaceinbox.swiftynotes.tests.math.\(suffix)")
            try app.register()
            preview = MarkdownPreview(remoteImageLoader: { _, _ in })
            configure(preview)
            window = ApplicationWindow(application: app)
            window.setDefaultSize(width: 700, height: 600)
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

    @MainActor
    private func pumpUntil(timeout: Duration, _ condition: () -> Bool) {
        let step = Duration.milliseconds(20)
        var elapsed: Duration = .zero
        while elapsed < timeout, !condition() {
            MainContext.pump(for: step)
            elapsed += step
        }
    }

    /// Draws the label's layout (with its shape renderer, as GTK does) onto
    /// a black-free transparent surface and counts strongly red and blue
    /// pixels; the plain text draws in the cairo source, set to green here.
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
