import Adwaita
import Foundation

/// The right-hand Outline panel — a Table-of-Contents view of the
/// active note's headings.
@MainActor
struct OutlineSidebar {
    let root: ToolbarView
    let list: ListBox
    let searchEntry: SearchEntry
    let countBadge: Label
    let emptyLabel: Label
    let footerLabel: Label

    private let scroll: ScrolledWindow
    private let renderState: RenderState

    init() {
        OutlineCSS.installGlobalIfNeeded()

        renderState = RenderState()

        list = ListBox()
        list.selectionMode = .single
        list.activateOnSingleClick = true
        list.addCSSClass("navigation-sidebar")
        list.setAccessibleLabel("Note Outline")

        scroll = ScrolledWindow(child: list)
        scroll.setPolicy(horizontal: .never, vertical: .automatic)
        scroll.vexpand = true
        #if os(macOS)
        scroll.overlayScrolling = false
        scroll.kineticScrolling = false
        #endif

        countBadge = Label("0")
        countBadge.addCSSClass(.dimLabel)
        countBadge.addCSSClass("outline-count")

        searchEntry = SearchEntry()
        searchEntry.placeholderText = "Filter headings…"
        searchEntry.searchDelay = 120
        searchEntry.hexpand = true
        searchEntry.setAccessibleLabel("Filter Outline")

        emptyLabel = Label("")
        emptyLabel.wrap = true
        emptyLabel.xalign = 0
        emptyLabel.useMarkup = true
        emptyLabel.addCSSClass(.dimLabel)
        emptyLabel.marginStart = 6
        emptyLabel.marginEnd = 6
        emptyLabel.marginTop = 6

        // Activate-link wiring for the "Add ## Heading" hint in the
        // empty-state markup. The `<a href="…">` segments below resolve
        // to specific actions — `insert-heading` is the only one we
        // ship right now.
        let renderStateForLink = renderState
        emptyLabel.onActivateLink { href in
            // Ignored: the `<a href>` is captured in markup so a
            // future link target can be routed by inspecting `href`.
            switch href {
            case "insert-heading":
                renderStateForLink.insertHeadingHandler?()
            default:
                break
            }
        }

        footerLabel = Label("")
        footerLabel.xalign = 0
        footerLabel.addCSSClass(.dimLabel)
        footerLabel.addCSSClass("caption")
        footerLabel.marginStart = 4
        footerLabel.marginEnd = 4

        let titleLabel = Label("Outline")
        titleLabel.addCSSClass("heading")
        titleLabel.xalign = 0
        titleLabel.hexpand = true

        let titleRow = Box(orientation: .horizontal, spacing: 6)
        titleRow.append(titleLabel)
        titleRow.append(countBadge)

        let content = Box(orientation: .vertical, spacing: 10)
        content.setMargins(12)
        content.append(titleRow)
        content.append(searchEntry)
        content.append(scroll)
        content.append(emptyLabel)
        content.append(footerLabel)

        root = ToolbarView()
        root.content = content
        root.setAccessibleLabel("Outline Sidebar")

        rerender()
    }

    // MARK: — Public state accessors

    /// Snapshot of the heading rows currently visible in the panel.
    /// Index into this array matches the ListBox row index, so a
    /// row-activation handler can map a click back to a heading.
    var renderedHeadings: [Heading] { renderState.visible }

    /// All headings parsed from the active note (unfiltered).
    var allHeadings: [Heading] { renderState.allHeadings }

    var query: String { renderState.query }
    var collapsedSections: Set<String> { renderState.collapsed }
    var activeHeadingID: String? { renderState.activeID }

    func heading(at index: Int) -> Heading? {
        renderState.visible.indices.contains(index) ? renderState.visible[index] : nil
    }

    // MARK: — State mutators

    /// Replace the heading list. Re-applies the current query / collapsed
    /// state, so editing a note doesn't clear an active filter.
    func setHeadings(_ headings: [Heading]) {
        renderState.allHeadings = headings
        // Prune collapse entries for sections that no longer exist —
        // otherwise the collapsed set grows unboundedly across edits.
        let liveH2 = Set(headings.lazy.filter { $0.level == 2 }.map(\.id))
        renderState.collapsed.formIntersection(liveH2)
        rerender()
    }

    /// Update the search query. Empty (and whitespace-only) queries
    /// drop back into "show everything, respect collapse" mode.
    func setQuery(_ query: String) {
        renderState.query = query
        rerender()
    }

