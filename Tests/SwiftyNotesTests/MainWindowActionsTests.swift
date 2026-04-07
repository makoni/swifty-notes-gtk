import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita
import CAdwaita

struct MainWindowActionsTests {
    @Test @MainActor
    func mainWindowContextMenuActionsExecuteForSelectedRowAfterSidebarRefresh() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.ContextMenu")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.present()
        window.debugCreateNote()
        #expect(window.debugNotesCount == 2)
        #expect(window.debugOverflowMenuSectionTitles == ["Library", "Help"])
        #expect(window.debugOverflowMenuItemsBySection == [
            "Library": [
                "Import markdown…",
                "Reload from disk",
                "Open notes folder"
            ],
            "Help": [
                "About Swifty Notes"
            ]
        ])

        window.debugOpenContextMenuForDisplayedNote(at: 1)
        #expect(window.debugHasContextMenu)
        #expect(window.debugNoteContextMenuLabels == [
            "Rename note…",
            "Duplicate note",
            "Export note…",
            "Copy note ID",
            "Delete…"
        ])

        let selectedStableID = window.debugSelectedNoteStableID()
        #expect(selectedStableID != nil)
        #expect(window.debugInvokeContextMenuAction(label: "Copy note ID"))
        #expect(!window.debugHasContextMenu)
        #expect(window.debugLastCopiedNoteID == selectedStableID)

        window.debugOpenContextMenuForDisplayedNote(at: 1)
        #expect(window.debugHasContextMenu)
        #expect(window.debugInvokeContextMenuAction(label: "Duplicate note"))
        #expect(!window.debugHasContextMenu)
        #expect(window.debugNotesCount == 3)
        #expect(Set(window.debugDisplayedNoteStableIDs).count == window.debugDisplayedNoteStableIDs.count)
    }

    @Test @MainActor
    func mainWindowOpenNotesFolderUsesInjectedDirectoryOpener() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.OpenNotesFolder")
        try app.register()

        let openedURL = URLRecorder()
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            directoryOpener: { url in
                await openedURL.set(url)
            }
        )

        window.debugLoadInitialNotes()
        await window.debugOpenNotesFolder()

        let recordedURL = await openedURL.snapshot()
        #expect(recordedURL?.standardizedFileURL == temp.standardizedFileURL)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: temp.path(), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test @MainActor
    func mainWindowOpenNotesFolderMenuActionUsesInjectedDirectoryOpener() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.OpenNotesFolderAction")
        try app.register()

        let openedURL = URLRecorder()
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            directoryOpener: { url in
                await openedURL.set(url)
            }
        )

        window.present()
        window.debugActivateOpenNotesFolderAction()
        try await Task.sleep(for: .milliseconds(30))

        let recordedURL = await openedURL.snapshot()
        #expect(recordedURL?.standardizedFileURL == temp.standardizedFileURL)
    }

    @Test
    func openDirectoryInSystemFileManagerUsesDefaultURIHandlerFirst() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let expectedURI = temp.standardizedFileURL.absoluteString

        var launchedURIs: [String] = []
        var fallbackURIs: [String] = []

        try await MainWindow.openDirectoryInSystemFileManager(
            temp,
            launchDefaultForURI: { uri in
                launchedURIs.append(uri)
            },
            fallbackOpenURI: { uri in
                fallbackURIs.append(uri)
            }
        )

        #expect(launchedURIs == [expectedURI])
        #expect(fallbackURIs.isEmpty)
    }

    @Test
    func openDirectoryInSystemFileManagerFallsBackToXDGOpenWhenDefaultHandlerFails() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let expectedURI = temp.standardizedFileURL.absoluteString

        var launchedURIs: [String] = []
        var fallbackURIs: [String] = []

        try await MainWindow.openDirectoryInSystemFileManager(
            temp,
            launchDefaultForURI: { uri in
                launchedURIs.append(uri)
                throw CocoaError(.fileNoSuchFile)
            },
            fallbackOpenURI: { uri in
                fallbackURIs.append(uri)
            }
        )

        #expect(launchedURIs == [expectedURI])
        #expect(fallbackURIs == [expectedURI])
    }

    @Test @MainActor
    func mainWindowAboutMenuActionPresentsAboutDialog() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.AboutDialog")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.present()
        window.debugActivateAboutAction()

        #expect(window.debugHasAboutDialog)
        #expect(window.debugAboutDialogSnapshot == .init(
            applicationName: "Swifty Notes",
            version: "Development",
            developerName: "Sergey Armodin",
            copyright: "© 2026 Sergey Armodin",
            website: "https://github.com/makoni/swifty-notes-gtk",
            issueURL: "https://github.com/makoni/swifty-notes-gtk/issues",
            comments: "A native GTK markdown notes app written in Swift using swift-adwaita."
        ))

        window.debugCloseAboutDialog()
        #expect(!window.debugHasAboutDialog)
    }

    @Test @MainActor
    func mainWindowSwitchingBetweenNotesRefreshesPreview() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let first = Note(
            id: UUID(),
            filename: "first.md",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            content: "# First\n\nOne"
        )
        let second = Note(
            id: UUID(),
            filename: "second.md",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200),
            content: "# Second\n\nTwo"
        )
        _ = try repository.save(note: first)
        _ = try repository.save(note: second)

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.SelectionSwitch")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.debugPreviewText.contains("Second"))
        #expect(window.debugPreviewText.contains("Two"))

        window.present()
        try await Task.sleep(for: .milliseconds(30))

        window.debugSelectDisplayedNote(at: 1)
        try await Task.sleep(for: .milliseconds(10))
        #expect(window.debugPreviewText.contains("First"))
        #expect(window.debugPreviewText.contains("One"))

        window.debugSelectDisplayedNote(at: 0)
        try await Task.sleep(for: .milliseconds(10))
        #expect(window.debugPreviewText.contains("Second"))
        #expect(window.debugPreviewText.contains("Two"))
    }

    @Test @MainActor
    func mainWindowSidebarSortControlReflectsAndChangesSortMode() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let alpha = Note(
            id: UUID(),
            filename: "alpha.md",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            content: "# Alpha\n"
        )
        let zeta = Note(
            id: UUID(),
            filename: "zeta.md",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200),
            content: "# Zeta\n"
        )
        _ = try repository.save(note: alpha)
        _ = try repository.save(note: zeta)

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.SortControl")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugSortMode == .newestFirst)
        #expect(window.debugSidebarSortSelection == 0)
        #expect(window.debugDisplayedNoteTitles == ["Zeta", "Alpha"])

        window.debugEmitSortButtonClicked()
        #expect(window.debugSortMode == .oldestFirst)
        #expect(window.debugSidebarSortSelection == 1)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Zeta"])

        window.debugSelectSidebarSort(at: 2)

        #expect(window.debugSortMode == .title)
        #expect(window.debugSidebarSortSelection == 2)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Zeta"])
    }
}
