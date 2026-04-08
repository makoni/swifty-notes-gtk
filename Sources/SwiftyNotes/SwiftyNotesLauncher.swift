import Adwaita
import Foundation
import Glibc

@MainActor
private final class AppController {
    private var mainWindow: MainWindow?

    func activate(app: Application) {
        let stateStore = WorkspaceStateStore()
        let appSettingsStore = AppSettingsStore()
        let workspaceState = (try? stateStore.load()) ?? .default
        let appSettings = (try? appSettingsStore.load()) ?? .default
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
            appSettings: appSettings
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
