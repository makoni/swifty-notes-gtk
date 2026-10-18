import Adwaita
import CAdwaita
import Foundation

/// Draws TeX formulas inside the preview's labels.
///
/// The renderer leaves one U+FFFC in a label's markup for every inline
/// formula and lists the formulas in `RenderedText.mathSpans`, in the same
/// order. ``install(on:spans:)`` turns each U+FFFC into a Pango shape
/// attribute the size of the formula and draws the formula there through a
/// cairo shape renderer, so formulas sit on the text baseline, wrap like
/// words and stay part of one selectable label.
///
/// Per label it also:
/// - sizes formulas from the label's font (and any `size=` span around the
///   formula, as in the single-label layout's headings),
/// - draws them in the label's current colour, so theme switches need no
///   relayout,
/// - copies `$tex$` instead of U+FFFC,
/// - exposes the TeX source as the accessible label,
/// - maps search-hit offsets from the plain text (which spells formulas as
///   `$tex$`) to the label text (one character per formula).
///
/// A formula the engine cannot draw is shown as its TeX source in monospace
/// instead.
@MainActor
enum PreviewMath {
    /// Formulas are drawn this much larger than the surrounding text, like
    /// KaTeX (1.21 em) does, because math glyphs run small next to UI fonts.
    static let formulaScale = 1.21

    private static let stateKey = "swifty-notes-preview-math"
    private static let copyHandlerKey = "swifty-notes-preview-math-copy"
    private static let shapeRendererKey = "swifty-notes-preview-math-drawer"

    /// Installs (or refreshes) the formulas of `label`. `spans` are the
    /// label's formulas in markup order. A label whose markup holds a
    /// different number of markers (which should not happen) loses any
    /// formulas it drew rather than keep ones that no longer match; returns
    /// false then.
    @discardableResult
    static func install(on label: Label, spans: [MathSpan]) -> Bool {
        let existing = state(of: label)
        let markup = label.markup
        let markerCount = markup.unicodeScalars.reduce(0) { $0 + ($1 == MathSpanExtractor.formulaMarker ? 1 : 0) }
        guard markerCount == spans.count, !spans.isEmpty else {
            if existing != nil {
                label.attributes = nil
                // The accessible label spelled the old formulas out; go back
                // to the label's own text.
                label.setAccessibleLabel(label.text)
                detachState(from: label)
            }
            return markerCount == spans.count
        }

        let state = existing ?? attachState(to: label)
        if state.originalMarkup != markup {
            state.originalMarkup = markup
            state.markerSizes = nil
        }
        // A new render tries again formulas refused only at the memory limit
        // (they may fit now); every other decision stands, so a note full of
        // broken formulas is not parsed again on each keystroke.
        state.decisions = state.decisions.filter { !$0.value.isRetryable }
        state.spans = spans
        state.baseFontPixels = fontPixels(of: label)
        state.measuredFontPixels = state.baseFontPixels
        layOut(label, state: state)
        return true
    }

    /// Shows `text` — a note's title, a heading — in `label`, drawing its
    /// formulas as the preview does (and dropping any it drew before).
    static func show(_ text: String, in label: Label) {
        let math = MathInlineText.markup(for: text)
        label.markup = math.markup
        install(on: label, spans: math.spans)
    }

    /// Lays out formulas that a render pass postponed when it ran out of
    /// parse budget (they show their source meanwhile). Returns true when
    /// some are still postponed after this pass.
    static func layOutPostponedFormulas(under root: Widget) -> Bool {
        var stillPostponed = false
        forEachMathLabel(under: root) { label, state in
            guard state.hasPostponedFormulas else { return }
            // Relaying a long label out costs more than a pass may spend, so
            // it is shown again only once all its formulas are ready.
            layOut(label, state: state, applyingWhilePostponed: false)
            stillPostponed = stillPostponed || state.hasPostponedFormulas
        }
        if !stillPostponed {
            mayHavePostponedFormulas = false
        }
        return stillPostponed
    }

    /// Set whenever a formula is postponed, cleared by a pass that leaves
    /// none postponed, so that most row binds skip walking the tree.
    private static var mayHavePostponedFormulas = false

    /// Whether any label under `root` shows formulas postponed by the parse
    /// budget.
    static func hasPostponedFormulas(under root: Widget) -> Bool {
        guard mayHavePostponedFormulas else { return false }
        var found = false
        forEachMathLabel(under: root) { _, state in
            found = found || state.hasPostponedFormulas
        }
        return found
    }

    /// Re-lays out every formula label under `root` at `factor` times its
    /// font size — the preview's zoom step, applied straight away rather than
    /// after GTK restyles the labels on its next frame.
    static func rescale(under root: Widget, by factor: Double) {
        guard factor.isFinite, factor > 0, abs(factor - 1) > 0.001 else { return }
        forEachMathLabel(under: root) { label, state in
            state.baseFontPixels *= factor
            layOut(label, state: state)
        }
    }