    /// Push the user-facing display tweaks (Settings → Outline). The
    /// density flips the `.outline-compact` class on the root so the
    /// CSS provider can tighten / loosen padding; tree-lines and
    /// drag-handle visibility flow through to the row builder's CSS
    /// classes for the next ``rerender()``.
    func applyTweaks(density: OutlineDensity, treeLines: Bool, dragHandles: Bool) {
        if density == .compact {
            root.addCSSClass("outline-compact")
        } else {
            root.removeCSSClass("outline-compact")
        }
        renderState.treeLines = treeLines
        renderState.dragHandles = dragHandles
        rerender()
    }

    /// Replace the collapsed-set wholesale. Used by ``MainWindow`` to
    /// hydrate from persisted per-note state on a note transition.
    /// Re-renders so the visible row list reflects the new mask
    /// immediately.
    func setCollapsedSections(_ set: Set<String>) {
        renderState.collapsed = set
        rerender()
    }

    /// Flip the collapsed flag for an H2 section. No-op on other levels.
    func toggleCollapsed(_ id: String) {
        guard renderState.allHeadings.contains(where: { $0.id == id && $0.level == 2 }) else { return }
        if renderState.collapsed.contains(id) {
            renderState.collapsed.remove(id)
        } else {
            renderState.collapsed.insert(id)
        }
        rerender()
    }

    /// Set the active highlight on the row whose heading id matches.
    /// Pass `nil` to clear.
    ///
    /// Performance: this fires every scroll-spy tick (30+/s during a
    /// kinetic scroll), often with the same id. Hot path — must NOT
    /// rebuild rows. Early-exits on unchanged id and only toggles the
    /// `is-active` CSS class + `ListBox.selectRow` on the relevant
    /// rows. The previous `rerender()` here was a regression that
    /// tanked scroll FPS on long notes.
    func setActiveHeading(_ id: String?) {
        guard renderState.activeID != id else { return }
        let oldID = renderState.activeID
        renderState.activeID = id

        if let oldID,
           let oldIdx = renderState.visible.firstIndex(where: { $0.id == oldID }),
           renderState.rows.indices.contains(oldIdx)
        {
            renderState.rows[oldIdx].removeCSSClass("is-active")
        }
        if let id,
           let newIdx = renderState.visible.firstIndex(where: { $0.id == id }),
           renderState.rows.indices.contains(newIdx)
        {
            renderState.rows[newIdx].addCSSClass("is-active")
            list.selectRow(at: newIdx)
        } else if id == nil {
            list.unselectAll()
        }
    }

    /// Legacy API kept for callers that already use it; equivalent to
    /// `setHeadings(_:)`.
    func render(headings: [Heading]) { setHeadings(headings) }

    // MARK: — Rendering

    private func rerender() {
        let visible = OutlineFilter.visible(
            headings: renderState.allHeadings,
            query: renderState.query,
            collapsed: renderState.collapsed,
        )
        renderState.visible = visible

        let total = renderState.allHeadings.count
        countBadge.text = "\(total)"
        let h2 = renderState.allHeadings.lazy.filter { $0.level == 2 }.count
        let h3 = renderState.allHeadings.lazy.filter { $0.level == 3 }.count
        footerLabel.text = "\(h2) section\(h2 == 1 ? "" : "s") · \(h3) subsection\(h3 == 1 ? "" : "s")"

        if renderState.treeLines {
            list.addCSSClass("has-lines")
        } else {
            list.removeCSSClass("has-lines")
        }

        // Precompute "does any visible H2 have children?". When the
        // answer is no — the showcase note is the common example —
        // there's no chevron column to align against, so we can build
        // every row as just `ListBoxRow > Label` (2 widgets) instead
        // of `ListBoxRow > Box > spacer Label > text Label` (4
        // widgets). On a typical chevron-less note that halves the
        // outline panel's widget count, which directly cuts the per-
        // frame `gtk_widget_snapshot_child` walk that dominates scroll
        // CPU at this point.
        let anyH2HasChildren = visible.contains { $0.level == 2 && hasChildren(of: $0) }

        list.removeAll()
        renderState.rows.removeAll()
        renderState.rowLabels.removeAll()
        for heading in visible {
            let (row, label) = makeRow(for: heading, anyH2HasChildren: anyH2HasChildren)
            list.append(row)
            renderState.rows.append(row)
            renderState.rowLabels.append(label)
        }

        // ListBox selection (the blue "currently selected row" tint)
        // resets every time `removeAll` runs, so a rerender from a
        // scroll-spy tick — or from a follow-up click — would leave
        // whatever row used to be selected highlighted forever. Snap
        // the selection to whichever row matches the active id so the
        // visible selection mirrors what the scroll-spy / palette /
        // click actually marked active.
        if let active = renderState.activeID,
           let index = visible.firstIndex(where: { $0.id == active })
        {
            list.selectRow(at: index)
        } else {
            list.unselectAll()
        }

        let isQuery = !renderState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if renderState.allHeadings.isEmpty {
            // The `Add ## Heading` segment is a Pango hyperlink that
            // routes to `insert-heading` via `onActivateLink` above.
            // Setting `markup` (not `text`) is what actually parses the
            // anchor — `text` strips markup back to plain.
            emptyLabel.markup = "No headings in this note. <a href=\"insert-heading\">Add <tt>## Heading</tt></a> to start."
            emptyLabel.visible = true
            scroll.visible = false
        } else if isQuery, visible.isEmpty {
            emptyLabel.useMarkup = false
            emptyLabel.text = "No headings match the filter."
            emptyLabel.visible = true
            scroll.visible = false
        } else {
            emptyLabel.visible = false
            scroll.visible = true
        }
    }

