import Adwaita
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum ExternalDocumentOpenError: LocalizedError {
    case unsupportedLocation(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocation:
            "Swifty Notes can only open local markdown files."
        }
    }
}

@MainActor
final class AppController {
    private let stateStore: WorkspaceStateStore
    private let appSettingsStore: AppSettingsStore
    private let allowsWindowPresentation: Bool
    private let launchOptions: AppLaunchOptions
    fileprivate(set) var mainWindow: MainWindow?
    private var externalDocumentWindows: [ObjectIdentifier: ExternalDocumentWindow] = [:]

    init(
        stateStore: WorkspaceStateStore = WorkspaceStateStore(),
        appSettingsStore: AppSettingsStore = AppSettingsStore(),
        allowsWindowPresentation: Bool = true,
        launchOptions: AppLaunchOptions = AppLaunchOptions(forceUpdateAvailable: false, passthroughArguments: []),
    ) {
        self.stateStore = stateStore
        self.appSettingsStore = appSettingsStore
        self.allowsWindowPresentation = allowsWindowPresentation
        self.launchOptions = launchOptions
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
            forceUpdateAvailable: launchOptions.forceUpdateAvailable,
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
        let loaded = (try? appSettingsStore.load()) ?? .default
        let normalized = loaded.normalizedAgainstFilesystem()
        if normalized != loaded {
            // Persist the recovery so the user doesn't see the
            // missing-folder errors on every launch. Best-effort; if the
            // save fails we still hand back the in-memory normalized
            // settings so the rest of startup uses a valid notes folder.
            try? appSettingsStore.save(normalized)
        }
        return normalized
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
        ensureRuntimeResourcePathsForUnbundledMacOSIfNeeded()
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

        let launchOptions = AppLaunchOptions.parse(arguments: arguments)
        let environment = ProcessInfo.processInfo.environment
        let app = Application(
            id: resolveApplicationID(
                override: environment["SWIFTY_NOTES_APP_ID"],
                env: environment,
            ),
            flags: resolveApplicationFlags(env: environment),
        )
        let appController = AppController(launchOptions: launchOptions)
        installQuitAction(on: app)
        installOutlineActions(on: app, controller: appController)

        app.onActivate {
            appController.activate(app: app)
        }
        app.onOpen { fileURLs, _ in
            appController.openDocuments(at: fileURLs, application: app)
        }

        let processArguments = [CommandLine.arguments.first ?? "swiftynotes"] + launchOptions.passthroughArguments
        app.run(arguments: processArguments)
        exit(0)
    }

