import Adwaita
import Foundation
import Glibc

private enum ExternalDocumentOpenError: LocalizedError {
    case unsupportedLocation(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocation:
            "Swifty Notes can only open local markdown files."
        }
    }
}

private let applicationHandlesOpenFlag = GApplicationFlags(rawValue: 1 << 2)

@MainActor
final class AppController {
    private let stateStore: WorkspaceStateStore
    private let appSettingsStore: AppSettingsStore
    private let allowsWindowPresentation: Bool
    private var mainWindow: MainWindow?
    private var externalDocumentWindows: [ObjectIdentifier: ExternalDocumentWindow] = [:]

    init(
        stateStore: WorkspaceStateStore = WorkspaceStateStore(),
        appSettingsStore: AppSettingsStore = AppSettingsStore(),
        allowsWindowPresentation: Bool = true,
    ) {
        self.stateStore = stateStore
        self.appSettingsStore = appSettingsStore
        self.allowsWindowPresentation = allowsWindowPresentation
    }

    func activate(app: Application) {
        if let mainWindow {
            if allowsWindowPresentation {
                mainWindow.present()
            }
            return
        }

        let workspaceState = (try? stateStore.load()) ?? .default
        let appSettings = currentAppSettings()
        let window = MainWindow(
            application: app,
            state: AppState(persistedState: workspaceState),
            stateStore: stateStore,
            repository: NotesRepository(
                notesDirectory: appSettings.resolvedNotesDirectory(),
            ),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: appSettingsStore,
            appSettings: appSettings,
            openExternalDocumentHandler: { [weak self, weak app] fileURL in
                guard let self, let app else { return }
                try openExternalDocument(at: fileURL, application: app)
            },
        )
        window.window.onDestroy { [weak self] in
            self?.releaseMainWindow()
        }
        mainWindow = window
        if allowsWindowPresentation {
            window.present()
        }
    }

    func releaseMainWindow() {
        mainWindow = nil
    }

    private func currentAppSettings() -> AppSettings {
        (try? appSettingsStore.load()) ?? .default
    }

    func openDocuments(at fileURLs: [URL], application: Application) {
        guard !fileURLs.isEmpty else {
            activate(app: application)
            return
        }

        for fileURL in fileURLs {
            do {
                try openExternalDocument(at: fileURL, application: application)
            } catch {
                presentOpenDocumentError(error, for: fileURL, application: application)
            }
        }
    }

    private func openExternalDocument(at fileURL: URL, application: Application) throws {
        let standardizedURL = try normalizedExternalDocumentURL(from: fileURL)
        if let existingWindow = externalDocumentWindows.values.first(where: { $0.fileURL == standardizedURL }) {
            if allowsWindowPresentation {
                existingWindow.present()
            }
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
                return try importExternalDocumentIntoLibrary(from: fileURL)
            },
        )
        externalWindow.window.onDestroy { [weak self, weak externalWindow] in
            guard let self, let externalWindow else { return }
            externalDocumentWindows.removeValue(forKey: ObjectIdentifier(externalWindow))
        }
        externalDocumentWindows[ObjectIdentifier(externalWindow)] = externalWindow
        if allowsWindowPresentation {
            externalWindow.present()
        }
    }

    private func importExternalDocumentIntoLibrary(from fileURL: URL) throws -> Note {
        let repository = NotesRepository(notesDirectory: currentAppSettings().resolvedNotesDirectory())
        let importedNote = try repository.importNote(from: fileURL)
        mainWindow?.pollForExternalChanges()
        return importedNote
    }

    private func normalizedExternalDocumentURL(from fileURL: URL) throws -> URL {
        guard fileURL.isFileURL else {
            throw ExternalDocumentOpenError.unsupportedLocation(fileURL)
        }
        return fileURL.standardizedFileURL
    }

    private func presentOpenDocumentError(_ error: Error, for fileURL: URL, application: Application) {
        let body = """
        \(displayLocation(for: fileURL))

        \(error.localizedDescription)
        """

        if let mainWindow {
            mainWindow.present()
            mainWindow.presentError(heading: "Could not open markdown file", body: body)
            return
        }

        activate(app: application)
        mainWindow?.presentError(heading: "Could not open markdown file", body: body)
    }

    private func displayLocation(for fileURL: URL) -> String {
        if fileURL.isFileURL {
            return fileURL.standardizedFileURL.path(percentEncoded: false)
        }
        return fileURL.absoluteString
    }
}

public enum SwiftyNotesLauncher {
    @MainActor
    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Never {
        MainContext.silenceSpuriousScrollbarWarnings()
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
            id: (applicationID?.isEmpty == false) ? applicationID! : AppIdentity.identifier,
            flags: applicationHandlesOpenFlag,
        )
        let appController = AppController()

        app.onActivate {
            appController.activate(app: app)
        }
        app.onOpen { fileURLs, _ in
            appController.openDocuments(at: fileURLs, application: app)
        }

        let processArguments = [CommandLine.arguments.first ?? "swiftynotes"] + arguments
        app.run(arguments: processArguments)
        exit(0)
    }
}

#if DEBUG
    extension AppController {
        var debugHasMainWindow: Bool {
            mainWindow != nil
        }

        var debugExternalDocumentFileURLs: [URL] {
            externalDocumentWindows.values
                .map(\.fileURL)
                .sorted { $0.path < $1.path }
        }

        func debugExternalWindowIdentifier(for fileURL: URL) -> ObjectIdentifier? {
            let standardizedURL = fileURL.standardizedFileURL
            return externalDocumentWindows.values
                .first(where: { $0.fileURL == standardizedURL })
                .map(ObjectIdentifier.init)
        }
    }
#endif
