import Adwaita
import Foundation

/// Ctrl+G quick-jump palette. Mirrors the design's `.sn-pal` overlay:
/// a centered modal `Window` with a `SearchEntry` on top, a grouped
/// `ListBox` of headings underneath, and a keyboard-hint footer below.
///
/// Behaviour contract (from `palette.jsx`):
///   * empty query → "Recent jumps" group (max 5) then "All headings"
///     in document order, excluding entries already in the recents.
///   * non-empty query → "Matches" group ranked by ``PaletteRanker``.
///   * keyboard: ↑/↓ move highlight, PgUp/PgDn move by 5, Home/End
///     go to first/last, Enter activates, Esc + Ctrl+G dismiss.
///   * the currently in-view heading is rendered with a "current"
///     pill so the user knows where they are even when they search.
@MainActor
final class CommandPaletteWindow {
    private let dialog: Dialog
    private let transient: ApplicationWindow
    private let searchEntry: SearchEntry
    private let list: ListBox
    private let footerCount: Label
    private let emptyLabel: Label
    private let scroll: ScrolledWindow

    private let headings: [Heading]
    private let recents: [String]
    private let currentID: String?
    private let parentText: [String: String]
    private let onPick: (String) -> Void
    private let onClosed: () -> Void

    private var items: [Heading] = []
    private var rowWidgets: [ListBoxRow] = []
    private var highlightIndex: Int = 0

    #if DEBUG
        /// Incremented every time `close()` is called via the `stop-search`
        /// (Escape) path. Tests use this instead of `onClosed`, which only fires
        /// for a dialog that was presented.
        var debugCloseCallCount = 0
    #endif

    init(
        transientFor: ApplicationWindow,
        headings: [Heading],
        currentID: String?,
        recents: [String],
        onPick: @escaping (String) -> Void,
        onClosed: @escaping () -> Void = {},
    ) {
        self.headings = headings
        self.recents = recents
        self.currentID = currentID
        self.onPick = onPick
        self.onClosed = onClosed
        self.transient = transientFor

        // Build the H3+ → parent H2 lookup once; the ranker doesn't
        // need it but our row rendering does (parent breadcrumb on
        // H3+ rows).
        var parentMap: [String: String] = [:]
        var currentH2: String?
        for heading in headings {
            if heading.level == 2 { currentH2 = heading.text }
            if heading.level >= 3, let parent = currentH2 {
                parentMap[heading.id] = parent
            }
        }
        parentText = parentMap

        // AdwDialog draws its own dimmed backdrop behind the floating
        // dialog (libadwaita ≥ 1.5), which is the closest GTK4
        // equivalent of the design's `backdrop-filter: blur(2px)`.
        // True frosted blur isn't available on GTK4 yet — pinning a
        // GskBlurNode behind the dialog is technically possible but
        // requires custom drawing; the AdwDialog dim is the
        // production-quality compromise the rest of the GNOME stack
        // uses.
        dialog = Dialog()
        dialog.title = "Jump to heading"
        dialog.contentWidth = 640
        dialog.contentHeight = 480
        dialog.presentationMode = .floating
        searchEntry = SearchEntry()
        searchEntry.placeholderText = "Jump to heading…"
        searchEntry.hexpand = true
        searchEntry.searchDelay = 0 // palette should feel instant; debounce already happens at keystroke level

        list = ListBox()
        list.selectionMode = .browse
        list.activateOnSingleClick = true
        list.addCSSClass("navigation-sidebar")
        list.setAccessibleLabel("Jump-to-heading results")

        scroll = ScrolledWindow(child: list)
        scroll.setPolicy(horizontal: .never, vertical: .automatic)
        scroll.vexpand = true
        scroll.minContentHeight = 320

        emptyLabel = Label("")
        emptyLabel.wrap = true
        emptyLabel.xalign = 0
        emptyLabel.addCSSClass(.dimLabel)
        emptyLabel.marginTop = 24
        emptyLabel.marginBottom = 12

        footerCount = Label("")
        footerCount.addCSSClass(.dimLabel)
        footerCount.addCSSClass("caption")
        footerCount.xalign = 1

        // SearchEntry already renders its own magnifier glyph
        // inside the field, so the wrapping row carries the
        // entry alone — adding an external `Image(icon:)` next to
        // it duplicated the icon.
        let searchRow = Box(orientation: .horizontal, spacing: 8)
        searchRow.setMargins(12)
        searchRow.append(searchEntry)

        let footerRow = Box(orientation: .horizontal, spacing: 16)
        footerRow.marginStart = 12
        footerRow.marginEnd = 12
        footerRow.marginTop = 6
        footerRow.marginBottom = 8
        let kbdHints = Label("↑↓ navigate · ↵ jump · Esc close")
        kbdHints.addCSSClass(.dimLabel)
        kbdHints.addCSSClass("caption")
        kbdHints.xalign = 0
        kbdHints.hexpand = true
        footerRow.append(kbdHints)
        footerRow.append(footerCount)

        let content = Box(orientation: .vertical, spacing: 0)
        content.append(searchRow)
        content.append(Separator())
        content.append(scroll)
        content.append(emptyLabel)
        content.append(Separator())
        content.append(footerRow)

        dialog.child = content
        wireSignals()
        rebuildItems()
    }