    private func makeRow(for heading: Heading, anyH2HasChildren: Bool) -> (ListBoxRow, Label) {
        let row = ListBoxRow()
        row.setAccessibleLabel(heading.text)

        let label = Label("")
        label.xalign = 0
        label.hexpand = true
        label.ellipsize = .end
        label.tooltipText = heading.text
        // Pango markup highlights query matches in the row text. With
        // no query the label is a plain non-markup string so an
        // ampersand or angle bracket in the heading doesn't accidentally
        // turn into entity-escape territory. `label.markup` is the
        // only setter that actually parses Pango syntax — `label.text`
        // strips markup, which was the source of the "raw <span...>"
        // bug.
        let trimmedQuery = renderState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            label.useMarkup = false
            label.text = heading.text
        } else {
            label.markup = Self.highlightedMarkup(heading.text, query: trimmedQuery)
        }

        row.addCSSClass("sn-out")
        row.addCSSClass("sn-out-h\(heading.level)")
        if heading.id == renderState.activeID {
            row.addCSSClass("is-active")
        }
        row.marginEnd = 4

        // Layout decision tree, optimised for widget count:
        //
        // (a) H2 with children → needs a chevron toggle, so we keep
        //     the leading `Box > [chevron, label]` shape (4 widgets).
        // (b) H2 without children, in a doc where some other H2
        //     does have children → keep a spacer-Label-in-Box so the
        //     "H2 text" column stays aligned across siblings.
        // (c) anything else (H1, H3+, and H2-without-children in a
        //     chevron-less doc) → `ListBoxRow > Label` directly
        //     (2 widgets). Indent flows through `label.marginStart`.
        let chevronColumnWidth = 20 // 16 px chevron + 4 px spacing
        let needsChevron = heading.level == 2 && hasChildren(of: heading)
        let needsAlignmentSpacer = heading.level == 2 && !needsChevron && anyH2HasChildren

        if needsChevron {
            let leadingContainer = Box(orientation: .horizontal, spacing: 4)
            leadingContainer.marginStart = indent(for: heading.level)
            leadingContainer.marginEnd = 4
            let chevron = Button(icon: .custom(renderState.collapsed.contains(heading.id) ? "pan-end-symbolic" : "pan-down-symbolic"))
            chevron.addCSSClass(.flat)
            chevron.tooltipText = renderState.collapsed.contains(heading.id) ? "Expand section" : "Collapse section"
            MacOSClickWorkaround.onClick(chevron, label: "OutlineChevron") { [weak rs = renderState, id = heading.id] in
                guard let rs else { return }
                rs.toggleHandler?(id)
            }
            leadingContainer.append(chevron)
            leadingContainer.append(label)
            row.child = leadingContainer
        } else if needsAlignmentSpacer {
            // Cheap shape variant: still need the Box to keep the H2
            // column aligned with chevron-bearing siblings, but skip
            // the spacer Label entirely — `label.marginStart` covers
            // the chevron-column width.
            let leadingContainer = Box(orientation: .horizontal, spacing: 4)
            leadingContainer.marginStart = indent(for: heading.level)
            leadingContainer.marginEnd = 4
            label.marginStart = chevronColumnWidth
            leadingContainer.append(label)
            row.child = leadingContainer
        } else {
            // Smallest shape: ListBoxRow > Label. The indent + spacing
            // moves to `label.marginStart` so the Box layer goes away.
            label.marginStart = indent(for: heading.level) + 4
            label.marginEnd = 4
            row.child = label
        }