    /// Re-lays out every formula label under `root` whose own font size
    /// changed (zoom once GTK restyles, the desktop's font settings) to a
    /// size its formulas were not laid out for. Returns true when a label
    /// was refreshed.
    ///
    /// Only a change of the label's font counts: until GTK restyles after a
    /// zoom step the font still has the old size, and going by that would
    /// undo ``rescale(under:by:)`` for a frame.
    @discardableResult
    static func refreshFontSizes(under root: Widget) -> Bool {
        var refreshed = false
        forEachMathLabel(under: root) { label, state in
            var needsLayout = false
            // The formula budget assumed another width, visible height or
            // scale (allocated since, resized, moved to another screen):
            // only labels the budget could bind (or did) care.
            if !state.isDisplayBlock, !state.entries.isEmpty || state.isBudgetLimited {
                let frame = budgetFrame(of: label)
                let assumed = state.budgetFrame
                if state.isBudgetSensitive || state.isBudgetLimited {
                    // The estimate went by the width; a few percent off
                    // (margins, a scrollbar, a resize) is worth a re-estimate.
                    needsLayout = abs(frame.width - assumed.width) > max(4, frame.width * 0.02)
                        || frame.clipArea != assumed.clipArea || frame.scale != assumed.scale
                } else if frame.clipArea != assumed.clipArea || frame.scale != assumed.scale {
                    // Another monitor: drawing everything may no longer fit.
                    let ceiling = frame.clipArea * frame.scale * frame.scale * 4
                    needsLayout = Double(state.entries.count) * ceiling > drawnFormulaBudget
                }
            }
            let pixels = fontPixels(of: label)
            if abs(pixels - state.measuredFontPixels) > 0.01 {
                state.measuredFontPixels = pixels
                // A new font (after a zoom step's immediate rescale the base
                // is already right); a label the budget could bind estimated
                // its size with the old font, so estimates again.
                if abs(pixels - state.baseFontPixels) > 0.01 {
                    state.baseFontPixels = pixels
                    needsLayout = true
                }
                needsLayout = needsLayout || state.isBudgetSensitive || state.isBudgetLimited
            }
            guard needsLayout else { return }
            layOut(label, state: state)
            refreshed = true
        }
        return refreshed
    }

    /// Adds the formula shapes of `labelPointer` (if it draws any) to
    /// `attributes`, so overlays that replace a label's attribute list —
    /// search highlighting — keep the formulas.
    static func appendShapes(of labelPointer: OpaquePointer, to attributes: TextAttributes) {
        guard let state = state(ofPointer: labelPointer) else { return }
        state.appendShapes(to: attributes)
    }

    /// Whether `labelPointer` draws at least one formula.
    static func drawsFormulas(_ labelPointer: OpaquePointer) -> Bool {
        !(state(ofPointer: labelPointer)?.entries.isEmpty ?? true)
    }

    /// Converts a character (grapheme) offset in the plain text a label was
    /// built from — search hits count in these, with formulas spelled
    /// `$tex$` — into the label's own text, where a drawn formula is one
    /// character. Labels without formulas map one to one.
    /// An offset inside a formula's source snaps to the formula: down for
    /// the start of a range, up for its end, so a hit inside the TeX
    /// highlights the whole formula.
    static func labelOffset(forPlainOffset offset: Int, in labelPointer: OpaquePointer, isRangeEnd: Bool) -> Int {
        guard let state = state(ofPointer: labelPointer) else { return offset }
        return state.labelOffset(forPlainOffset: offset, isRangeEnd: isRangeEnd)
    }

    /// Spells the formulas of `label` out again in its accessible label,
    /// which GTK resets to the label's text whenever the markup changes.
    static func restoreAccessibleLabel(of label: Label) {
        guard let state = state(of: label) else { return }
        label.setAccessibleLabel(state.accessibleText(labelText: label.text))
    }

    /// The label's text with each drawn formula spelled as its TeX source,
    /// limited to `selection` when given — what copying that selection puts
    /// on the clipboard. `selection` counts code points, as GTK's selection
    /// bounds do.
    static func sourceText(of label: Label, selection: Range<Int>? = nil) -> String {
        guard let state = state(of: label) else { return label.text }
        return state.sourceText(labelText: label.text, scalarRange: selection)
    }

    /// The formulas `label` draws, in order (tests).
    static func debugFormulas(on label: Label) -> [MathFormula] {
        state(of: label)?.entries.map(\.shape.formula) ?? []
    }

    /// How many formula shape attributes the label's attribute list holds
    /// right now (tests: overlays must keep them).
    static func debugShapeAttributeCount(on label: Label) -> Int {
        guard let list = gtk_label_get_attributes(label.opaquePointer),
              let attributes = pango_attr_list_get_attributes(list)
        else {
            return 0
        }
        defer { g_slist_free_full(attributes) { pango_attribute_destroy($0?.assumingMemoryBound(to: PangoAttribute.self)) } }
        var count = 0
        var node: UnsafeMutablePointer<GSList>? = attributes
        while let current = node {
            if let attribute = current.pointee.data?.assumingMemoryBound(to: PangoAttribute.self),
               attribute.pointee.klass.pointee.type == PANGO_ATTR_SHAPE
            {
                count += 1
            }
            node = current.pointee.next
        }
        return count
    }

    // MARK: - Layout

    /// Formulas wider or taller than this inline, or larger than
    /// ``maxFormulaArea``, show their source: GTK renders label content into
    /// textures, and a formula thousands of pixels across (`\hspace{600em}`,
    /// `\rule{0pt}{200em}`) costs tens of megabytes there.
    static let maxInlineFormulaWidth = 2048.0
    static let maxFormulaArea = 2048.0 * 2048.0

