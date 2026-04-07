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

    private static let sortModes = NotesSortMode.allCases

    private final class SortState {
        var currentMode: NotesSortMode = .newestFirst
    }

    init() {
        list = ListBox()
        list.selectionMode = .single
        list.activateOnSingleClick = true
        list.addCSSClass("navigation-sidebar")

        let scroll = ScrolledWindow(child: list)
        scroll.setPolicy(horizontal: .never, vertical: .automatic)
        scroll.vexpand = true

        titleLabel = Label("Notes")
        titleLabel.addCSSClass("heading")

        searchEntry = SearchEntry()
        searchEntry.placeholderText = "Search notes"
        searchEntry.searchDelay = 120
        searchEntry.hexpand = true

        sortButton = SplitButton()
        sortButton.canShrink = true
        sortButton.dropdownTooltip = "Sort Notes"
        sortButton.direction = .down

        sortPopover = Popover()
        sortState = SortState()

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

        sortOptionButtons = sortButtons
        setSortMode(.newestFirst)
    }

    func render(notes: [Note], selectedID: UUID?, totalCount: Int, searchQuery: String, sortMode: NotesSortMode) {
        setSortMode(sortMode)
        list.removeAll()
        for (index, note) in notes.enumerated() {
            let row = ListBoxRow()
            row.activatable = true
            row.selectable = true

            let rowBox = Box(orientation: .vertical, spacing: 2)
            rowBox.setMargins(8)

            let title = Label(note.title)
            title.xalign = 0
            rowBox.append(title)

            let subtitle = Label(Self.displayDate(note.createdAt))
            subtitle.xalign = 0
            subtitle.addCSSClass(.dimLabel)
            rowBox.append(subtitle)

            row.child = rowBox
            list.append(row)
            if note.id == selectedID {
                list.selectRow(at: index)
            }
        }

        if totalCount == 0 {
            titleLabel.text = "Notes"
            emptyLabel.text = "No notes yet. Create one with +."
        } else if notes.isEmpty {
            titleLabel.text = "Notes"
            emptyLabel.text = "No notes match “\(searchQuery)”."
        } else {
            titleLabel.text = searchQuery.isEmpty ? "Notes (\(totalCount))" : "Notes (\(notes.count)/\(totalCount))"
        }
        emptyLabel.visible = notes.isEmpty
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

    private static func displayDate(_ date: Date) -> String {
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
