import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

@MainActor
struct SidebarTreeFlattenerTests {
    private static func note(_ title: String, in folderPath: String = "", createdAt: Date = Date()) -> Note {
        Note(
            id: UUID(),
            filename: "\(UUID().uuidString.lowercased())/note.md",
            folderPath: folderPath,
            createdAt: createdAt,
            updatedAt: createdAt,
            content: "# \(title)\n",
        )
    }

    @Test("Root only notes flatten to a flat list")
    func rootOnlyNotesFlattenToAFlatList() {
        let alpha = Self.note("Alpha", createdAt: Date(timeIntervalSince1970: 200))
        let beta = Self.note("Beta", createdAt: Date(timeIntervalSince1970: 100))

        let items = SidebarTreeFlattener.flatten(
            notes: [alpha, beta],
            folders: [],
            expandedFolders: [],
            searchQuery: "",
            sortMode: .newestFirst,
        )
        #expect(items.count == 3)
        if case let .note(first) = items[0] { #expect(first.note.id == alpha.id) }
        if case let .note(second) = items[1] { #expect(second.note.id == beta.id) }
        guard case let .trashHeader(header) = items[2] else {
            Issue.record("Expected a trailing Trash header")
            return
        }
        #expect(header.count == 0)
        #expect(header.isExpanded == false)
    }

    @Test("Folder children stay hidden until the folder is expanded")
    func folderChildrenStayHiddenUntilTheFolderIsExpanded() {
        let inside = Self.note("Inside", in: "Work")
        let items = SidebarTreeFlattener.flatten(
            notes: [inside],
            folders: ["Work"],
            expandedFolders: [],
            searchQuery: "",
            sortMode: .newestFirst,
        )
        #expect(items.count == 2)
        guard case let .folder(folder) = items[0] else {
            Issue.record("Expected a folder row")
            return
        }
        #expect(folder.path == "Work")
        #expect(folder.isExpanded == false)
        #expect(folder.hasChildren)
        #expect(folder.noteCount == 1)
        guard case let .trashHeader(header) = items[1] else {
            Issue.record("Expected a trailing Trash header")
            return
        }
        #expect(header.count == 0)
        #expect(header.isExpanded == false)
    }

    @Test("Expanded folder reveals nested folders and notes at the right depth")
    func expandedFolderRevealsNestedFoldersAndNotesAtTheRightDepth() {
        let root = Self.note("Root")
        let work = Self.note("Work Note", in: "Work")
        let project = Self.note("Project Note", in: "Work/Projects")

        let items = SidebarTreeFlattener.flatten(
            notes: [root, work, project],
            folders: ["Work", "Work/Projects"],
            expandedFolders: ["Work", "Work/Projects"],
            searchQuery: "",
            sortMode: .newestFirst,
        )

        #expect(items.count == 6)
        // Order: Work folder (depth 0), Work/Projects folder (depth 1),
        // Project Note (depth 1), Work Note (depth 0), Root note (depth 0),
        // then the always-visible Trash header.
        guard case let .folder(workFolder) = items[0] else {
            Issue.record("Expected Work folder first")
            return
        }
        #expect(workFolder.path == "Work")
        #expect(workFolder.depth == 0)
        guard case let .folder(projectsFolder) = items[1] else {
            Issue.record("Expected Projects folder second")
            return
        }
        #expect(projectsFolder.path == "Work/Projects")
        #expect(projectsFolder.depth == 1)
        guard case let .note(projectNote) = items[2] else {
            Issue.record("Expected project note third")
            return
        }
        // Project note sits inside Work/Projects (depth 1) so it indents to depth 2.
        #expect(projectNote.depth == 2)
        guard case let .note(workNote) = items[3] else {
            Issue.record("Expected work note fourth")
            return
        }
        // Work note sits inside Work (depth 0) so it indents to depth 1.
        #expect(workNote.depth == 1)
        guard case let .note(rootNote) = items[4] else {
            Issue.record("Expected root note last")
            return
        }
        #expect(rootNote.depth == 0)
        guard case let .trashHeader(header) = items[5] else {
            Issue.record("Expected Trash header after visible notes")
            return
        }
        #expect(header.count == 0)
        #expect(header.isExpanded == false)
    }

    @Test("Search collapses to flat matching notes ignoring folders")
    func searchCollapsesToFlatMatchingNotesIgnoringFolders() {
        let workNote = Self.note("Find me", in: "Work")
        let other = Self.note("Skip", in: "Personal")

        let items = SidebarTreeFlattener.flatten(
            notes: [workNote, other],
            folders: ["Work", "Personal"],
            expandedFolders: ["Work"],
            searchQuery: "find",
            sortMode: .newestFirst,
        )
        #expect(items.count == 1)
        if case let .note(noteItem) = items[0] {
            #expect(noteItem.note.id == workNote.id)
            #expect(noteItem.depth == 0)
        }
    }

    @Test("Drag payload round trips through string encoding")
    func dragPayloadRoundTripsThroughStringEncoding() throws {
        let noteID = UUID()
        let notePayload = SidebarDragPayload.note(noteID)
        let folderPayload = SidebarDragPayload.folder(path: "Work/Drafts")

        guard case let .note(decodedID) = SidebarDragPayload.parse(notePayload.encoded) else {
            Issue.record("Note payload failed to round-trip")
            return
        }
        #expect(decodedID == noteID)

        guard case let .folder(decodedPath) = SidebarDragPayload.parse(folderPayload.encoded) else {
            Issue.record("Folder payload failed to round-trip")
            return
        }
        #expect(decodedPath == "Work/Drafts")
    }

    @Test("Drag payload rejects unrelated text drops")
    func dragPayloadRejectsUnrelatedTextDrops() {
        #expect(SidebarDragPayload.parse("https://example.com") == nil)
        #expect(SidebarDragPayload.parse("swiftynotes/note/not-a-uuid") == nil)
    }

    @Test("Sidebar title label layout truncates with an ellipsis on a single line and keeps the full title in the tooltip")
    func sidebarTitleLabelLayoutTruncatesWithAnEllipsisOnASingleLine() {
        let longTitle = String(repeating: "Very long heading ", count: 12)
        let note = Self.note(longTitle)
        let layout = NotesSidebar.titleLabelLayout(for: note)
        // note.title applies its own 80-char trim before we ever see it,
        // so the layout text and tooltip both reflect the displayed title.
        #expect(layout.text == note.title)
        #expect(layout.tooltipText == note.title)
        #expect(layout.ellipsize == PANGO_ELLIPSIZE_END)
        #expect(layout.lines == 1)
        #expect(layout.wrap == false)
    }

    @Test("Empty folders still surface as collapsed rows so the user can rename or delete them")
    func emptyFoldersStillSurfaceAsCollapsedRowsSoTheUserCanRename() {
        let items = SidebarTreeFlattener.flatten(
            notes: [],
            folders: ["Work"],
            expandedFolders: [],
            searchQuery: "",
            sortMode: .newestFirst,
        )
        #expect(items.count == 2)
        if case let .folder(folder) = items[0] {
            #expect(folder.path == "Work")
            #expect(folder.hasChildren == false)
            #expect(folder.noteCount == 0)
        }
        guard case let .trashHeader(header) = items[1] else {
            Issue.record("Expected a trailing Trash header")
            return
        }
        #expect(header.count == 0)
        #expect(header.isExpanded == false)
    }
}
