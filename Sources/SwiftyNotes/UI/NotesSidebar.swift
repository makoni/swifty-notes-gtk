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

        let header = HeaderBar()
        header.titleWidget = titleLabel

        let controlsRow = Box(orientation: .horizontal, spacing: 6)
        controlsRow.append(searchEntry)
        controlsRow.append(sortButton)

        let content = Box(orientation: .vertical, spacing: 12)
        content.setMargins(12)
        content.append(controlsRow)
        content.append(scroll)
        content.append(emptyLabel)

        root = ToolbarView()
        root.addTopBar(header)
        root.content = content
        root.setAccessibleLabel("Notes Sidebar")

        sortOptionButtons = sortButtons
        setSortMode(.newestFirst)
    }

    /// Cached layout of the most recent ``render(items:...)`` call so callers
    /// can map a ListBox row index back to the underlying folder or note.
    var renderedItems: [SidebarItem] { renderState.items }

    func render(
        items: [SidebarItem],
        selectedNoteID: UUID?,
        totalCount: Int,
        searchQuery: String,
        sortMode: NotesSortMode,
    ) {
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
        }
    }

    private static func makeNoteRow(_ noteItem: SidebarNote) -> ListBoxRow {
        let row = ListBoxRow()
        row.activatable = true
        row.selectable = true
        row.setAccessibleLabel(noteItem.note.title)

        let rowBox = Box(orientation: .vertical, spacing: 2)
        rowBox.setMargins(8)
        rowBox.marginStart = 8 + indentation(forDepth: noteItem.depth)

        let title = Label(noteItem.note.title)
        title.xalign = 0
        rowBox.append(title)

        let subtitle = Label(displayDate(noteItem.note.createdAt))
        subtitle.xalign = 0
        subtitle.addCSSClass(.dimLabel)
        rowBox.append(subtitle)

        row.child = rowBox
        return row
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
        sortButton.iconName = Self.iconName(for: sortMode)
        sortButton.tooltipText = Self.tooltip(for: sortMode)
        sortButton.setAccessibleLabel(Self.accessibilityLabel(for: sortMode))
    }

    func onSortModeChanged(_ handler: @escaping @MainActor (NotesSortMode) -> Void) {
        sortButton.onClicked { [sortButton, sortState] in
            let nextMode = Self.nextSortMode(after: sortState.currentMode)
            sortState.currentMode = nextMode
            sortButton.iconName = Self.iconName(for: nextMode)
            sortButton.tooltipText = Self.tooltip(for: nextMode)
            sortButton.setAccessibleLabel(Self.accessibilityLabel(for: nextMode))
            handler(nextMode)
        }

        for (mode, button) in sortOptionButtons {
            button.onClicked { [sortPopover, sortButton, sortState] in
                sortState.currentMode = mode
                sortButton.iconName = Self.iconName(for: mode)
                sortButton.tooltipText = Self.tooltip(for: mode)
                sortButton.setAccessibleLabel(Self.accessibilityLabel(for: mode))
                sortPopover.popdown()
                handler(mode)
            }
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
