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

        render(headings: [])
    }

    /// Snapshot of the most recent ``render(headings:)`` call — index
    /// into this array matches the corresponding `ListBox` row index,
    /// so a row-activation handler can look up which heading was
    /// clicked.
    var renderedHeadings: [Heading] { renderState.headings }

    func heading(at index: Int) -> Heading? {
        renderState.headings.indices.contains(index) ? renderState.headings[index] : nil
    }

    /// Refresh the panel for a new heading list. Rebuilds the rows
    /// from scratch — Phase 2 keeps the implementation simple; a
    /// row-reuse pass can land later if rebuild churn shows up in
    /// profiling.
    func render(headings: [Heading]) {
        renderState.headings = headings
        list.removeAll()
        for heading in headings {
            list.append(Self.makeRow(for: heading))
        }

        countBadge.text = "\(headings.count)"
        let h2 = headings.lazy.filter { $0.level == 2 }.count
        let h3 = headings.lazy.filter { $0.level == 3 }.count
        footerLabel.text = "\(h2) section\(h2 == 1 ? "" : "s") · \(h3) subsection\(h3 == 1 ? "" : "s")"

        if headings.isEmpty {
            emptyLabel.useMarkup = true
            emptyLabel.text = "No headings in this note. Add <tt>## Heading</tt> to start."
            emptyLabel.visible = true
            scroll.visible = false
        } else {
            emptyLabel.visible = false
            scroll.visible = true
        }
    }

    /// Set the active highlight on the row whose heading id matches.
    /// Pass `nil` to clear. Phase 3 will drive this from scroll-spy.
    func setActiveHeading(_ id: String?) {
        renderState.activeID = id
        // Phase 3 wires the CSS-class swap — for now we just remember
        // the id so the data path is testable.
    }

    /// Currently-active heading id, set by ``setActiveHeading``.
    var activeHeadingID: String? { renderState.activeID }

    private static func makeRow(for heading: Heading) -> ListBoxRow {
        let row = ListBoxRow()
        row.setAccessibleLabel(heading.text)

        let label = Label(heading.text)
        label.xalign = 0
        label.hexpand = true
        label.ellipsize = .end
        label.tooltipText = heading.text
        // Level-specific CSS classes match the design's `.sn-out-h1`,
        // `.sn-out-h2`, `.sn-out-h3` selectors. Per-level indentation is
        // applied as a Pango margin so it composes with the row's own
        // padding rather than fighting it.
        row.addCSSClass("sn-out")
        row.addCSSClass("sn-out-h\(heading.level)")
        row.marginStart = indent(for: heading.level)
        row.marginEnd = 4

        row.child = label
        return row
    }

    /// Per-level indentation in pixels. H1/H2 have no extra indent
    /// (they're "section anchors"); H3 lines up under H2 with a 22 px
    /// step, and each deeper level adds another 16 px so deeply nested
    /// H4–H6 outlines remain readable. Phase 6 will revisit visual
    /// hierarchy for H4+.
    private static func indent(for level: Int) -> Int {
        switch level {
        case ...2: 0
        case 3:    22
        default:   22 + 16 * (level - 3)
        }
    }

    private final class RenderState {
        var headings: [Heading] = []
        var activeID: String?
    }
}
