import Adwaita
import Foundation

@MainActor
struct NotesSidebar {
    let root: ToolbarView
    let list: ListBox
    let titleLabel: Label
    let searchEntry: SearchEntry
    let sortButton: SplitButton

    private let emptyLabel: Label
    private let sortPopover: Popover
    private let sortOptionButtons: [NotesSortMode: Button]
    private let sortState: SortState
    private let renderState: RenderState

    private static let sortModes = NotesSortMode.allCases

    private final class SortState {
        var currentMode: NotesSortMode = .newestFirst
    }

    private final class RenderState {
        var items: [SidebarItem] = []
#if DEBUG
        var renderCount = 0
#endif
    }

    init() {
        list = ListBox()
        list.selectionMode = .single
        list.activateOnSingleClick = true
        list.addCSSClass("navigation-sidebar")
        list.setAccessibleLabel("Notes List")

        let scroll = ScrolledWindow(child: list)
        scroll.setPolicy(horizontal: .never, vertical: .automatic)
        scroll.vexpand = true
        #if os(macOS)
        // GTK4 on Quartz stacks overlay scrollbar fade-in reallocations on
        // top of macOS's own inertial trackpad input, producing visibly
        // jittery sidebar scrolling. Linux mice / Wayland compositors don't
        // hit either codepath the same way, so this stays macOS-only.
        scroll.overlayScrolling = false
        scroll.kineticScrolling = false
        #endif

        titleLabel = Label("Notes")
        titleLabel.addCSSClass("heading")

        searchEntry = SearchEntry()
        searchEntry.placeholderText = "Search notes"
        searchEntry.searchDelay = 120
        searchEntry.hexpand = true
        searchEntry.setAccessibleLabel("Search Notes")

        sortButton = SplitButton()
        sortButton.canShrink = true
        sortButton.dropdownTooltip = "Sort Notes"
        sortButton.direction = .down

        sortPopover = Popover()
        sortState = SortState()
        renderState = RenderState()

        var sortButtons: [NotesSortMode: Button] = [:]
        let sortMenuBox = Box(orientation: .vertical, spacing: 2)
        sortMenuBox.setMargins(4)
        for mode in Self.sortModes {
            let button = Self.makeSortOptionButton(for: mode)
            sortMenuBox.append(button)
            sortButtons[mode] = button
        }
        sortPopover.child = sortMenuBox
        sortButton.setPopover(sortPopover)

        emptyLabel = Label("No notes yet.")
        emptyLabel.wrap = true
        emptyLabel.xalign = 0
        emptyLabel.addCSSClass(.dimLabel)

        // On macOS the sidebar deliberately does NOT get an AdwHeaderBar.
        // Each AdwHeaderBar instance internally creates a GtkWindowControls
        // with `use_native_controls = TRUE`, which spawns a
        // GtkWindowButtonsQuartz widget whose size-allocate calls
        // `setTitlebarHeight:` on the underlying NSWindow with the widget's
        // own Y coordinate. With two AdwHeaderBars stacked vertically
        // (main + sidebar), the lower one wins the setTitlebarHeight race,
        // pulling the native macOS traffic lights down into the sidebar
        // pane instead of the window-level toolbar where macOS conventions
        // place them. By skipping `root.addTopBar(header)` on macOS we
        // leave only MainWindow's HeaderBar to own the native controls,
        // and the traffic lights settle at the absolute top-left of the
        // window — the natural macOS position.
        //
        // The "Notes (N)" title + sort SplitButton that normally sit in
        // the AdwHeaderBar move into a row at the top of the sidebar's
        // content area, with the search entry on its own row below. This
        // matches the typical macOS sidebar pattern (Notes.app, Mail.app,
        // Finder) where the sidebar has no per-pane title chrome — just
        // a section header inline with the content.
        let controlsRow = Box(orientation: .horizontal, spacing: 6)
        controlsRow.append(searchEntry)
        #if !os(macOS)
        // On Linux the sort SplitButton sits next to the search entry on
        // the same row because the title lives in the HeaderBar above.
        // On macOS it instead pairs with the title in `titleRow` below
        // to keep the search row clean and full-width.
        controlsRow.append(sortButton)
        #endif

        let content = Box(orientation: .vertical, spacing: 12)
        content.setMargins(12)

        #if os(macOS)
        // macOS replacement for the AdwHeaderBar's titleWidget: an
        // inline horizontal row with the "Notes" label hugging the
        // start and the sort SplitButton hugging the end.
        let titleRow = Box(orientation: .horizontal, spacing: 6)
        titleLabel.hexpand = true
        titleLabel.xalign = 0   // left-align the label text
        titleRow.append(titleLabel)
        titleRow.append(sortButton)
        content.append(titleRow)
        #endif

        content.append(controlsRow)
        content.append(scroll)
        content.append(emptyLabel)

        root = ToolbarView()
        #if !os(macOS)
        // Linux only: keep the original libadwaita HeaderBar with the
        // title widget centred. On macOS the title widget already lives
        // inside `content` (see `titleRow` above), so no top bar at all.
        let header = HeaderBar()
        header.titleWidget = titleLabel
        root.addTopBar(header)
        #endif
        root.content = content
        root.setAccessibleLabel("Notes Sidebar")

        sortOptionButtons = sortButtons
        setSortMode(.newestFirst)
    }

