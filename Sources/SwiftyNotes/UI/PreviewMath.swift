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
///   formula, as in coalesced headings),
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
        state.originalMarkup = markup
        state.spans = spans
        state.baseFontPixels = fontPixels(of: label)
        layOut(label, state: state)
        return true
    }

    /// Lays out formulas that a render pass postponed when it ran out of
    /// parse budget (they show their source meanwhile). Returns true when
    /// some are still postponed after this pass.
    static func layOutPostponedFormulas(under root: Widget) -> Bool {
        var stillPostponed = false
        forEachMathLabel(under: root) { label, state in
            guard state.hasPostponedFormulas else { return }
            layOut(label, state: state)
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

    /// Re-lays out every formula label under `root` whose own font size no
    /// longer matches the size its formulas were laid out for (zoom, or the
    /// desktop's font settings). Returns true when a label was refreshed.
    @discardableResult
    static func refreshFontSizes(under root: Widget) -> Bool {
        var refreshed = false
        forEachMathLabel(under: root) { label, state in
            let pixels = fontPixels(of: label)
            guard abs(pixels - state.baseFontPixels) > 0.01 else { return }
            state.baseFontPixels = pixels
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

    private static func layOut(_ label: Label, state: MathLabelState) {
        // Parse every formula at its own size; one that does not parse falls
        // back to its source, which changes the markup.
        let sizes = markerFontPixels(in: state.originalMarkup, basePixels: state.baseFontPixels)
        var formulas: [MathFormula?] = []
        state.hasPostponedFormulas = false
        for (index, span) in state.spans.enumerated() {
            let pixels = (index < sizes.count ? sizes[index] : state.baseFontPixels) * formulaScale
            let isDisplay = span.isDisplay && state.isDisplayBlock
            // Keep what the label already drew: the cache may have dropped
            // it while a long postponed pass went on.
            if index < state.formulas.count, let drawn = state.formulas[index], drawn.tex == span.tex,
               drawn.isDisplay == isDisplay, abs(drawn.pixelSize - pixels) < 0.125
            {
                formulas.append(drawn)
                continue
            }
            formulas.append(MathRenderer.formula(tex: span.tex, isDisplay: isDisplay, pixelSize: pixels))
            if MathRenderer.lastLookupWasPostponed {
                state.hasPostponedFormulas = true
                mayHavePostponedFormulas = true
            }
        }
        state.formulas = formulas
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
    /// attributes the markup puts around it (coalesced headings use
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

    private static func installShapeRenderer(on label: Label) {
        let context = gtk_widget_get_pango_context(label.widgetPointer)
        pango_cairo_context_set_shape_renderer(context, drawFormulaShape, nil, nil)
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
    /// The formulas last laid out, by span (nil: source shown).
    var formulas: [MathFormula?] = []
    var baseFontPixels = 0.0
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
            let plainLength = entry.shape.span.tex.count + 2
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
    var color = GdkRGBA()
    gtk_widget_get_color(shape.label, &color)
    cairo_save(cairo)
    cairo_translate(cairo, x + shape.horizontalPadding, top)
    shape.formula.draw(
        on: UnsafeMutableRawPointer(cairo),
        red: Double(color.red),
        green: Double(color.green),
        blue: Double(color.blue),
        alpha: Double(color.alpha)
    )
    cairo_restore(cairo)
}