    /// GTK draws each formula (a Pango shape) into a cairo node as large as
    /// the whole label — `gsk_pango_renderer_draw_shape` in GTK's
    /// gskpango.c gives every shape the layout's extents — and the GL and
    /// Vulkan renderers rasterise each one, clipped to what is on screen. So
    /// a formula costs about the visible part of its label, in (video)
    /// memory. A label draws as many as fit this many bytes; the rest show
    /// their source. Text with formulas is kept in labels of its own for the
    /// same reason (``mayShareLabel(_:)``). One drawing node per label
    /// would remove the need; GTK offers labels no hook for it.
    static let drawnFormulaBudget = 128.0 * 1024 * 1024

    /// Whether `text` may be joined with other text into one label: not
    /// when it has formulas (see ``drawnFormulaBudget``).
    static func mayShareLabel(_ text: RenderedText) -> Bool {
        text.mathSpans.isEmpty
    }

    /// The width, clip area and scale a label's formula budget goes by: its
    /// own width (before allocation, its scrolled window's), and the larger
    /// of its monitor's area and its window's — what a GPU renderer
    /// rasterises of a node at most; a window growing on its monitor stays
    /// within it, and a resize past it is re-checked.
    private static func budgetFrame(of label: Label) -> (width: Double, clipArea: Double, scale: Double) {
        let scroller = gtk_widget_get_ancestor(label.widgetPointer, gtk_scrolled_window_get_type())
        let ownWidth = Double(gtk_widget_get_width(label.widgetPointer))
        let scrollerWidth = scroller.map { Double(gtk_widget_get_width($0)) } ?? 0
        var clipArea = 3840.0 * 2160
        if let native = gtk_widget_get_native(label.widgetPointer),
           let surface = gtk_native_get_surface(native),
           let monitor = gdk_display_get_monitor_at_surface(gdk_surface_get_display(surface), surface)
        {
            var geometry = GdkRectangle()
            gdk_monitor_get_geometry(monitor, &geometry)
            if geometry.width > 0, geometry.height > 0 {
                clipArea = Double(geometry.width) * Double(geometry.height)
            }
        }
        // A window can be larger than the monitor GDK names for it (spread
        // over two): the renderer draws the whole window.
        if let root = gtk_widget_get_root(label.widgetPointer) {
            let window = UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWidget.self)
            clipArea = max(clipArea, Double(gtk_widget_get_width(window)) * Double(gtk_widget_get_height(window)))
        }
        return (ownWidth > 0 ? ownWidth : (scrollerWidth > 0 ? scrollerWidth : 1280), clipArea, surfaceScale(of: label))
    }

    /// How many of `formulas` (in order) `label` may draw within
    /// ``drawnFormulaBudget``. A formula costs the label's area, but never
    /// more than the monitor's (the most a renderer rasterises); a label
    /// that fits even at that draws them all without further ado — nearly
    /// every label. Otherwise the label is laid out apart, as it will look
    /// (the formulas drawn, the rest as source), at the width it gets:
    /// never from its live layout, which before allocation is laid out at
    /// width zero and otherwise shows the last decision. Text area hardly
    /// changes when a resize rewraps it, so the decision holds while the
    /// window grows. Display blocks hold one formula and are exempt.
    private static func drawnFormulaAllowance(
        for label: Label,
        state: MathLabelState,
        formulas: [MathFormula?],
        frame: (width: Double, clipArea: Double, scale: Double)
    ) -> Int {
        let count = formulas.lazy.compactMap(\.self).count
        let bytesPerPixel = frame.scale * frame.scale * 4
        let ceiling = frame.clipArea * bytesPerPixel
        guard !state.isDisplayBlock, count > 0, Double(count) * ceiling > drawnFormulaBudget else { return .max }

        // The bytes one formula costs with the first `drawn` of them drawn,
        // or nil when the text inks several times its own box (a stack of
        // combining marks): GTK sizes the nodes by the ink.
        func costPerFormula(drawing drawn: Int) -> Double? {
            var kept = 0
            let shown = formulas.map { formula -> MathFormula? in
                guard let formula else { return nil }
                kept += 1
                return kept <= drawn ? formula : nil
            }
            guard let extents = estimatedExtents(of: label, state: state, formulas: shown, width: frame.width) else {
                return Double.infinity
            }
            let inkArea = Double(extents.ink.width) * Double(extents.ink.height)
            let logicalArea = Double(max(1, extents.logical.width)) * Double(max(1, extents.logical.height))
            if inkArea > 250_000, inkArea > 4 * logicalArea { return nil }
            let left = min(extents.ink.x, extents.logical.x)
            let right = max(extents.ink.x + extents.ink.width, extents.logical.x + extents.logical.width)
            let top = min(extents.ink.y, extents.logical.y)
            let bottom = max(extents.ink.y + extents.ink.height, extents.logical.y + extents.logical.height)
            let area = max(frame.width, Double(right - left)) * Double(bottom - top)
            return min(area, frame.clipArea) * bytesPerPixel
        }

        // Always within budget, whatever the layout.
        let surelyFits = max(1, min(count, Int(drawnFormulaBudget / ceiling)))
        guard let costAll = costPerFormula(drawing: count) else { return 0 }
        guard costAll.isFinite, costAll > 0 else { return costAll > 0 ? surelyFits : count }
        var allowance = min(count, Int(drawnFormulaBudget / costAll))
        // Fewer drawn, the rest show their source and the label grows:
        // check again until it fits (the allowance only shrinks), a few
        // times at most, then fall back to what surely fits.
        var checks = 0
        while allowance < count, allowance > surelyFits {
            guard let cost = costPerFormula(drawing: allowance) else { return 0 }
            guard cost.isFinite, cost > 0 else { allowance = surelyFits; break }
            if Double(allowance) * cost <= drawnFormulaBudget { break }
            checks += 1
            allowance = checks < 4 ? Int(drawnFormulaBudget / cost) : surelyFits
        }
        return max(allowance, surelyFits)
    }

    /// The ink and logical extents `label` would have with `formulas`
    /// drawn (nil: shown as source), laid out apart at `width`.
    private static func estimatedExtents(
        of label: Label, state: MathLabelState, formulas: [MathFormula?], width: Double
    ) -> (ink: PangoRectangle, logical: PangoRectangle)? {
        guard let context = gtk_widget_get_pango_context(label.widgetPointer),
              let layout = pango_layout_new(context)
        else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        // Pango markup has no links; GtkLabel handles `<a>` itself.
        let markup = markupReplacingFailedFormulas(
            in: state.originalMarkup, spans: state.spans, formulas: formulas, isDisplayBlock: false
        )
        .replacingOccurrences(of: "<a\\b[^>]*>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "</a>", with: "")
        pango_layout_set_markup(layout, markup, -1)
        pango_layout_set_wrap(layout, gtk_label_get_wrap_mode(label.opaquePointer))
        pango_layout_set_width(layout, Int32(min(width, 100_000) * Double(PANGO_SCALE)))

        // The drawn formulas' room, as their shapes will take it, and the
        // line-height and letter-spacing GtkLabel sets on its own layout
        // from CSS — not part of the Pango context.
        let attributes = pango_layout_get_attributes(layout).map { pango_attr_list_copy($0) } ?? pango_attr_list_new()
        defer { pango_attr_list_unref(attributes) }
        if let live = gtk_label_get_layout(label.opaquePointer).flatMap({ pango_layout_get_attributes($0) }),
           let list = pango_attr_list_get_attributes(live)
        {
            var node: UnsafeMutablePointer<GSList>? = list
            while let current = node {
                if let attribute = current.pointee.data?.assumingMemoryBound(to: PangoAttribute.self),
                   [PANGO_ATTR_LINE_HEIGHT, PANGO_ATTR_ABSOLUTE_LINE_HEIGHT, PANGO_ATTR_LETTER_SPACING]
                       .contains(attribute.pointee.klass.pointee.type)
                {
                    pango_attr_list_insert(attributes, pango_attribute_copy(attribute))
                }
                node = current.pointee.next
            }
            g_slist_free_full(list) { pango_attribute_destroy($0?.assumingMemoryBound(to: PangoAttribute.self)) }
        }
        let text = String(cString: pango_layout_get_text(layout))
        var drawn = formulas.lazy.compactMap(\.self).makeIterator()
        var byteIndex = 0
        for scalar in text.unicodeScalars {
            if scalar == MathSpanExtractor.formulaMarker, let formula = drawn.next() {
                let padX = max(1, (formula.pixelSize * 0.04).rounded(.up))
                let padY = max(2, (formula.pixelSize * 0.1).rounded(.up))
                var rect = PangoRectangle(
                    x: 0,
                    y: Int32(-((formula.ascent + padY) * Double(PANGO_SCALE)).rounded(.up)),
                    width: Int32(((formula.width + 2 * padX) * Double(PANGO_SCALE)).rounded(.up)),
                    height: Int32(((formula.height + 2 * padY) * Double(PANGO_SCALE)).rounded(.up))
                )
                if let shape = pango_attr_shape_new(&rect, &rect) {
                    shape.pointee.start_index = guint(byteIndex)
                    shape.pointee.end_index = guint(byteIndex + scalar.utf8.count)
                    pango_attr_list_insert(attributes, shape)
                }
            }
            byteIndex += scalar.utf8.count
        }
        pango_layout_set_attributes(layout, attributes)
        var ink = PangoRectangle()
        var logical = PangoRectangle()
        pango_layout_get_pixel_extents(layout, &ink, &logical)
        return (ink, logical)
    }

    /// The device pixels per pixel of the window `label` is in (1 before it
    /// is in one).
    private static func surfaceScale(of label: Label) -> Double {
        guard let native = gtk_widget_get_native(label.widgetPointer),
              let surface = gtk_native_get_surface(native)
        else {
            return 1
        }
        return max(1, gdk_surface_get_scale(surface))
    }

    static func isDrawable(_ formula: MathFormula, inline: Bool) -> Bool {
        formula.width * formula.height <= maxFormulaArea
            && (!inline || (formula.width <= maxInlineFormulaWidth && formula.height <= maxInlineFormulaWidth))
    }

    private static func layOut(_ label: Label, state: MathLabelState, applyingWhilePostponed: Bool = true) {
        // Parse every formula at its own size; one that does not parse falls
        // back to its source, which changes the markup.
        let sizes: [Double]
        if let cached = state.markerSizes, cached.basePixels == state.baseFontPixels {
            sizes = cached.sizes
        } else {
            sizes = markerFontPixels(in: state.originalMarkup, basePixels: state.baseFontPixels)
            state.markerSizes = (state.baseFontPixels, sizes)
        }
        var formulas: [MathFormula?] = []
        var decisions: [MathLabelState.DecisionKey: MathLabelState.Decision] = [:]
        state.hasPostponedFormulas = false
        for (index, span) in state.spans.enumerated() {
            let pixels = (index < sizes.count ? sizes[index] : state.baseFontPixels) * formulaScale
            let isDisplay = span.isDisplay && state.isDisplayBlock
            let key = MathLabelState.DecisionKey(
                tex: span.tex, isDisplay: isDisplay, quarterPixels: Int((pixels * 4).rounded())
            )
            // Keep what the label already decided — a drawn formula, or its
            // source: the cache may have dropped either, and looking them up
            // again would never end on a label with more of them than the
            // cache holds.
            if let decided = decisions[key] ?? state.decisions[key] {
                formulas.append(decided.formula)
                decisions[key] = decided
                continue
            }
            let formula = MathRenderer.formula(tex: span.tex, isDisplay: isDisplay, pixelSize: pixels)
                .flatMap { isDrawable($0, inline: !state.isDisplayBlock) ? $0 : nil }
            formulas.append(formula)
            if MathRenderer.lastLookupWasPostponed {
                state.hasPostponedFormulas = true
                mayHavePostponedFormulas = true
            } else {
                decisions[key] = .init(formula: formula, isRetryable: MathRenderer.lastLookupWasTransient)
            }
        }
        // Only the formulas the label holds now.
        state.decisions = decisions
        // Past the label's budget the rest show their source.
        let frame = budgetFrame(of: label)
        let allowance = drawnFormulaAllowance(for: label, state: state, formulas: formulas, frame: frame)
        state.budgetFrame = frame
        state.isBudgetSensitive = allowance != .max
        state.isBudgetLimited = formulas.lazy.compactMap(\.self).count > allowance
        var drawn = 0
        formulas = formulas.map { formula in
            guard let formula else { return nil }
            drawn += 1
            return drawn <= allowance ? formula : nil
        }
        if state.hasPostponedFormulas, !applyingWhilePostponed {
            return
        }
        let markup = markupReplacingFailedFormulas(
            in: state.originalMarkup,
            spans: state.spans,
            formulas: formulas,
            isDisplayBlock: state.isDisplayBlock
        )
        if label.markup != markup {
            label.markup = markup
        }

        // Pango attributes need byte offsets, GTK's selection counts code
        // points and search hits count characters (graphemes); record all
        // three for every marker.
        let text = label.text
        var entries: [MathLabelState.Entry] = []
        var graphemeIndex = 0
        var scalarIndex = 0
        var byteIndex = 0
        var formulaIterator = formulas.enumerated().makeIterator()
        for character in text {
            for scalar in character.unicodeScalars {
                if scalar == MathSpanExtractor.formulaMarker {
                    // Skip formulas that fell back to source; they have no marker.
                    while let (index, formula) = formulaIterator.next() {
                        guard let formula else { continue }
                        let shape = MathShape(formula: formula, span: state.spans[index], label: label.widgetPointer)
                        entries.append(.init(
                            byteIndex: byteIndex,
                            scalarIndex: scalarIndex,
                            graphemeIndex: graphemeIndex,
                            shape: shape
                        ))
                        break
                    }
                }
                scalarIndex += 1
                byteIndex += scalar.utf8.count
            }
            graphemeIndex += 1
        }
        state.entries = entries
        state.fallbackSpans = zip(state.spans, formulas).compactMap { $1 == nil ? $0 : nil }

        let attributes = TextAttributes()
        state.appendShapes(to: attributes)
        label.attributes = attributes
        installShapeRenderer(on: label)
        installCopyHandler(on: label)
        label.setAccessibleLabel(state.accessibleText(labelText: text))
    }

    /// The label markup with every formula the engine could not draw
    /// replaced by its TeX source.
    private static func markupReplacingFailedFormulas(
        in markup: String,
        spans: [MathSpan],
        formulas: [MathFormula?],
        isDisplayBlock: Bool
    ) -> String {
        guard formulas.contains(where: { $0 == nil }) else { return markup }
        var result = ""
        var index = 0
        for scalar in markup.unicodeScalars {
            if scalar == MathSpanExtractor.formulaMarker, index < spans.count {
                if formulas[index] == nil {
                    // Inline the plain text spells every formula `$tex$`;
                    // keeping that spelling keeps search offsets aligned.
                    let delimiter = isDisplayBlock ? "$$" : "$"
                    let source = pangoEscape(delimiter + spans[index].tex + delimiter)
                    result += "<span font_family=\"monospace\">\(source)</span>"
                } else {
                    result.unicodeScalars.append(scalar)
                }
                index += 1
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// The font size in pixels at each marker, from the size and scale
    /// attributes the markup puts around it (the single-label layout's headings use
    /// `size="x-large"` spans); markers outside any such span use
    /// `basePixels`.
    private static func markerFontPixels(in markup: String, basePixels: Double) -> [Double] {
        var attributeList: OpaquePointer?
        var text: UnsafeMutablePointer<CChar>?
        guard pango_parse_markup(markup, -1, 0, &attributeList, &text, nil, nil) != 0,
              let attributeList, let text
        else {
            return []
        }
        defer {
            pango_attr_list_unref(attributeList)
            g_free(text)
        }
        let bytes = UnsafeRawBufferPointer(start: text, count: strlen(text))
        let markerBytes = Array(String(MathSpanExtractor.formulaMarker).utf8)
        var sizes: [Double] = []
        var offset = 0
        while offset + markerBytes.count <= bytes.count {
            if bytes[offset] == markerBytes[0], Array(bytes[offset..<offset + markerBytes.count]) == markerBytes {
                sizes.append(fontPixels(at: offset, in: attributeList, basePixels: basePixels))
                offset += markerBytes.count
            } else {
                offset += 1
            }
        }
        return sizes
    }

    private static func fontPixels(at byteIndex: Int, in attributeList: OpaquePointer, basePixels: Double) -> Double {
        guard let iterator = pango_attr_list_get_iterator(attributeList) else { return basePixels }
        defer { pango_attr_iterator_destroy(iterator) }
        repeat {
            var start: Int32 = 0
            var end: Int32 = 0
            pango_attr_iterator_range(iterator, &start, &end)
            guard byteIndex >= Int(start), byteIndex < Int(end) else { continue }
            var pixels = basePixels
            if let absolute = pango_attr_iterator_get(iterator, PANGO_ATTR_ABSOLUTE_SIZE) {
                let size = absolute.withMemoryRebound(to: PangoAttrSize.self, capacity: 1) { $0.pointee.size }
                pixels = Double(size) / Double(PANGO_SCALE)
            } else if let points = pango_attr_iterator_get(iterator, PANGO_ATTR_SIZE) {
                let size = points.withMemoryRebound(to: PangoAttrSize.self, capacity: 1) { $0.pointee.size }
                pixels = Double(size) / Double(PANGO_SCALE) * 96 / 72
            }
            if let scale = pango_attr_iterator_get(iterator, PANGO_ATTR_SCALE) {
                pixels *= scale.withMemoryRebound(to: PangoAttrFloat.self, capacity: 1) { $0.pointee.value }
            }
            return pixels
        } while pango_attr_iterator_next(iterator) != 0
        return basePixels
    }

    /// The pixel size of the label's own font.
    private static func fontPixels(of label: Label) -> Double {
        let context = gtk_widget_get_pango_context(label.widgetPointer)
        guard let description = pango_context_get_font_description(context) else { return 15 }
        var size = Double(pango_font_description_get_size(description)) / Double(PANGO_SCALE)
        if pango_font_description_get_size_is_absolute(description) == 0 {
            var resolution = pango_cairo_context_get_resolution(context)
            if resolution <= 0 { resolution = 96 }
            size *= resolution / 72
        }
        return size > 0 ? size : 15
    }

    // MARK: - Desktop font settings

    /// Calls `handler` when the desktop's interface font or its resolution
    /// changes, which resizes the preview's text without any CSS class
    /// changing. Handlers are held weakly through `owner`: once it is gone
    /// its handler is dropped. One pair of GtkSettings connections serves
    /// every handler, made on first use.
    static func observeDesktopFontSettings(owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        fontSettingsObservers.removeAll { $0.owner == nil }
        fontSettingsObservers.append(FontSettingsObserver(owner: owner, handler: handler))
        guard !didConnectFontSettings, let settings = gtk_settings_get_default() else { return }
        didConnectFontSettings = true
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
            _, _, _ in
            MainActor.assumeIsolated {
                PreviewMath.fontSettingsObservers.removeAll { $0.owner == nil }
                for observer in PreviewMath.fontSettingsObservers {
                    observer.handler()
                }
            }
        }
        for property in ["notify::gtk-font-name", "notify::gtk-xft-dpi"] {
            g_signal_connect_data(
                UnsafeMutableRawPointer(settings),
                property,
                unsafeBitCast(callback, to: GCallback.self),
                nil,
                nil,
                GConnectFlags(rawValue: 0)
            )
        }
    }

    private static var fontSettingsObservers: [FontSettingsObserver] = []
    private static var didConnectFontSettings = false

    // MARK: - Drawing

    /// Sets the formula drawer on the label's Pango context — again each
    /// time the label is mapped: moving it to another parent (Split ↔
    /// Preview) gives it a new context without the drawer, and the formulas'
    /// room would stay empty.
    private static func installShapeRenderer(on label: Label) {
        let context = gtk_widget_get_pango_context(label.widgetPointer)
        pango_cairo_context_set_shape_renderer(context, drawFormulaShape, nil, nil)
        let object = UnsafeMutablePointer<GObject>(label.opaquePointer)
        guard g_object_get_data(object, shapeRendererKey) == nil else { return }
        g_object_set_data(object, shapeRendererKey, UnsafeMutableRawPointer(bitPattern: 1))
        let onMap: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { widget, _ in
            guard let widget else { return }
            let context = gtk_widget_get_pango_context(widget.assumingMemoryBound(to: GtkWidget.self))
            pango_cairo_context_set_shape_renderer(context, drawFormulaShape, nil, nil)
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(label.opaquePointer),
            "map",
            unsafeBitCast(onMap, to: GCallback.self),
            nil,
            nil,
            GConnectFlags(rawValue: 0)
        )
    }

    // MARK: - Copy

    /// Connected once per label for its lifetime (the flag lives in its own
    /// key, so it outlasts the formulas' state when an edit removes them).
    private static func installCopyHandler(on label: Label) {
        let object = UnsafeMutablePointer<GObject>(label.opaquePointer)
        guard g_object_get_data(object, copyHandlerKey) == nil else { return }
        g_object_set_data(object, copyHandlerKey, UnsafeMutableRawPointer(bitPattern: 1))
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { instance, _ in
            guard let instance else { return }
            MainActor.assumeIsolated {
                PreviewMath.copySelection(of: OpaquePointer(instance))
            }
        }
        // After the default handler, so the TeX text replaces the U+FFFC
        // copy GTK just put on the clipboard.
        g_signal_connect_data(
            label.widgetPointer,
            "copy-clipboard",
            unsafeBitCast(callback, to: GCallback.self),
            nil,
            nil,
            GConnectFlags(rawValue: 1)  // G_CONNECT_AFTER
        )
    }

    private static func copySelection(of labelPointer: OpaquePointer) {
        guard let state = state(ofPointer: labelPointer) else { return }
        var start: Int32 = 0
        var end: Int32 = 0
        guard gtk_label_get_selection_bounds(labelPointer, &start, &end) != 0, start != end else { return }
        let text = String(cString: gtk_label_get_text(labelPointer))
        let lower = Int(min(start, end))
        let upper = Int(max(start, end))
        let copied = state.sourceText(labelText: text, scalarRange: lower..<upper)
        let clipboard = gtk_widget_get_clipboard(UnsafeMutablePointer<GtkWidget>(labelPointer))
        gdk_clipboard_set_text(clipboard, copied)
    }

    // MARK: - State storage

    private static func state(of label: Label) -> MathLabelState? {
        state(ofPointer: label.opaquePointer)
    }

    private static func state(ofPointer pointer: OpaquePointer) -> MathLabelState? {
        guard let raw = g_object_get_data(UnsafeMutablePointer<GObject>(pointer), stateKey) else { return nil }
        return Unmanaged<MathLabelState>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func attachState(to label: Label) -> MathLabelState {
        let state = MathLabelState()
        g_object_set_data_full(
            UnsafeMutablePointer<GObject>(label.opaquePointer),
            stateKey,
            Unmanaged.passRetained(state).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<MathLabelState>.fromOpaque(raw).release()
            }
        )
        return state
    }

    private static func detachState(from label: Label) {
        g_object_set_data(UnsafeMutablePointer<GObject>(label.opaquePointer), stateKey, nil)
    }

    static func markAsDisplayBlock(_ label: Label) {
        let state = state(of: label) ?? attachState(to: label)
        state.isDisplayBlock = true
    }

    private static func forEachMathLabel(under widget: Widget, _ body: (Label, MathLabelState) -> Void) {
        if let label = widget.tryCast(Label.self), let state = state(of: label), !state.spans.isEmpty {
            body(label, state)
        }
        for child in widget.children() {
            forEachMathLabel(under: child, body)
        }
    }
}

private struct FontSettingsObserver {
    weak var owner: AnyObject?
    let handler: @MainActor () -> Void
}

/// One drawn formula. Pango copies shape attributes; each copy holds a
/// reference (see ``PreviewMath``'s shape attribute copy/destroy pair).
final class MathShape {
    let formula: MathFormula
    let span: MathSpan
    /// The label drawing this formula. Not retained: the attribute that
    /// holds the shape lives inside that label's layout.
    let label: UnsafeMutablePointer<GtkWidget>

    init(formula: MathFormula, span: MathSpan, label: UnsafeMutablePointer<GtkWidget>) {
        self.formula = formula
        self.span = span
        self.label = label
    }

    /// Room around the formula's box: the ink of fractions and limits runs a
    /// pixel or two past the box the engine reports, and without this two
    /// lines of tall formulas touch.
    var horizontalPadding: Double {
        max(1, (formula.pixelSize * 0.04).rounded(.up))
    }

    var verticalPadding: Double {
        max(2, (formula.pixelSize * 0.1).rounded(.up))
    }
}

@MainActor
final class MathLabelState {
    struct Entry {
        let byteIndex: Int
        let scalarIndex: Int
        let graphemeIndex: Int
        let shape: MathShape
    }

    var originalMarkup = ""
    var spans: [MathSpan] = []
    var fallbackSpans: [MathSpan] = []
    var entries: [Entry] = []
    struct DecisionKey: Hashable {
        let tex: String
        let isDisplay: Bool
        /// The pixel size in quarter pixels, as the formula cache keys it.
        let quarterPixels: Int
    }

    /// What was decided for a formula: drawn, or its source shown (nil).
    struct Decision {
        let formula: MathFormula?
        /// Refused only at the memory limit; worth trying again.
        let isRetryable: Bool
    }

    /// The decisions for the label's formulas; a postponed one has none.
    var decisions: [DecisionKey: Decision] = [:]
    /// The font size of each marker for a base size, which takes a parse of
    /// the markup to find.
    var markerSizes: (basePixels: Double, sizes: [Double])?
    /// The width, clip area and scale the drawn-formula budget assumed
    /// (see ``PreviewMath/drawnFormulaBudget``); the label is laid out again
    /// when they change clearly (allocation, a resize, another screen).
    var budgetFrame: (width: Double, clipArea: Double, scale: Double) = (0, 0, 1)
    /// Whether the budget could bind (the label was estimated), and whether
    /// it left some of the label's formulas as source.
    var isBudgetSensitive = false
    var isBudgetLimited = false
    var baseFontPixels = 0.0
    /// The label's font size when last read: formulas follow its changes.
    var measuredFontPixels = 0.0
    var isDisplayBlock = false
    var hasPostponedFormulas = false

    func appendShapes(to attributes: TextAttributes) {
        for entry in entries {
            let formula = entry.shape.formula
            let padX = entry.shape.horizontalPadding
            let padY = entry.shape.verticalPadding
            var rect = PangoRectangle(
                x: 0,
                y: Int32(-((formula.ascent + padY) * Double(PANGO_SCALE)).rounded(.up)),
                width: Int32(((formula.width + 2 * padX) * Double(PANGO_SCALE)).rounded(.up)),
                height: Int32(((formula.height + 2 * padY) * Double(PANGO_SCALE)).rounded(.up))
            )
            let data = Unmanaged.passRetained(entry.shape).toOpaque()
            guard let attribute = pango_attr_shape_new_with_data(&rect, &rect, data, retainShape, releaseShape) else {
                Unmanaged<MathShape>.fromOpaque(data).release()
                continue
            }
            let markerLength = String(MathSpanExtractor.formulaMarker).utf8.count
            attribute.pointee.start_index = guint(entry.byteIndex)
            attribute.pointee.end_index = guint(entry.byteIndex + markerLength)
            pango_attr_list_insert(attributes.pointer, attribute)
        }
    }

    /// The label text with each drawn formula spelled as its TeX source,
    /// limited to the code points in `scalarRange` when given.
    func sourceText(labelText: String, scalarRange: Range<Int>? = nil) -> String {
        var result = String.UnicodeScalarView()
        var entryIterator = entries.makeIterator()
        var nextEntry = entryIterator.next()
        for (index, scalar) in labelText.unicodeScalars.enumerated() {
            let entry = nextEntry?.scalarIndex == index ? nextEntry : nil
            if entry != nil {
                nextEntry = entryIterator.next()
            }
            if let range = scalarRange, !range.contains(index) {
                continue
            }
            if let entry {
                let delimiter = entry.shape.span.isDisplay ? "$$" : "$"
                result.append(contentsOf: (delimiter + entry.shape.span.tex + delimiter).unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    func accessibleText(labelText: String) -> String {
        sourceText(labelText: labelText)
    }

    /// See ``PreviewMath/labelOffset(forPlainOffset:in:isRangeEnd:)``. The plain text
    /// spells every formula `$tex$` (drawn or not), while the label text
    /// has one character for a drawn formula and the same `$tex$` for one
    /// that fell back to source.
    func labelOffset(forPlainOffset offset: Int, isRangeEnd: Bool) -> Int {
        var shift = 0
        for entry in entries {
            let plainStart = entry.graphemeIndex + shift
            // Counted as characters of `$tex$`: a TeX that starts with a
            // combining mark merges with the dollar.
            let plainLength = "$\(entry.shape.span.tex)$".count
            if offset <= plainStart {
                break
            }
            if offset < plainStart + plainLength {
                // Inside the formula's source: snap to the formula.
                return entry.graphemeIndex + (isRangeEnd ? 1 : 0)
            }
            shift += plainLength - 1
        }
        return offset - shift
    }
}

// MARK: - C callbacks

private func retainShape(_ data: gconstpointer?) -> gpointer? {
    guard let data else { return nil }
    let shape = Unmanaged<MathShape>.fromOpaque(data)
    _ = shape.retain()
    return UnsafeMutableRawPointer(mutating: data)
}

private func releaseShape(_ data: gpointer?) {
    guard let data else { return }
    Unmanaged<MathShape>.fromOpaque(data).release()
}

private func drawFormulaShape(
    _ cairo: OpaquePointer?,
    _ attribute: UnsafeMutablePointer<PangoAttrShape>?,
    _ doPath: gboolean,
    _: gpointer?
) {
    // In path mode Pango collects outlines (pango_cairo_layout_path); a
    // formula has none to add.
    guard doPath == 0, let cairo, let attribute, let data = attribute.pointee.data else { return }
    let shape = Unmanaged<MathShape>.fromOpaque(data).takeUnretainedValue()
    // Pango moves to the shape's baseline origin before calling back; the
    // engine draws from the box's top-left corner.
    var x = 0.0
    var y = 0.0
    cairo_get_current_point(cairo, &x, &y)
    let top = y + Double(attribute.pointee.logical_rect.y) / Double(PANGO_SCALE) + shape.verticalPadding
    // The renderer sets the source to the run's foreground — a link's
    // colour, a dimmed quote, a search hit's text — before calling back;
    // the label's own colour stands in when it is not a plain colour.
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var alpha = 0.0
    if cairo_pattern_get_rgba(cairo_get_source(cairo), &red, &green, &blue, &alpha) != CAIRO_STATUS_SUCCESS {
        var color = GdkRGBA()
        gtk_widget_get_color(shape.label, &color)
        (red, green, blue, alpha) = (Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha))
    }
    cairo_save(cairo)
    cairo_translate(cairo, x + shape.horizontalPadding, top)
    shape.formula.draw(on: UnsafeMutableRawPointer(cairo), red: red, green: green, blue: blue, alpha: alpha)
    cairo_restore(cairo)
    if logsFormulaDraws {
        FileHandle.standardError.write(Data("swiftynotes-debug: formula drawn \(shape.formula.tex)\n".utf8))
    }
}

/// Lets the black-box UI tests see formulas being drawn, which the
/// accessibility tree cannot show.
private let logsFormulaDraws = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_LOG_FORMULA_DRAWS"] == "1"