    /// Resolves the GApplication identifier to register on the session bus.
    ///
    /// Honors an explicit ``SWIFTY_NOTES_APP_ID`` override and otherwise
    /// returns ``AppIdentity.identifier`` — the canonical reverse-DNS app
    /// id used everywhere (Flatpak, native, snap). Snap-specific name
    /// shaping is intentionally not done here; instead, see
    /// ``resolveApplicationFlags(env:)`` which adds ``.nonUnique`` under
    /// strict-confined Snap so the id is never bound on the bus at all.
    static func resolveApplicationID(override: String?, env _: [String: String]) -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return AppIdentity.identifier
    }

    /// Picks ``ApplicationFlags`` based on the process environment.
    ///
    /// Strict-confined Snap installs cannot own a session-bus name —
    /// snapd's default AppArmor profile permits no ``dbus (bind)`` rules
    /// on the session bus other than tray-icon names. Trying to register
    /// a GApplication id there aborts startup with ``AccessDenied: ...
    /// due to AppArmor policy``. Adding ``.nonUnique`` skips the bus
    /// registration entirely, at the cost of single-instance behavior in
    /// the Snap build only — a second launch spawns a second process
    /// instead of focusing the running one. Flatpak and native installs
    /// keep the default behavior. Same approach the Actioneer snap uses.
    static func resolveApplicationFlags(env: [String: String]) -> ApplicationFlags {
        var flags: ApplicationFlags = .handlesOpen
        let snapInstance = env["SNAP_INSTANCE_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapName = env["SNAP_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snap = env["SNAP"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (snapInstance?.isEmpty == false) || (snapName?.isEmpty == false) || (snap?.isEmpty == false) {
            flags.insert(.nonUnique)
        }
        return flags
    }

    /// Registers `app.toggle-outline` (bound to F9) and
    /// `app.quick-jump` (bound to `<Primary>g`) at the GApplication
    /// level. Same pattern as ``installQuitAction``: lifting the
    /// shortcuts off the per-window keyboard map lets them surface in
    /// the macOS Apple menu and fire across every window (main note
    /// window + external document windows + Settings) without each
    /// having to wire them up locally.
    @MainActor
    private static func installOutlineActions(on app: Application, controller: AppController) {
        let toggle = SimpleAction(name: "toggle-outline") { [weak controller] in
            controller?.mainWindow?.toggleOutlineVisibility()
        }
        app.addAction(toggle)
        installAccelerator("F9", forAction: "app.toggle-outline", on: app)

        let quickJump = SimpleAction(name: "quick-jump") { [weak controller] in
            controller?.mainWindow?.openCommandPalette()
        }
        app.addAction(quickJump)
        installAccelerator("<Primary>g", forAction: "app.quick-jump", on: app)
    }

    @MainActor
    private static func installAccelerator(_ accel: String, forAction action: String, on app: Application) {
        accel.withCString { accelPtr in
            var arr: [UnsafePointer<CChar>?] = [accelPtr, nil]
            arr.withUnsafeMutableBufferPointer { buf in
                gtk_application_set_accels_for_action(
                    app.gtkApplicationPointer,
                    action,
                    buf.baseAddress,
                )
            }
        }
    }

    /// Registers an `app.quit` GAction on the GApplication and binds
    /// `<Primary>q` (Cmd+Q on macOS, Ctrl+Q on Linux) to it. Doing this
    /// at the GApplication level — instead of per-window
    /// `addKeyboardShortcut` — lights up the standard "Quit Swifty
    /// Notes" item in the Cocoa Apple menu (GTK's macOS backend bridges
    /// it to `app.quit` automatically) and lets the shortcut fire even
    /// when no swift-adwaita-managed window has focus.
    @MainActor
    private static func installQuitAction(on app: Application) {
        let quitAction = SimpleAction(name: "quit") {
            Application.current?.quit()
        }
        app.addAction(quitAction)

        // `gtk_application_set_accels_for_action` takes a NULL-terminated
        // C array of accelerator strings. Build it inline so the
        // CStrings outlive the GTK call.
        "<Primary>q".withCString { accel in
            var arr: [UnsafePointer<CChar>?] = [accel, nil]
            arr.withUnsafeMutableBufferPointer { buf in
                gtk_application_set_accels_for_action(
                    app.gtkApplicationPointer,
                    "app.quit",
                    buf.baseAddress,
                )
            }
        }
    }

    /// On macOS, GTK/GLib's resource discovery walks `XDG_DATA_DIRS` to
    /// find `glib-2.0/schemas/gschemas.compiled` and the icon themes.
    /// The bundled `.app` entry sets this from `Bundle.main.resourcePath`
    /// before calling `run`; the SwiftPM `swift run swiftynotes` entry
    /// doesn't, which means `g_settings_new(...)` aborts the process
    /// with `No GSettings schemas are installed on the system` the
    /// moment any GTK widget that needs a schema is created — most
    /// visibly `GtkFileChooserNative` (Settings → Browse).
    ///
    /// Merging (not replacing) is important: Ghostty / iTerm export
    /// their own `XDG_DATA_DIRS` from `~/.zshrc` (`/usr/local/share`,
    /// terminal-bundled paths, …) which contain *no* GLib schemas, so
    /// a "set only when unset" guard would silently skip exactly the
    /// case that broke this user's Settings → Browse. Mirror what
    /// swift-adwaita's `DemoAppLib.ensureHomebrewSchemasOnPath` does:
    /// prepend brew's share dir(s) if they aren't already in the path.
    private static func ensureRuntimeResourcePathsForUnbundledMacOSIfNeeded() {
        #if os(macOS)
        let env = ProcessInfo.processInfo.environment
        let candidates = ["/opt/homebrew/share", "/usr/local/share"]
            .filter { FileManager.default.fileExists(atPath: "\($0)/glib-2.0/schemas/gschemas.compiled") }
        guard !candidates.isEmpty else { return }
        let existing = env["XDG_DATA_DIRS"] ?? ""
        let parts = existing.split(separator: ":").map(String.init)
        let missing = candidates.filter { !parts.contains($0) }
        guard !missing.isEmpty else { return }
        let combined = (missing + parts).joined(separator: ":")
        setenv("XDG_DATA_DIRS", combined, 1)
        #endif
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
                .sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
        }

        func debugExternalWindowIdentifier(for fileURL: URL) -> ObjectIdentifier? {
            let standardizedURL = fileURL.standardizedFileURL
            return externalDocumentWindows.values
                .first(where: { $0.fileURL == standardizedURL })
                .map(ObjectIdentifier.init)
        }
    }
#endif
