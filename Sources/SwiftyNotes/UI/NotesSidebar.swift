import Adwaita
import Foundation

@MainActor
struct NotesSidebar {
    let root: ToolbarView
    let list: ListBox
    let titleLabel: Label
    let searchEntry: SearchEntry

    private let emptyLabel: Label

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

        emptyLabel = Label("No notes yet.")
        emptyLabel.wrap = true
        emptyLabel.xalign = 0
        emptyLabel.addCSSClass(.dimLabel)

        let header = HeaderBar()
        header.titleWidget = titleLabel

        let content = Box(orientation: .vertical, spacing: 12)
        content.setMargins(12)
        content.append(searchEntry)
        content.append(scroll)
        content.append(emptyLabel)

        root = ToolbarView()
        root.addTopBar(header)
        root.content = content
    }

    func render(notes: [Note], selectedID: UUID?, totalCount: Int, searchQuery: String) {
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

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
