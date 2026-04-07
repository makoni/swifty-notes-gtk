import Adwaita
import Foundation
import Glibc

@MainActor
private final class AppController {
    private var mainWindow: MainWindow?

    func activate(app: Application) {
        let stateStore = WorkspaceStateStore()
        let workspaceState = (try? stateStore.load()) ?? .default
        let window = MainWindow(
            application: app,
            state: AppState(persistedState: workspaceState),
            stateStore: stateStore,
            repository: NotesRepository(),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
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

private let appController = AppController()

@MainActor
private func buildApp() {
    let applicationID = ProcessInfo.processInfo.environment["SWIFTY_NOTES_APP_ID"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let app = Application(
        id: (applicationID?.isEmpty == false) ? applicationID! : AppIdentity.identifier
    )

    app.onActivate {
        appController.activate(app: app)
    }

    app.run()
}

let arguments = Array(CommandLine.arguments.dropFirst())
if let cliResult = NotesCLI.runIfRequested(arguments: arguments) {
    if !cliResult.stdout.isEmpty, let data = cliResult.stdout.data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
    if !cliResult.stderr.isEmpty, let data = cliResult.stderr.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(cliResult.exitCode)
}

buildApp()
