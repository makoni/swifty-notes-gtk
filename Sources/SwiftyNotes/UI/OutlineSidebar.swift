import Adwaita
import Foundation

/// The right-hand Outline panel — a Table-of-Contents view of the
/// active note's headings. Phase 1 ships the widget shell only; the
/// surrounding phases wire heading rendering, scroll-spy, search,
/// collapse, and Ctrl+G integration.
@MainActor
struct OutlineSidebar {
    let root: ToolbarView
    let list: ListBox
    let searchEntry: SearchEntry
    let countBadge: Label
    let emptyLabel: Label
    let footerLabel: Label

    private let scroll: ScrolledWindow

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
        // Mirror NotesSidebar's macOS jitter workaround for inertial
        // trackpad input layered over GTK's Quartz scroll fade-in.
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

        // No AdwHeaderBar on the Outline panel — the design places the
        // title inline with the content (matching the NotesSidebar macOS
        // shape and the design's `.sn-outline-head` spec), and adding a
        // second AdwHeaderBar on the right column risks the same
        // NSWindow traffic-light reshuffle that NotesSidebar avoids.
        root = ToolbarView()
        root.content = content
        root.setAccessibleLabel("Outline Sidebar")

        render(headings: [])
    }

    /// Refreshes the count badge, footer summary, and empty-state
    /// visibility. Heading-row population lands in Phase 2 — for now
    /// we just keep the chrome in sync with the count.
    func render(headings: [Heading]) {
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
}
