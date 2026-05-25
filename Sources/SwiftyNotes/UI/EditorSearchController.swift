import Adwaita
import Foundation

/// Wires a ``FindReplaceBar`` to the editor's ``SourceBuffer`` /
/// ``SourceView``. Owns the search state — cached matches, the
/// active match index, the buffer-change subscription that
/// invalidates the cache — and routes the bar's callbacks into
/// concrete buffer mutations.
///
/// Why we don't use `GtkSourceSearchContext` here: the context's
/// occurrence count is computed on a background scan that lands
/// through `notify::occurrences-count`, which makes the unit-test
/// story significantly harder (have to spin the main loop until
/// the scan finishes, which is flaky on headless CI). Our notes
/// are small enough that a synchronous regex pass via
/// ``MarkdownSearchEngine.matches(in:query:options:)`` finishes
/// in microseconds — same engine the preview pane uses, so the
/// behaviour stays consistent across panes.
@MainActor
final class EditorSearchController {
    let bar: FindReplaceBar

    private let view: SourceView
    private let buffer: SourceBuffer

    /// Last query / options that produced ``matches``. Used to skip
    /// recomputation when nothing actually changed (e.g. when the
    /// buffer-change handler fires for unrelated edits — moves the
    /// cursor without altering text).
    private var lastQuery: String = ""
    private var lastOptions: SearchOptions = .init()

    /// Cached match ranges in document order. Indices into
    /// `buffer.text`. Invalidated by the buffer-change handler.
    private var matches: [Range<String.Index>] = []
    /// 0-based index into ``matches`` for the currently highlighted
    /// match. `nil` when no match is active (empty query, no hits,
    /// or just-cleared state).
    private var activeIndex: Int?

    init(bar: FindReplaceBar, view: SourceView, buffer: SourceBuffer) {
        self.bar = bar
        self.view = view
        self.buffer = buffer
        wireBarCallbacks()
        wireBufferChange()
    }
    // No explicit deinit / signal disconnect: the buffer-change
    // handler captures `[weak self]` and SignalConnection holds a
    // `weak var source` to the buffer, so once either the controller
    // or the buffer goes away the closure is effectively dead.

    private func wireBarCallbacks() {
        bar.onQueryChanged = { [weak self] query, options in
            self?.applyQuery(query, options: options)
        }
        bar.onStepNext = { [weak self] in self?.step(forward: true) }
        bar.onStepPrev = { [weak self] in self?.step(forward: false) }
        bar.onClose = { [weak self] in self?.clearState() }
    }

    private func wireBufferChange() {
        buffer.onChanged { [weak self] in
            guard let self else { return }
            // Buffer-mutating actions inside this controller (the
            // replace pipeline in Phase 3) also fire `changed`; we
            // rely on the cheap-recompute shortcut here when the
            // cached query is still empty to keep that a no-op
            // until something is actually being searched.
            guard !lastQuery.isEmpty else { return }
            recomputeMatches()
            updateBarCount()
        }
    }

    /// Re-run the search whenever the bar reports a new query or
    /// a toggled option. Empty query clears state (matches the
    /// "you're not actively searching" affordance — no count, no
    /// selection).
    private func applyQuery(_ query: String, options: SearchOptions) {
        lastQuery = query
        lastOptions = options
        if query.isEmpty {
            clearState()
            return
        }
        recomputeMatches()
        // Auto-step to first match relative to the current cursor
        // position — same affordance every GNOME find bar offers.
        // If there are zero matches we just update the count
        // (which will read "0" / "" via setMatchCount) without
        // moving the cursor.
        activeIndex = nil
        if matches.isEmpty {
            updateBarCount()
        } else {
            step(forward: true)
        }
    }

    private func recomputeMatches() {
        let text = buffer.text
        matches = MarkdownSearchEngine.matches(
            in: text,
            query: lastQuery,
            options: lastOptions,
        )
        // If we had an active match before the edit, try to keep
        // it pinned. Otherwise the existing index might point past
        // the end of the new matches array.
        if let active = activeIndex, active >= matches.count {
            activeIndex = matches.isEmpty ? nil : matches.count - 1
        }
    }

    /// Move to the next / previous match. Wraps around the document.
    /// First-time stepping after a query change starts from the
    /// match closest to (and at or after) the current cursor —
    /// i.e. typing "foo" jumps to the foo that's nearest below the
    /// caret, not back to the top.
    private func step(forward: Bool) {
        guard !matches.isEmpty else {
            updateBarCount()
            return
        }
        let text = buffer.text
        let newIndex: Int
        if let active = activeIndex {
            if forward {
                newIndex = (active + 1) % matches.count
            } else {
                newIndex = (active - 1 + matches.count) % matches.count
            }
        } else {
            // First step after a query change. Pick the first match
            // at or after the cursor (forward direction) or the last
            // one at or before the cursor (backward).
            let cursorOffset = buffer.selectedRange.lowerBound
            let cursorIndex = text.index(
                text.startIndex,
                offsetBy: min(cursorOffset, text.count),
            )
            if forward {
                newIndex = matches.firstIndex(where: { $0.lowerBound >= cursorIndex }) ?? 0
            } else {
                newIndex = matches.lastIndex(where: { $0.upperBound <= cursorIndex }) ?? (matches.count - 1)
            }
        }
        activeIndex = newIndex
        selectMatch(at: newIndex)
        updateBarCount()
    }

    private func selectMatch(at index: Int) {
        guard matches.indices.contains(index) else { return }
        let text = buffer.text
        let match = matches[index]
        let startOffset = text.distance(from: text.startIndex, to: match.lowerBound)
        let endOffset = text.distance(from: text.startIndex, to: match.upperBound)
        buffer.select(range: startOffset..<endOffset)
        scrollViewToCursor()
    }

    private func scrollViewToCursor() {
        // Scroll the active match into view. swift-adwaita's
        // SourceView doesn't expose a wrapper for
        // `gtk_text_view_scroll_to_mark`, so drop into the raw GTK
        // API. yalign = 0.3 lands the cursor at one-third from the
        // top of the visible area — the same target GtkSourceView
        // uses for its own stepped navigation.
        let viewPointer = UnsafeMutablePointer<GtkTextView>(view.opaquePointer)
        let bufferPointer = UnsafeMutablePointer<GtkTextBuffer>(buffer.opaquePointer)
        guard let insertMark = gtk_text_buffer_get_insert(bufferPointer) else { return }
        gtk_text_view_scroll_to_mark(
            viewPointer,
            insertMark,
            /* within_margin */ 0.0,
            /* use_align */ 1,
            /* xalign */ 0.0,
            /* yalign */ 0.3,
        )
    }

    private func updateBarCount() {
        if lastQuery.isEmpty {
            bar.setMatchCount(total: 0, activeDisplayIndex: nil)
            return
        }
        let total = matches.count
        let display: Int?
        if let activeIndex, total > 0 {
            display = activeIndex + 1
        } else {
            display = nil
        }
        bar.setMatchCount(total: total, activeDisplayIndex: display)
    }

    private func clearState() {
        lastQuery = ""
        matches.removeAll()
        activeIndex = nil
        bar.setMatchCount(total: 0, activeDisplayIndex: nil)
    }
}

#if DEBUG
extension EditorSearchController {
    var debugMatchCount: Int { matches.count }
    var debugActiveIndex: Int? { activeIndex }
    var debugCachedQuery: String { lastQuery }
    func debugRecomputeFromBuffer() {
        guard !lastQuery.isEmpty else { return }
        recomputeMatches()
        updateBarCount()
    }
}
#endif