        // Drag source: identifies the row by its heading id. The drop
        // handler on every sibling row reads this string and routes
        // it through `OutlineReorder.movedMarkdown`.
        if renderState.dragHandles {
            let source = DragSource()
            source.actions = GDK_ACTION_MOVE
            source.setTextContent(heading.id)
            row.addController(source)

            // Drop target: accepts an id-string drop, then calls the
            // toggle handler with `(droppedID, ownID)`. We piggyback on
            // the existing toggleHandler / new dropHandler so the
            // struct doesn't have to close over `self`.
            let drop = DropTarget.forText(actions: GDK_ACTION_MOVE)
            let dropHandler = renderState.dropHandler
            let targetID = heading.id
            drop.onDrop { droppedID in
                guard let droppedID, !droppedID.isEmpty else { return false }
                guard droppedID != targetID else { return false }
                dropHandler?(droppedID, targetID)
                return true
            }
            row.addController(drop)
        }
        return (row, label)
    }

    private func hasChildren(of h2: Heading) -> Bool {
        var sawH2 = false
        for heading in renderState.allHeadings {
            if heading.id == h2.id { sawH2 = true; continue }
            if !sawH2 { continue }
            if heading.level <= 2 { return false }
            if heading.level >= 3 { return true }
        }
        return false
    }

    private func indent(for level: Int) -> Int {
        switch level {
        case ...2: 0
        case 3:    16
        default:   16 + 16 * (level - 3)
        }
    }

    private static func highlightedMarkup(_ text: String, query: String) -> String {
        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()
        guard let range = lowerText.range(of: lowerQuery) else {
            return PangoMarkup.escape(text)
        }
        let pre = String(text[..<range.lowerBound])
        let hit = String(text[range])
        let post = String(text[range.upperBound...])
        return "\(PangoMarkup.escape(pre))<span background=\"#f5c211\" foreground=\"#1e1e1e\">\(PangoMarkup.escape(hit))</span>\(PangoMarkup.escape(post))"
    }

    /// Pango entity escape — same five entities the swift-adwaita
    /// preview's HTML builder uses (see ``MarkdownRendererHTMLBuilder``).
    // MARK: — Internal handler hook

    /// Wired by `MainWindow.wireSignals` so chevron clicks can call
    /// back without OutlineSidebar (a value-type struct) holding a
    /// retain cycle on itself. Each invocation receives the H2 id that
    /// was toggled.
    func onToggleCollapsed(_ handler: @escaping (String) -> Void) {
        renderState.toggleHandler = handler
    }

    /// Hooked from `MainWindow.wireSignals` so a click on the empty-
    /// state "Add `## Heading`" link can insert a starter heading in
    /// the editor without OutlineSidebar (a value-type struct) holding
    /// a reference cycle on itself.
    func onInsertHeadingRequest(_ handler: @escaping () -> Void) {
        renderState.insertHeadingHandler = handler
    }

    /// Hooked from `MainWindow.wireSignals` for drag-to-reorder.
    /// `droppedID` is the heading the user dragged; `targetID` is the
    /// heading they dropped on (the move lands *before* the target).
    func onDropReorder(_ handler: @escaping (_ droppedID: String, _ targetID: String) -> Void) {
        renderState.dropHandler = handler
    }

    func emptyStateInsertHandler() -> (() -> Void)? {
        renderState.insertHeadingHandler
    }

    final class RenderState {
        var allHeadings: [Heading] = []
        var visible: [Heading] = []
        var query: String = ""
        var collapsed: Set<String> = []
        var activeID: String?
        var toggleHandler: ((String) -> Void)?
        var insertHeadingHandler: (() -> Void)?
        var dropHandler: ((_ droppedID: String, _ targetID: String) -> Void)?
        var treeLines: Bool = true
        var dragHandles: Bool = true
        var rows: [ListBoxRow] = []
        var rowLabels: [Label] = []
    }

    /// The Label widget for the visible row at `index`. Exposed so
    /// tests can verify Pango-markup behaviour without walking the
    /// widget tree (`children()` returns generic `Widget` borrows that
    /// don't downcast to `Label`).
    func rowLabel(at index: Int) -> Label? {
        renderState.rowLabels.indices.contains(index) ? renderState.rowLabels[index] : nil
    }
}

private extension Label {
    /// Minimal helper so the spacer width call reads at the use site.
    /// Equivalent to `setSizeRequest(width: w)`.
    func widthRequest(_ width: Int) {
        setSizeRequest(width: width)
    }
}
