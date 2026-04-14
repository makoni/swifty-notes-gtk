import Adwaita
import Foundation
import Glibc

@MainActor
private final class AppController {
    private let stateStore = WorkspaceStateStore()
    private let appSettingsStore = AppSettingsStore()
    private var mainWindow: MainWindow?
    private var externalDocumentWindows: [ObjectIdentifier: ExternalDocumentWindow] = [:]

    func activate(app: Application) {
        if let mainWindow {
            mainWindow.present()
            return
        }

        let workspaceState = (try? stateStore.load()) ?? .default
        let appSettings = currentAppSettings()
        let window = MainWindow(
            application: app,
            state: AppState(persistedState: workspaceState),
            stateStore: stateStore,
            repository: NotesRepository(
                notesDirectory: appSettings.resolvedNotesDirectory()
            ),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: appSettingsStore,
            appSettings: appSettings,
            openExternalDocumentHandler: { [weak self, weak app] fileURL in
                guard let self, let app else { return }
                try self.openExternalDocument(at: fileURL, application: app)
            }
        )
        window.window.onDestroy { [weak self] in
            self?.releaseMainWindow()
        }
        mainWindow = window
        window.present()
    }

    func releaseMainWindow() {
        mainWindow = nil
    }

    private func currentAppSettings() -> AppSettings {
        (try? appSettingsStore.load()) ?? .default
    }

    private func openExternalDocument(at fileURL: URL, application: Application) throws {
        let standardizedURL = fileURL.standardizedFileURL
        if let existingWindow = externalDocumentWindows.values.first(where: { $0.fileURL == standardizedURL }) {
            existingWindow.present()
            return
        }

        let externalWindow = try ExternalDocumentWindow(
            application: application,
            fileURL: standardizedURL,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettings: currentAppSettings(),
            importIntoLibrary: { [weak self] fileURL in
                guard let self else { throw CocoaError(.userCancelled) }
                return try self.importExternalDocumentIntoLibrary(from: fileURL)
            }
        )
        externalWindow.window.onDestroy { [weak self, weak externalWindow] in
            guard let self, let externalWindow else { return }
            self.externalDocumentWindows.removeValue(forKey: ObjectIdentifier(externalWindow))
        }
        externalDocumentWindows[ObjectIdentifier(externalWindow)] = externalWindow
        externalWindow.present()
    }

    private func importExternalDocumentIntoLibrary(from fileURL: URL) throws -> Note {
        let repository = NotesRepository(notesDirectory: currentAppSettings().resolvedNotesDirectory())
        let importedNote = try repository.importNote(from: fileURL)
        mainWindow?.pollForExternalChanges()
        return importedNote
    }
}

public enum SwiftyNotesLauncher {
    @MainActor
    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Never {
        if let cliResult = NotesCLI.runIfRequested(arguments: arguments) {
            if !cliResult.stdout.isEmpty, let data = cliResult.stdout.data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
            if !cliResult.stderr.isEmpty, let data = cliResult.stderr.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            exit(cliResult.exitCode)
        }

        let applicationID = ProcessInfo.processInfo.environment["SWIFTY_NOTES_APP_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let app = Application(
            id: (applicationID?.isEmpty == false) ? applicationID! : AppIdentity.identifier
        )
        let appController = AppController()

        app.onActivate {
            appController.activate(app: app)
        }

        app.run()
        exit(0)
    }
}