    /// Cached layout of the most recent ``render(items:...)`` call so callers
    /// can map a ListBox row index back to the underlying folder or note.
    var renderedItems: [SidebarItem] { renderState.items }

#if DEBUG
    var debugRenderCount: Int { renderState.renderCount }
#endif

    func render(
        items: [SidebarItem],
        selectedNoteID: UUID?,
        totalCount: Int,
        searchQuery: String,
        sortMode: NotesSortMode,
    ) {
#if DEBUG
        renderState.renderCount += 1
#endif
        setSortMode(sortMode)
        list.removeAll()
        renderState.items = items

        for (index, item) in items.enumerated() {
            let row = Self.makeRow(for: item)
            list.append(row)
            if case let .note(noteItem) = item, noteItem.note.id == selectedNoteID {
                list.selectRow(at: index)
            }
        }

        let visibleNoteCount = items.reduce(into: 0) { count, item in
            if case .note = item { count += 1 }
        }

        if totalCount == 0 {
            titleLabel.text = "Notes"
            emptyLabel.text = "No notes yet. Create one with +."
        } else if visibleNoteCount == 0 && items.isEmpty {
            titleLabel.text = "Notes"
            emptyLabel.text = "No notes match “\(searchQuery)”."
        } else {
            titleLabel.text = searchQuery.isEmpty
                ? "Notes (\(totalCount))"
                : "Notes (\(visibleNoteCount)/\(totalCount))"
        }
        emptyLabel.visible = items.isEmpty
    }

    func item(at index: Int) -> SidebarItem? {
        renderState.items.indices.contains(index) ? renderState.items[index] : nil
    }

    /// Index of the row that represents the given note, or `nil` if the
    /// note is not currently visible (e.g. its folder is collapsed).
    func indexOfNote(id: UUID) -> Int? {
        renderState.items.firstIndex { item in
            if case let .note(noteItem) = item { return noteItem.note.id == id }
            return false
        }
    }

    private static func makeRow(for item: SidebarItem) -> ListBoxRow {
        switch item {
        case let .folder(folder):
            makeFolderRow(folder)
        case let .note(noteItem):
            makeNoteRow(noteItem)
        case let .trashHeader(header):
            makeTrashHeaderRow(header)
        case let .trashedNote(trashedNote):
            makeTrashedNoteRow(trashedNote)
        }
    }

    private static func makeTrashHeaderRow(_ header: SidebarTrashHeader) -> ListBoxRow {
        let row = ListBoxRow()
        row.activatable = true
        row.selectable = false
        row.setAccessibleLabel("Trash")
        row.addCSSClass("dim-label")

        let rowBox = Box(orientation: .horizontal, spacing: 6)
        rowBox.setMargins(6)
        rowBox.marginStart = 6

        let chevron = Image(iconName: header.isExpanded
            ? "pan-down-symbolic"
            : "pan-end-symbolic")
        chevron.pixelSize = 12
        rowBox.append(chevron)

        let icon = Image(iconName: "user-trash-symbolic")
        icon.pixelSize = 14
        rowBox.append(icon)

        let title = Label("Trash")
        title.xalign = 0
        title.hexpand = true
        rowBox.append(title)

        let badge = Label("\(header.count)")
        badge.addCSSClass(.dimLabel)
        badge.addCSSClass(.caption)
        rowBox.append(badge)

        row.child = rowBox
        return row
    }

