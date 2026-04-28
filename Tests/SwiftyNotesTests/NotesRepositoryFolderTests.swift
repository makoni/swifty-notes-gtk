import Foundation
@testable import SwiftyNotes
import Testing

struct NotesRepositoryFolderTests {
    private static func makeRepository() -> (NotesRepository, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (NotesRepository(notesDirectory: directory), directory)
    }

    @Test
    func `loadNotes finds notes nested across folders and reports their folder paths`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try repository.createNote(initialContent: "root")
        try repository.createFolder(at: "Work")
        try repository.createFolder(at: "Work/Projects")
        let work = try repository.createNote(initialContent: "work", in: "Work")
        let project = try repository.createNote(initialContent: "project", in: "Work/Projects")

        let notes = try repository.loadNotes().sorted { $0.content < $1.content }
        #expect(notes.count == 3)
        #expect(notes.map(\.id).contains(root.id))
        let folders = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.folderPath) })
        #expect(folders[root.id] == "")
        #expect(folders[work.id] == "Work")
        #expect(folders[project.id] == "Work/Projects")
    }

    @Test
    func `listFolders returns every folder including empty ones`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Work")
        try repository.createFolder(at: "Work/Active")
        try repository.createFolder(at: "Personal")

        let folders = try repository.listFolders()
        #expect(folders == ["Personal", "Work", "Work/Active"])
    }

    @Test
    func `creating a folder twice fails with alreadyExists`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Work")
        #expect(throws: NotesRepositoryFolderError.alreadyExists("Work")) {
            try repository.createFolder(at: "Work")
        }
    }

    @Test
    func `creating a folder with empty or invalid name throws invalidName`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: NotesRepositoryFolderError.invalidName("")) {
            try repository.createFolder(at: "")
        }
        #expect(throws: NotesRepositoryFolderError.self) {
            try repository.createFolder(at: "Work/../Hack")
        }
    }

    @Test
    func `renameFolder moves the directory and keeps notes loadable`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Old")
        let note = try repository.createNote(initialContent: "x", in: "Old")

        try repository.renameFolder(at: "Old", to: "New")
        let notes = try repository.loadNotes()
        #expect(notes.first?.id == note.id)
        #expect(notes.first?.folderPath == "New")
    }

    @Test
    func `renameFolder rejects a name that conflicts with an existing sibling`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "A")
        try repository.createFolder(at: "B")

        #expect(throws: NotesRepositoryFolderError.alreadyExists("B")) {
            try repository.renameFolder(at: "A", to: "B")
        }
    }

    @Test
    func `deleteFolderRecursively removes nested notes and folders`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Top")
        try repository.createFolder(at: "Top/Inner")
        _ = try repository.createNote(initialContent: "x", in: "Top")
        _ = try repository.createNote(initialContent: "y", in: "Top/Inner")
        let outsider = try repository.createNote(initialContent: "outside")

        try repository.deleteFolderRecursively(at: "Top")
        let remaining = try repository.loadNotes()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == outsider.id)
        #expect(try repository.listFolders().isEmpty)
    }

    @Test
    func `move note relocates it on disk and preserves its identity`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Inbox")
        let note = try repository.createNote(initialContent: "hi")

        let moved = try repository.move(note: note, to: "Inbox")
        #expect(moved.id == note.id)
        #expect(moved.folderPath == "Inbox")

        let onDisk = try repository.loadNotes().first
        #expect(onDisk?.folderPath == "Inbox")
    }

    @Test
    func `move folder rejects placing it inside its own descendant`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Outer")
        try repository.createFolder(at: "Outer/Inner")

        #expect(throws: NotesRepositoryFolderError.wouldNestInsideSelf(source: "Outer", destination: "Outer/Inner")) {
            try repository.moveFolder(at: "Outer", to: "Outer/Inner")
        }
    }

    @Test
    func `moveFolder relocates folder under a new parent`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "A")
        try repository.createFolder(at: "B")
        let note = try repository.createNote(initialContent: "n", in: "A")

        try repository.moveFolder(at: "A", to: "B")
        let folders = try repository.listFolders()
        #expect(folders.contains("B/A"))
        #expect(!folders.contains("A"))

        let loaded = try repository.loadNotes()
        #expect(loaded.first?.id == note.id)
        #expect(loaded.first?.folderPath == "B/A")
    }

    @Test
    func `creating a note in a missing folder throws notFound`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: NotesRepositoryFolderError.notFound("Ghost")) {
            _ = try repository.createNote(initialContent: "x", in: "Ghost")
        }
    }

    @Test
    func `directorySnapshot filename includes the folder path so cross folder collisions are visible`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try repository.createNote(initialContent: "root")
        try repository.createFolder(at: "Inbox")
        _ = try repository.createNote(initialContent: "deep", in: "Inbox")

        let snapshot = try repository.directorySnapshot()
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries.contains { $0.filename.hasPrefix("Inbox/") })
        #expect(snapshot.entries.contains { !$0.filename.contains("/") })
    }

    @Test
    func `createFolder rejects a path that traverses an existing note directory`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Work")
        let note = try repository.createNote(initialContent: "x", in: "Work")
        let noteDirectoryName = (note.filename as NSString).deletingLastPathComponent

        // Trying to create a subfolder inside the note's UUID directory must
        // fail — placing anything under <folder>/<UUID>/ produces orphan
        // content the walker never finds because the walker stops at any
        // directory that contains a note.md.
        let target = "Work/\(noteDirectoryName)/Sub"
        #expect(throws: NotesRepositoryFolderError.self) {
            try repository.createFolder(at: target)
        }
    }

    @Test
    func `move note rejects a destination folder that is itself a note directory`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Work")
        let host = try repository.createNote(initialContent: "host", in: "Work")
        let stranger = try repository.createNote(initialContent: "stranger", in: "Work")
        let hostDirectoryName = (host.filename as NSString).deletingLastPathComponent
        let noteDirectoryPath = "Work/\(hostDirectoryName)"

        #expect(throws: NotesRepositoryFolderError.self) {
            _ = try repository.move(note: stranger, to: noteDirectoryPath)
        }
    }

    @Test
    func `createNote rejects a folder path that lives inside an existing note directory`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Work")
        let host = try repository.createNote(initialContent: "host", in: "Work")
        let hostDirectoryName = (host.filename as NSString).deletingLastPathComponent

        // Pre-create the rogue subfolder on disk (simulating a manual mkdir
        // or a CLI bypass) so ensureFolderExists passes and we exercise the
        // ancestor-check path.
        let rogue = directory
            .appendingPathComponent("Work", isDirectory: true)
            .appendingPathComponent(hostDirectoryName, isDirectory: true)
            .appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: rogue, withIntermediateDirectories: true)

        #expect(throws: NotesRepositoryFolderError.self) {
            _ = try repository.createNote(initialContent: "stranger", in: "Work/\(hostDirectoryName)/Sub")
        }
    }

    @Test
    func `validation rejects names containing path separators`() throws {
        let (repository, directory) = Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }

        try repository.createFolder(at: "Source")
        #expect(throws: NotesRepositoryFolderError.self) {
            try repository.renameFolder(at: "Source", to: "evil/name")
        }
    }
}
