import Adwaita
import Foundation

/// Editor + preview scroll helpers used by the Outline panel, the
/// breadcrumb, and the Ctrl+G command palette. Animates both panes
/// when ``smoothScroll`` is on; falls back to an instant jump
/// otherwise.
@MainActor
enum OutlineNavigation {
    /// Default scroll-animation duration. 260 ms matches libadwaita's
    /// own "medium" duration constant — long enough to feel smooth,
    /// short enough that fast keyboard navigation doesn't stack a
    /// queue of pending animations.
    static let smoothScrollDurationMs: Int = 260

    /// Top-of-viewport breathing room when jumping to a heading. The
    /// scroll-spy anchor sits ~80 px below the visible top, so a 24 px
    /// breathing room leaves the heading clearly above the anchor.
    static let scrollMarginTopPx: Double = 24

    /// Scrolls the source view to the heading's line. Uses
    /// `gtk_text_view_get_iter_location` to find the buffer-space Y
    /// of the line; animates the `verticalAdjustment.value` to that
    /// Y minus a top margin so the heading sits comfortably below the
    /// editor toolbar.
    ///
    /// Also places the cursor at the iter so a follow-up keystroke
    /// continues editing where the user just navigated.
    static func scrollEditor(view: SourceView, buffer: SourceBuffer, scroll: ScrolledWindow, toLine line: Int, smooth: Bool = true) {
        let zeroBased = max(line - 1, 0)
        var iter = GtkTextIter()
        let bufferPtr = UnsafeMutablePointer<GtkTextBuffer>(buffer.opaquePointer)
        let viewPtr = UnsafeMutablePointer<GtkTextView>(view.opaquePointer)
        gtk_text_buffer_get_iter_at_line(bufferPtr, &iter, gint(zeroBased))
        gtk_text_buffer_place_cursor(bufferPtr, &iter)
        var rect = GdkRectangle()
        gtk_text_view_get_iter_location(viewPtr, &iter, &rect)
        let targetY = Double(rect.y) - scrollMarginTopPx
        let adj = scroll.verticalAdjustment
        let clamped = clampToAdjustment(adj, target: targetY)
        if smooth {
            animate(adj: adj, from: adj.value, to: clamped, widget: view)
        } else {
            adj.value = clamped
        }
    }

    /// Scrolls the preview pane to the rendered widget at the given
    /// `Heading.blockIndex`. Falls back to the proportional editor-
    /// driven sync when block-targeted positioning isn't available
    /// (the widget tree hasn't allocated yet, or `blockIndex` is out
    /// of bounds for the current render).
    static func scrollPreview(heading: Heading, preview: MarkdownPreview, editorScroll: ScrolledWindow, smooth: Bool = true) {
        let previewScroll = preview.rootScroll
        if let blockY = OutlinePositions.previewY(for: heading, in: preview.container) {
            let target = blockY - scrollMarginTopPx
            let adj = previewScroll.verticalAdjustment
            let clamped = clampToAdjustment(adj, target: target)
            if smooth {
                animate(adj: adj, from: adj.value, to: clamped, widget: previewScroll)
            } else {
                adj.value = clamped
            }
        } else {
            // Block widget not yet allocated — fall back to the
            // proportional sync via the editor's adjustment position
            // (works in split mode; in preview-only mode the editor
            // is hidden so the sync is a no-op and the user just sees
            // the existing preview scroll, which is acceptable as a
            // best-effort fallback).
            PreviewScrollSync.sync(editor: editorScroll, preview: previewScroll)
        }
    }

    private static func clampToAdjustment(_ adj: Adjustment, target: Double) -> Double {
        let lower = adj.lower
        let upper = adj.upper - adj.pageSize
        if upper <= lower { return lower }
        return min(max(lower, target), upper)
    }

    private static func animate(adj: Adjustment, from: Double, to: Double, widget: Widget) {
        // Bail out on tiny deltas so a flurry of clicks doesn't queue
        // up imperceptible animations. The Adjustment proportional-sync
        // logic uses the same 0.5 px floor.
        guard abs(to - from) > 0.5 else {
            adj.value = to
            return
        }
        let target = CallbackAnimationTarget { value in
            adj.value = value
        }
        let animation = TimedAnimation(
            widget: widget,
            from: from,
            to: to,
            duration: smoothScrollDurationMs,
            target: target,
        )
        animation.easing = .easeOutCubic
        animation.play()
    }
}

/// `gtk_true()` is not exposed in Swift — gboolean is a typedef for int
/// in GLib, and `1` works equivalently. Wrapped in a small helper so the
/// call sites read like the underlying API rather than peppering literal
/// `1`s around.
private func gtk_true() -> gboolean { 1 }

/// Heading-position queries used by ``OutlineScrollSpyDriver``. Both
/// return values are in the scroll container's coordinate system so
/// they can be compared directly against the `verticalAdjustment.value`.
@MainActor
enum OutlinePositions {
    /// Y of the rendered preview block at `heading.blockIndex`,
    /// relative to the preview's scrolled-window child. Returns `nil`
    /// when the index is out of bounds (the typing-deferred render
    /// hasn't committed yet) or the widget has no allocation (the
    /// preview pane is offscreen).
    static func previewY(for heading: Heading, in container: Box) -> Double? {
        let children = container.children()
        guard children.indices.contains(heading.blockIndex) else { return nil }
        return widgetY(of: children[heading.blockIndex])
    }

    /// Y of the source-view iter at `heading.line` (1-based). Uses
    /// `gtk_text_view_get_iter_location`, which fills a rectangle in
    /// the buffer's coordinate space; we translate that into widget
    /// coordinates and add the editor's current scroll offset so the
    /// number is directly comparable against the adjustment value.
    static func editorY(for heading: Heading, view: SourceView, buffer: SourceBuffer, scroll: ScrolledWindow) -> Double? {
        let bufferPtr = UnsafeMutablePointer<GtkTextBuffer>(buffer.opaquePointer)
        let viewPtr = UnsafeMutablePointer<GtkTextView>(view.opaquePointer)
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_line(bufferPtr, &iter, gint(max(heading.line - 1, 0)))
        var rect = GdkRectangle()
        gtk_text_view_get_iter_location(viewPtr, &iter, &rect)
        // `rect.y` is in buffer coordinates; the source view's vertical
        // adjustment also reports in buffer coords (it scrolls the whole
        // buffer, not the visible window), so they're directly
        // comparable. `scroll` is unused for now but kept on the
        // signature so the API matches the preview path one day.
        _ = scroll
        return Double(rect.y)
    }

    private static func widgetY(of widget: Widget) -> Double? {
        let widgetPtr = widget.widgetPointer
        var allocation = GtkAllocation()
        gtk_widget_get_allocation(widgetPtr, &allocation)
        guard allocation.height > 0 else { return nil }
        return Double(allocation.y)
    }
}