    private static func makeTrashedNoteRow(_ trashedNote: SidebarTrashedNote) -> ListBoxRow {
        let row = ListBoxRow()
        row.activatable = true
        row.selectable = true
        row.setAccessibleLabel(trashedNote.note.title)

        let rowBox = Box(orientation: .vertical, spacing: 2)
        rowBox.setMargins(8)
        rowBox.marginStart = 8 + indentation(forDepth: 1)

        rowBox.append(makeTitleLabel(for: trashedNote.note))

        let subtitle = Label(trashedNoteSubtitle(for: trashedNote.note))
        subtitle.xalign = 0
        subtitle.addCSSClass(.dimLabel)
        rowBox.append(subtitle)

        row.child = rowBox
        row.opacity = 0.7
        return row
    }

    private static func trashedNoteSubtitle(for note: Note) -> String {
        guard let deletedAt = note.deletedAt else {
            return "Deleted"
        }
        return "Deleted \(displayDate(deletedAt))"
    }

    private static func makeNoteRow(_ noteItem: SidebarNote) -> ListBoxRow {
        let row = ListBoxRow()
        row.activatable = true
        row.selectable = true
        row.setAccessibleLabel(noteItem.note.title)

        let rowBox = Box(orientation: .vertical, spacing: 2)
        rowBox.setMargins(8)
        rowBox.marginStart = 8 + indentation(forDepth: noteItem.depth)

        rowBox.append(makeTitleLabel(for: noteItem.note))

        let subtitle = Label(displayDate(noteItem.note.createdAt))
        subtitle.xalign = 0
        subtitle.addCSSClass(.dimLabel)
        rowBox.append(subtitle)

        row.child = rowBox
        return row
    }

    /// Layout used by the title label of every note row.
    ///
    /// Pulled out as a plain value so tests can assert the layout without
    /// needing a GTK display — the headless test suite shouldn't construct
    /// widgets, which would require `gtk_init`.
    struct TitleLabelLayout: Equatable {
        let text: String
        let tooltipText: String
        let ellipsize: PangoEllipsizeMode
        let wrap: Bool
        let lines: Int
    }

    /// Settings for a note's title label. Long titles truncate to a single
    /// line with a trailing ellipsis instead of wrapping, so a long heading
    /// never grows the sidebar's row height or its overall width. The full
    /// title is preserved in the tooltip.
    static func titleLabelLayout(for note: Note) -> TitleLabelLayout {
        TitleLabelLayout(
            text: note.title,
            tooltipText: note.title,
            ellipsize: PANGO_ELLIPSIZE_END,
            wrap: false,
            lines: 1,
        )
    }

    /// Builds the title `Label` for a note row in the sidebar by applying
    /// ``titleLabelLayout(for:)`` to a fresh `Label`.
    static func makeTitleLabel(for note: Note) -> Label {
        let layout = titleLabelLayout(for: note)
        let title = Label(layout.text)
        title.xalign = 0
        title.ellipsize = layout.ellipsize
        title.lines = layout.lines
        title.wrap = layout.wrap
        title.tooltipText = layout.tooltipText
        return title
    }

    private static func makeFolderRow(_ folder: SidebarFolder) -> ListBoxRow {
        let row = ListBoxRow()
        row.activatable = true
        row.selectable = false
        row.setAccessibleLabel("Folder \(folder.path)")
        row.addCSSClass("dim-label")

        let rowBox = Box(orientation: .horizontal, spacing: 6)
        rowBox.setMargins(6)
        rowBox.marginStart = 6 + indentation(forDepth: folder.depth)

        let chevron = Image(iconName: folder.isExpanded
            ? "pan-down-symbolic"
            : "pan-end-symbolic")
        chevron.pixelSize = 12
        if !folder.hasChildren {
            chevron.opacity = 0.35
        }
        rowBox.append(chevron)

        let folderIcon = Image(iconName: "folder-symbolic")
        folderIcon.pixelSize = 14
        rowBox.append(folderIcon)

        let title = Label(folder.displayName)
        title.xalign = 0
        title.hexpand = true
        rowBox.append(title)

        if folder.noteCount > 0 {
            let badge = Label("\(folder.noteCount)")
            badge.addCSSClass(.dimLabel)
            badge.addCSSClass(.caption)
            rowBox.append(badge)
        }

        row.child = rowBox
        return row
    }

