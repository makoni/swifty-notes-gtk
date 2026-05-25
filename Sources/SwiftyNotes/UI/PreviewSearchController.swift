import Adwaita
import Foundation

/// Drives a ``FindReplaceBar`` against the rendered ``MarkdownPreview``.
/// Mirrors the editor-side controller's contract — same engine,
/// same step semantics — minus the replace half (replacing inside
/// a rendered view doesn't make sense; the bar is mounted in
/// read-only mode).
@MainActor
final class PreviewSearchController {
    let bar: FindReplaceBar
    private let preview: MarkdownPreview

    private var lastQuery: String = ""
    private var lastOptions: SearchOptions = .init()

    /// Cached matches in document order. Refreshed whenever the
    /// bar's query / options change, or the preview re-renders
    /// (handled by the host window calling ``onPreviewRerendered()``
    /// after a render).
    private var matches: [PreviewMatch] = []
    private var activeIndex: Int?

    init(bar: FindReplaceBar, preview: MarkdownPreview) {
        self.bar = bar
        self.preview = preview
        // The preview bar is mounted read-only so the replace half
        // is locked off — replacing inside a rendered view isn't
        // meaningful.
        bar.isReadOnly = true
        wireBarCallbacks()
    }

    /// Host window calls this after every preview re-render so the
    /// match cache stays in sync with the visible content (otherwise
    /// active-match scrolling could land on a stale block index).
    func onPreviewRerendered() {
        guard !lastQuery.isEmpty else { return }
        recomputeMatches()
        // After a re-render the cached active index is no longer
        // meaningful — the block ordering may have shifted. Reset
        // and step forward so the user lands on something sensible.
        activeIndex = nil
        if !matches.isEmpty {
            step(forward: true)
        } else {
            updateBarCount()
        }
    }

    private func wireBarCallbacks() {
        bar.onQueryChanged = { [weak self] query, options in
            self?.applyQuery(query, options: options)
        }
        bar.onStepNext = { [weak self] in self?.step(forward: true) }
        bar.onStepPrev = { [weak self] in self?.step(forward: false) }
        bar.onClose = { [weak self] in self?.clearState() }
    }

    private func applyQuery(_ query: String, options: SearchOptions) {
        lastQuery = query
        lastOptions = options
        if query.isEmpty {
            clearState()
            return
        }
        recomputeMatches()
        activeIndex = nil
        if matches.isEmpty {
            updateBarCount()
        } else {
            step(forward: true)
        }
    }

    private func recomputeMatches() {
        matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: lastQuery,
            options: lastOptions,
        )
        if let active = activeIndex, active >= matches.count {
            activeIndex = matches.isEmpty ? nil : matches.count - 1
        }
    }

    private func step(forward: Bool) {
        guard !matches.isEmpty else {
            updateBarCount()
            return
        }
        let newIndex: Int
        if let active = activeIndex {
            if forward {
                newIndex = (active + 1) % matches.count
            } else {
                newIndex = (active - 1 + matches.count) % matches.count
            }
        } else {
            // First step after a query change: from the top of the
            // document. (Unlike the editor we don't have a "cursor"
            // to anchor against — the preview is a rendered view.)
            newIndex = forward ? 0 : matches.count - 1
        }
        activeIndex = newIndex
        scrollToMatch(matches[newIndex])
        updateBarCount()
    }

    /// Bring the matched block into the preview's visible band by
    /// translating its blockIndex through the preview's
    /// `blockToRowIndex` mapping to the rendered widget's row, then
    /// mutating the scroll's vadjustment.
    private func scrollToMatch(_ match: PreviewMatch) {
        guard let rowIndex = preview.blockToRowIndex[match.blockIndex] else { return }
        let children = preview.container.children()
        guard children.indices.contains(rowIndex) else { return }
        let widget = children[rowIndex]
        var allocation = GtkAllocation()
        gtk_widget_get_allocation(widget.widgetPointer, &allocation)
        // Pre-first-layout the allocation is zeroed; bail rather
        // than scrolling to (0, 0) — the next step call after GTK
        // has laid the rows out will succeed.
        guard allocation.height > 0 else { return }
        let rowTop = Double(allocation.y)
        let rowBottom = rowTop + Double(allocation.height)
        let adjustment = preview.rootScroll.verticalAdjustment
        let viewTop = adjustment.value
        let viewBottom = viewTop + adjustment.pageSize
        if rowTop < viewTop {
            adjustment.value = max(adjustment.lower, rowTop)
        } else if rowBottom > viewBottom {
            adjustment.value = min(
                adjustment.upper - adjustment.pageSize,
                rowBottom - adjustment.pageSize,
            )
        }
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
extension PreviewSearchController {
    var debugMatchCount: Int { matches.count }
    var debugActiveIndex: Int? { activeIndex }
    var debugCachedQuery: String { lastQuery }
}
#endif
