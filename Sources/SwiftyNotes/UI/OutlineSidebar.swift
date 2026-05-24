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

        renderState = RenderState()

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
    func setActiveHeading(_ id: String?) {
        renderState.activeID = id
        // Phase 3 wires the visual highlight by re-applying CSS classes
        // on the relevant row. The render path always honors the current
        // activeID, so a full rerender on activation change is the
        // simplest correct path — heading lists are short (dozens of
        // entries) so the cost is negligible.
        rerender()
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

        list.removeAll()
        for heading in visible {
            list.append(makeRow(for: heading))
        }

        let isQuery = !renderState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if renderState.allHeadings.isEmpty {
            emptyLabel.useMarkup = true
            emptyLabel.text = "No headings in this note. Add <tt>## Heading</tt> to start."
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

    private func makeRow(for heading: Heading) -> ListBoxRow {
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
        // turn into entity-escape territory.
        let trimmedQuery = renderState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            label.useMarkup = false
            label.text = heading.text
        } else {
            label.useMarkup = true
            label.text = Self.highlightedMarkup(heading.text, query: trimmedQuery)
        }

        row.addCSSClass("sn-out")
        row.addCSSClass("sn-out-h\(heading.level)")
        if heading.id == renderState.activeID {
            row.addCSSClass("is-active")
        }
        row.marginEnd = 4

        // H2 rows lead with a chevron that toggles their collapse state
        // (only when they have at least one H3+ child below them). H3+
        // rows lead with a rail-width spacer so the H2 / H3 columns line
        // up regardless of whether the chevron is present.
        let leadingContainer = Box(orientation: .horizontal, spacing: 4)
        leadingContainer.marginStart = indent(for: heading.level)
        leadingContainer.marginEnd = 4
        if heading.level == 2, hasChildren(of: heading) {
            let chevron = Button(icon: .custom(renderState.collapsed.contains(heading.id) ? "pan-end-symbolic" : "pan-down-symbolic"))
            chevron.addCSSClass(.flat)
            chevron.tooltipText = renderState.collapsed.contains(heading.id) ? "Expand section" : "Collapse section"
            MacOSClickWorkaround.onClick(chevron, label: "OutlineChevron") { [weak rs = renderState, id = heading.id] in
                // We can't safely capture `self` (struct) from a long-
                // lived closure, but the renderState class is the
                // single source of truth — toggle through it directly.
                guard let rs else { return }
                rs.toggleHandler?(id)
            }
            leadingContainer.append(chevron)
        } else {
            // 16 px spacer to keep H2-without-children and H3+ rows
            // aligned with H2-with-children siblings.
            let spacer = Label("")
            spacer.widthRequest(16)
            leadingContainer.append(spacer)
        }
        leadingContainer.append(label)

        row.child = leadingContainer
        return row
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
            return Self.escapeMarkup(text)
        }
        let pre = String(text[..<range.lowerBound])
        let hit = String(text[range])
        let post = String(text[range.upperBound...])
        return "\(Self.escapeMarkup(pre))<span background=\"#f5c211\" foreground=\"#1e1e1e\">\(Self.escapeMarkup(hit))</span>\(Self.escapeMarkup(post))"
    }

    /// Pango entity escape — same five entities the swift-adwaita
    /// preview's HTML builder uses (see ``MarkdownRendererHTMLBuilder``).
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

    // MARK: — Internal handler hook

    /// Wired by `MainWindow.wireSignals` so chevron clicks can call
    /// back without OutlineSidebar (a value-type struct) holding a
    /// retain cycle on itself. Each invocation receives the H2 id that
    /// was toggled.
    func onToggleCollapsed(_ handler: @escaping (String) -> Void) {
        renderState.toggleHandler = handler
    }

    final class RenderState {
        var allHeadings: [Heading] = []
        var visible: [Heading] = []
        var query: String = ""
        var collapsed: Set<String> = []
        var activeID: String?
        var toggleHandler: ((String) -> Void)?
    }
}

private extension Label {
    /// Minimal helper so the spacer width call reads at the use site.
    /// Equivalent to `setSizeRequest(width: w)`.
    func widthRequest(_ width: Int) {
        setSizeRequest(width: width)
    }
}