    private static func indentation(forDepth depth: Int) -> Int {
        depth * 14
    }

    func setSortMode(_ sortMode: NotesSortMode) {
        sortState.currentMode = sortMode
        Self.applyIcon(named: Self.iconName(for: sortMode), to: sortButton)
        sortButton.tooltipText = Self.tooltip(for: sortMode)
        sortButton.setAccessibleLabel(Self.accessibilityLabel(for: sortMode))
    }

    func onSortModeChanged(_ handler: @escaping @MainActor (NotesSortMode) -> Void) {
        sortButton.onClicked { [sortButton, sortState] in
            let nextMode = Self.nextSortMode(after: sortState.currentMode)
            sortState.currentMode = nextMode
            Self.applyIcon(named: Self.iconName(for: nextMode), to: sortButton)
            sortButton.tooltipText = Self.tooltip(for: nextMode)
            sortButton.setAccessibleLabel(Self.accessibilityLabel(for: nextMode))
            handler(nextMode)
        }

        for (mode, button) in sortOptionButtons {
            button.onClicked { [sortPopover, sortButton, sortState] in
                sortState.currentMode = mode
                Self.applyIcon(named: Self.iconName(for: mode), to: sortButton)
                sortButton.tooltipText = Self.tooltip(for: mode)
                sortButton.setAccessibleLabel(Self.accessibilityLabel(for: mode))
                sortPopover.popdown()
                handler(mode)
            }
        }
    }

    /// Sets the icon shown on the sort SplitButton, preferring a bundled
    /// SVG from `Sources/SwiftyNotes/Icons/` over the system Adwaita
    /// theme. Same workaround as ``MainWindow/iconButton(named:)`` — see
    /// the comment there for why bundled-first is necessary on macOS
    /// Quartz (GtkSymbolicPaintable drops `<g>` group elements that
    /// Adwaita-icon-theme 50.0 uses for the sort/font icons). `SplitButton`
    /// doesn't take a Button-style init parameter for its icon, so the
    /// logic lives here as a static helper rather than feeding through
    /// the MainWindow factory.
    private static func applyIcon(named iconName: String, to button: SplitButton) {
        if let bundledPath = MainWindow.bundledIconFilePath(for: iconName) {
            let image = Image(filename: bundledPath)
            image.pixelSize = 16
            button.child = image
        } else {
            // Clear any previously set custom child so the icon-name path
            // becomes the active rendering source again. Without this,
            // SplitButton continues to display the stale child widget and
            // ignores the new iconName.
            button.child = nil
            button.iconName = iconName
        }
    }

    var selectedSortIndex: Int {
        Self.sortModes.firstIndex(of: sortState.currentMode) ?? 0
    }

    static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func iconName(for mode: NotesSortMode) -> String {
        switch mode {
        case .newestFirst:
            "view-sort-descending-symbolic"
        case .oldestFirst:
            "view-sort-ascending-symbolic"
        case .title:
            "font-select-symbolic"
        }
    }

    private static func tooltip(for mode: NotesSortMode) -> String {
        switch mode {
        case .newestFirst:
            "Newest First"
        case .oldestFirst:
            "Oldest First"
        case .title:
            "Sort by Title"
        }
    }

    private static func accessibilityLabel(for mode: NotesSortMode) -> String {
        switch mode {
        case .newestFirst:
            "Sort Notes by Newest First"
        case .oldestFirst:
            "Sort Notes by Oldest First"
        case .title:
            "Sort Notes by Title"
        }
    }

    private static func nextSortMode(after mode: NotesSortMode) -> NotesSortMode {
        let currentIndex = sortModes.firstIndex(of: mode) ?? 0
        let nextIndex = sortModes.index(after: currentIndex)
        return nextIndex < sortModes.endIndex ? sortModes[nextIndex] : sortModes[sortModes.startIndex]
    }

    private static func makeSortOptionButton(for mode: NotesSortMode) -> Button {
        let button = Button()
        let row = Box(orientation: .horizontal, spacing: 8)
        row.hexpand = true
        row.halign = .fill

        let icon = Image(iconName: iconName(for: mode))
        icon.halign = .start
        row.append(icon)

        let label = Label(mode.displayName)
        label.xalign = 0
        label.hexpand = true
        row.append(label)

        button.child = row
        button.addCSSClass("flat")
        button.halign = .fill
        button.hexpand = true
        return button
    }
}