    func present() {
        // Re-derive items with currentID highlighted before the dialog
        // ever paints — otherwise the first render briefly shows the
        // 0th row highlighted before our currentID resolution kicks in.
        rebuildItems()
        dialog.present(transient)
        dialog.enableBackdropClickDismiss()
        _ = searchEntry.grabFocus()
    }

    private func wireSignals() {
        // Bridge AdwDialog's intrinsic "I'm closing" signal back up
        // to the owner so it can drop its strong reference to this
        // wrapper. Without that release the wrapper would leak; with
        // the release happening too early (i.e. without the owner
        // holding a strong ref in the first place) every callback
        // below would be invoked on a deallocated `self` and silently
        // no-op — which is exactly the bug that motivated this code.
        dialog.onClosed { [weak self] in
            self?.onClosed()
        }

        searchEntry.onSearchChanged { [weak self] in
            self?.rebuildItems()
        }

        // GtkSearchEntry consumes Escape by emitting stop-search and returning
        // GDK_EVENT_STOP, so LOCAL-scope shortcuts on ancestor widgets (including
        // the dialog's own Escape shortcut below) never fire when the search field
        // has focus. Connect here so pressing Escape always closes the palette,
        // regardless of which widget currently holds keyboard focus.
        searchEntry.onStopSearch { [weak self] in
            #if DEBUG
                self?.debugCloseCallCount += 1
            #endif
            _ = self?.dialog.close()
        }

        list.onRowActivated { [weak self] row in
            guard let self else { return }
            let index = Int(row.index)
            guard items.indices.contains(index) else { return }
            commit(items[index].id)
        }

        // Window-level shortcuts intercept before SearchEntry's default
        // cursor-movement handlers, so the user can type AND navigate
        // the list without having to leave the input.
        dialog.addKeyboardShortcut("Down") { [weak self] in
            self?.move(by: 1); return true
        }
        dialog.addKeyboardShortcut("Up") { [weak self] in
            self?.move(by: -1); return true
        }
        dialog.addKeyboardShortcut("Page_Down") { [weak self] in
            self?.move(by: 5); return true
        }
        dialog.addKeyboardShortcut("Page_Up") { [weak self] in
            self?.move(by: -5); return true
        }
        dialog.addKeyboardShortcut("Home") { [weak self] in
            self?.setHighlight(0); return true
        }
        dialog.addKeyboardShortcut("End") { [weak self] in
            guard let self else { return true }
            setHighlight(items.count - 1)
            return true
        }
        dialog.addKeyboardShortcut("Return") { [weak self] in
            self?.activateHighlighted(); return true
        }
        dialog.addKeyboardShortcut("KP_Enter") { [weak self] in
            self?.activateHighlighted(); return true
        }
        dialog.addKeyboardShortcut("Escape") { [weak self] in
            _ = self?.dialog.close(); return true
        }
        // Ctrl+G toggles — pressing again closes the palette.
        dialog.addKeyboardShortcut("<Primary>g") { [weak self] in
            _ = self?.dialog.close(); return true
        }
    }

    private func rebuildItems() {
        let query = searchEntry.text
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            items = emptyQueryItems()
        } else {
            items = PaletteRanker.rank(headings: headings, query: trimmed)
        }
        list.removeAll()
        rowWidgets.removeAll()
        for heading in items {
            let row = makeRow(for: heading, query: trimmed)
            list.append(row)
            rowWidgets.append(row)
        }

        if items.isEmpty {
            emptyLabel.text = trimmed.isEmpty
                ? "No headings in this note."
                : "No headings match \"\(trimmed)\""
            emptyLabel.visible = true
            scroll.visible = false
        } else {
            emptyLabel.visible = false
            scroll.visible = true
        }

        footerCount.text = "\(items.count) of \(headings.count)"

        // Default highlight: currentID if visible, else first row.
        if trimmed.isEmpty,
           let currentID,
           let idx = items.firstIndex(where: { $0.id == currentID })
        {
            setHighlight(idx)
        } else {
            setHighlight(0)
        }
    }

    private func emptyQueryItems() -> [Heading] {
        let recentSet = Set(recents)
        var out: [Heading] = []
        // Recent jumps first, in newest-first order — these came in as
        // ids; resolve back to headings via the full list.
        for id in recents {
            if let heading = headings.first(where: { $0.id == id }) {
                out.append(heading)
            }
        }
        for heading in headings where !recentSet.contains(heading.id) {
            out.append(heading)
        }
        return out
    }

    private func makeRow(for heading: Heading, query: String) -> ListBoxRow {
        let row = ListBoxRow()
        row.addCSSClass("sn-pal-row")

        let pill = Label("H\(heading.level)")
        pill.addCSSClass("sn-pal-pill")
        pill.addCSSClass("sn-pal-pill-h\(heading.level)")
        pill.marginEnd = 6

        let parentLabel = Label("")
        parentLabel.addCSSClass(.dimLabel)
        if let parent = parentText[heading.id], heading.level >= 3 {
            parentLabel.text = "\(parent) ›"
            parentLabel.visible = true
        } else {
            parentLabel.visible = false
        }
        parentLabel.marginEnd = 4

        let leafLabel = Label("")
        if query.isEmpty {
            leafLabel.useMarkup = false
            leafLabel.text = heading.text
        } else {
            // `label.markup` parses the Pango `<span>` highlight;
            // `label.text` would strip it back to literal angle
            // brackets. Same fix the outline rows use.
            leafLabel.markup = Self.highlightedMarkup(heading.text, query: query)
        }
        leafLabel.ellipsize = .end
        leafLabel.hexpand = true
        leafLabel.xalign = 0

        let container = Box(orientation: .horizontal, spacing: 6)
        container.setMargins(8)
        container.append(pill)
        container.append(parentLabel)
        container.append(leafLabel)
        if heading.id == currentID {
            let hint = Label("current")
            hint.addCSSClass("sn-pal-hint")
            hint.addCSSClass(.dimLabel)
            container.append(hint)
            row.addCSSClass("is-current")
        }
        row.child = container
        return row
    }

    private func setHighlight(_ index: Int) {
        guard !items.isEmpty else {
            highlightIndex = 0
            return
        }
        let clamped = max(0, min(index, items.count - 1))
        highlightIndex = clamped
        list.selectRow(at: clamped)
        scrollHighlightedRowIntoView()
    }

    /// Bring the currently highlighted row into the visible band of
    /// the ScrolledWindow without stealing keyboard focus from the
    /// search entry. The earlier implementation called `grabFocus()`
    /// on the row, which yanked focus off the input — typing the
    /// second character of a query landed on the list instead of the
    /// search entry, breaking incremental search.
    ///
    /// Uses the row's allocation against the ListBox parent (rows
    /// are direct children of the box). `gtk_widget_get_allocation`
    /// is technically deprecated in favour of `compute_bounds`, but
    /// the rest of the project (see OutlineNavigation.swift) already
    /// uses it and the data we need is exactly what it returns.
    private func scrollHighlightedRowIntoView() {
        guard rowWidgets.indices.contains(highlightIndex) else { return }
        let row = rowWidgets[highlightIndex]
        var allocation = GtkAllocation()
        gtk_widget_get_allocation(row.widgetPointer, &allocation)
        // Pre-layout (first paint), allocation is zeroed — nothing
        // sensible to scroll to yet. The next setHighlight call after
        // GTK has done its sizing pass will succeed.
        guard allocation.height > 0 else { return }
        let rowTop = Double(allocation.y)
        let rowBottom = rowTop + Double(allocation.height)
        let adjustment = scroll.verticalAdjustment
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

    private func move(by delta: Int) {
        setHighlight(highlightIndex + delta)
    }

    private func activateHighlighted() {
        guard items.indices.contains(highlightIndex) else { return }
        commit(items[highlightIndex].id)
    }

    private func commit(_ id: String) {
        onPick(id)
        _ = dialog.close()
    }

    /// Same Pango entity escape + yellow highlight as the outline rows.
    private static func highlightedMarkup(_ text: String, query: String) -> String {
        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()
        guard let range = lowerText.range(of: lowerQuery) else {
            return Self.escapeMarkup(text)
        }
        let pre = String(text[..<range.lowerBound])
        let hit = String(text[range])
        let post = String(text[range.upperBound...])
        return "\(escapeMarkup(pre))<span background=\"#f5c211\" foreground=\"#1e1e1e\">\(escapeMarkup(hit))</span>\(escapeMarkup(post))"
    }

    private static func escapeMarkup(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&apos;")
            default: result.append(char)
            }
        }
        return result
    }
}

#if DEBUG
    extension CommandPaletteWindow {
        var debugItems: [Heading] {
            items
        }

        var debugHighlightIndex: Int {
            highlightIndex
        }

        func debugSetQuery(_ q: String) {
            searchEntry.text = q
            rebuildItems()
        }

        func debugActivateHighlighted() {
            activateHighlighted()
        }

        func debugMove(by delta: Int) {
            move(by: delta)
        }

        /// Emits the `stop-search` signal on the internal `SearchEntry` — this is
        /// exactly what `GtkSearchEntry` does when the user presses Escape with
        /// focus on the entry.  Used by unit tests to verify the Escape close path
        /// without simulating real keyboard events.
        func debugEmitStopSearch() {
            searchEntry.emitStopSearch()
        }
    }
#endif
