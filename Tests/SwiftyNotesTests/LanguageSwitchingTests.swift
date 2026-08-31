#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// The interface-language picker: the preference, the gettext switch behind
/// it, and the live retranslation of an already-built window.
///
/// `LANGUAGE` and gettext's catalogue cache are process-global, so every test
/// that moves them is `@MainActor` and returns the language it found before
/// asserting anything else. Doing that synchronously — no `await` between the
/// switch and the restore — is what keeps the other `@MainActor` UI suites,
/// which assert English chrome, from observing a Russian process.
@Suite(.serialized)
struct LanguageSwitchingTests {
    // MARK: - The preference

    @Test("Each language carries the catalogue code gettext needs") @MainActor
    func eachLanguageCarriesTheCatalogueCodeGettextNeeds() {
        #expect(AppLanguage.system.catalogueCode == nil)
        #expect(AppLanguage.english.catalogueCode == "en")
        #expect(AppLanguage.russian.catalogueCode == "ru")
    }

    @Test("Following the system is the default") @MainActor
    func followingTheSystemIsTheDefault() {
        #expect(AppSettings.default.appLanguage == .system)
    }

    @Test("The picked language survives a settings round-trip") @MainActor
    func pickedLanguageSurvivesASettingsRoundTrip() throws {
        let settings = AppSettings(appLanguage: .russian)
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings),
        )
        #expect(decoded.appLanguage == .russian)
    }

    /// Settings written before the picker existed carry no `appLanguage` key.
    /// Reading those as anything but "follow the system" would silently pin
    /// every existing install to one language on upgrade.
    @Test("Settings saved before the picker existed still follow the system") @MainActor
    func settingsSavedBeforeThePickerExistedStillFollowTheSystem() throws {
        let legacy = Data(#"{"wrapsEditorLines":true,"editorFontSize":14}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(decoded.appLanguage == .system)
    }

    /// A language whose catalogue ships but has no ``AppLanguage`` case is
    /// invisible: `build-locales.sh` installs it, the user cannot select it.
    @Test("Every installed catalogue is selectable in the picker") @MainActor
    func everyInstalledCatalogueIsSelectableInThePicker() {
        let selectable = Set(AppLanguage.allCases.compactMap(\.catalogueCode))
        let installed = installedCatalogueLanguages()
        let unreachable = installed.subtracting(selectable).sorted()
        #expect(
            unreachable.isEmpty,
            """
            \(unreachable.count) catalogue(s) are installed but have no \
            AppLanguage case, so the picker cannot offer them: \
            \(unreachable.joined(separator: ", ")). Add a case to AppLanguage \
            (and its native name to displayName).
            """,
        )
    }

    // MARK: - The gettext switch

    @Test("Pinning a language changes lookups without a restart") @MainActor
    func pinningALanguageChangesLookupsWithoutARestart() throws {
        try withRestoredLanguage {
            try #require(
                applyLanguage(.russian),
                "no usable locale on this host — gettext ignores LANGUAGE under C",
            )
            #expect("Notes".localized == "Заметки")
            // Plurals come through ngettext, which resolves the catalogue
            // separately; a cache invalidation that missed it would leave
            // counted strings in the previous language.
            #expect(nlocalized("%d word", "%d words", count: 5) == "%d слов")

            #expect(applyLanguage(.english))
            #expect("Notes".localized == "Notes")
        }
    }

    @Test("Following the system restores the language the session asked for") @MainActor
    func followingTheSystemRestoresTheLanguageTheSessionAskedFor() throws {
        try withRestoredLanguage {
            AppLocalizationState.resetForTesting(sessionLanguage: nil)
            try #require(applyLanguage(.russian))
            #expect("Notes".localized == "Заметки")

            #expect(applyLanguage(.system))
            #expect("Notes".localized == "Notes", "an unset session LANGUAGE means untranslated")
        }
    }

    // MARK: - Live retranslation

    /// The point of the feature: an open window follows the picker instead of
    /// waiting for a restart, and it does so across the whole chrome rather
    /// than one label at a time.
    @Test("An open main window re-reads its whole chrome") @MainActor
    func openMainWindowReReadsItsWholeChrome() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.language-switch")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: AppSettingsStore(
                settingsFileURL: temp.appendingPathComponent("settings.json", isDirectory: false),
            ),
        )
        window.debugLoadInitialNotes()
        window.selectNote(at: 0)

        try withRestoredLanguage {
            let english = window.debugLocalizedChrome
            #expect(!english.isEmpty)

            try #require(
                applyLanguage(.russian),
                "no usable locale on this host — gettext ignores LANGUAGE under C",
            )
            // Applying the language without retranslating is the bug this
            // guards: the catalogue has moved, the widgets have not.
            #expect(window.debugLocalizedChrome == english)

            window.retranslate()
            let russian = window.debugLocalizedChrome

            let unchanged = english
                .filter { key, value in russian[key] == value && !value.isEmpty }
                .keys
                .sorted()
            #expect(
                unchanged.isEmpty,
                """
                \(unchanged.count) chrome label(s) kept their English text \
                after retranslate(): \(unchanged.joined(separator: ", ")). \
                Either the widget is set once at construction and \
                MainWindow.retranslate() does not re-apply it, or its msgid \
                has no Russian translation.
                """,
            )
        }
    }

    /// Changing the preference through the settings path — not by calling
    /// `retranslate()` directly — is how a user triggers this, so the wiring
    /// from `applyRuntimeSettings` has to be the thing under test.
    @Test("Changing the preference retranslates the window on its own") @MainActor
    func changingThePreferenceRetranslatesTheWindowOnItsOwn() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.language-preference")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: AppSettingsStore(
                settingsFileURL: temp.appendingPathComponent("settings.json", isDirectory: false),
            ),
        )
        window.debugLoadInitialNotes()

        try withRestoredLanguage {
            var externalWindowsNotified = 0
            window.onLanguageChanged = { externalWindowsNotified += 1 }

            // Prove a usable locale exists before asserting on translations,
            // then start from a known English baseline.
            try #require(
                applyLanguage(.russian),
                "no usable locale on this host — gettext ignores LANGUAGE under C",
            )
            _ = applyLanguage(.english)

            // `customNotesDirectoryPath` pins the notes folder to the one the
            // window already uses, so the update stays a preference change
            // and does not relocate storage.
            try window.debugUpdateAppSettings(AppSettings(
                customNotesDirectoryPath: temp.path(),
                appLanguage: .russian,
            ))
            #expect(window.appSettings.appLanguage == .russian)
            #expect(window.debugLocalizedChrome["tooltip.new"] == "Новая заметка")
            #expect(
                externalWindowsNotified == 1,
                "standalone document windows are notified through onLanguageChanged",
            )

            // Unsaved editor state is the reason the window retranslates
            // instead of being rebuilt.
            window.debugSetEditorText("черновик")
            try window.debugUpdateAppSettings(AppSettings(
                customNotesDirectoryPath: temp.path(),
                appLanguage: .english,
            ))
            #expect(window.editor.buffer.text == "черновик")
            #expect(window.debugLocalizedChrome["tooltip.new"] == "New Note")
        }
    }

    /// A standalone document window is not owned by the main window, so it
    /// follows the picker only if the launcher passes the change on.
    @Test("A standalone document window re-reads its whole chrome") @MainActor
    func standaloneDocumentWindowReReadsItsWholeChrome() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let fileURL = temp.appendingPathComponent("Doc.md", isDirectory: false)
        try "# Doc\n\n## Section\n\nBody".write(to: fileURL, atomically: true, encoding: .utf8)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.language-external")
        try app.register()

        let window = try ExternalDocumentWindow(
            application: app,
            fileURL: fileURL,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        try withRestoredLanguage {
            let english = window.debugLocalizedChrome
            #expect(!english.isEmpty)

            try #require(
                applyLanguage(.russian),
                "no usable locale on this host — gettext ignores LANGUAGE under C",
            )
            window.retranslate()

            let russian = window.debugLocalizedChrome
            let unchanged = english
                .filter { key, value in russian[key] == value && !value.isEmpty }
                .keys
                .sorted()
            #expect(
                unchanged.isEmpty,
                """
                \(unchanged.count) chrome label(s) kept their English text \
                after ExternalDocumentWindow.retranslate(): \
                \(unchanged.joined(separator: ", ")).
                """,
            )

            // The unsaved buffer is the reason this window retranslates rather
            // than being rebuilt.
            #expect(window.debugEditorText == "# Doc\n\n## Section\n\nBody")
        }
    }

    /// The picker lives in the settings window, so that window is the first
    /// thing the user watches for a response.
    @Test("The settings window re-reads its own rows and keeps the selection") @MainActor
    func settingsWindowReReadsItsOwnRowsAndKeepsTheSelection() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.language-settings")
        try app.register()
        let parent = ApplicationWindow(application: app)

        var applied: AppSettings?
        let window = SettingsWindow(
            application: app,
            parentWindow: parent,
            currentSettings: AppSettings(customNotesDirectoryPath: temp.path()),
            currentNotesDirectory: temp,
            defaultNotesDirectory: temp,
            applyNotesDirectoryChange: { $0 },
            applySettingsChange: { settings in
                applied = settings
                return settings
            },
            openDirectory: { _ in },
        )

        try withRestoredLanguage {
            let english = window.debugLocalizedChrome

            // Selecting Russian is what a user does; the row reports it back
            // through applySettingsChange, which in the app is MainWindow.
            window.debugSetLanguage(.russian)
            #expect(applied?.appLanguage == .russian)

            try #require(
                applyLanguage(.russian),
                "no usable locale on this host — gettext ignores LANGUAGE under C",
            )
            window.retranslate()

            let russian = window.debugLocalizedChrome
            let unchanged = english
                .filter { key, value in russian[key] == value && !value.isEmpty }
                .keys
                .sorted()
            #expect(
                unchanged.isEmpty,
                """
                \(unchanged.count) settings label(s) kept their English text \
                after retranslate(): \(unchanged.joined(separator: ", ")).
                """,
            )

            // Rebuilding the combo models resets their selection, so the
            // retranslate has to put the picked values back — otherwise
            // switching language silently rewrites other preferences.
            #expect(
                window.debugSelectedLanguage == .russian,
                "the language row must still show the language that was picked",
            )
        }
    }

    // MARK: - The real binary's startup path

    /// In-process tests drive ``applyLanguage(_:)`` directly. This one checks
    /// the wiring only the shipped binary runs: reading the preference out of
    /// settings before anything is drawn — and before command dispatch, since
    /// the CLI reports its errors through the same catalogue.
    ///
    /// `LANGUAGE` is deliberately unset here: if the preference were ignored,
    /// the subprocess would answer in English and the assertion would fail
    /// for the right reason.
    @Test("The binary honours the stored language with LANGUAGE unset") @MainActor
    func binaryHonoursTheStoredLanguageWithLanguageUnset() throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: configHome) }

        let settingsFile = AppIdentity.applicationDirectory(in: configHome)
            .appendingPathComponent("settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: settingsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data(#"{"appLanguage":"ru"}"#.utf8).write(to: settingsFile)

        let output = try Self.runSwiftyNotes(
            ["cli", "definitely-not-a-verb"],
            configHome: configHome,
        )
        #expect(
            output.contains("Неизвестная команда CLI"),
            "expected the stored language to win over an unset LANGUAGE, got: \(output)",
        )
    }

    /// Follow-the-system must not pin anything: with `LANGUAGE` unset and no
    /// preference stored, the binary stays on the msgid language.
    @Test("The binary follows the session when no language is stored") @MainActor
    func binaryFollowsTheSessionWhenNoLanguageIsStored() throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: configHome) }
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)

        let output = try Self.runSwiftyNotes(
            ["cli", "definitely-not-a-verb"],
            configHome: configHome,
        )
        #expect(output.contains("Unknown CLI command"), "got: \(output)")
    }

    /// Runs the built binary with a scratch config home and no `LANGUAGE`, so
    /// the only thing that can select a catalogue is the stored preference.
    private static func runSwiftyNotes(
        _ arguments: [String],
        configHome: URL,
    ) throws -> String {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        // A real base locale, because gettext ignores every language request
        // while LC_MESSAGES is C — see AppLocalization.applyLanguage(_:).
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        environment.removeValue(forKey: "LANGUAGE")
        environment.removeValue(forKey: "SWIFTY_NOTES_LOCALE_DIR")
        environment["XDG_CONFIG_HOME"] = configHome.path(percentEncoded: false)
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: outData, as: UTF8.self) + String(decoding: errData, as: UTF8.self)
    }

    private static func executableURL() throws -> URL {
        let argv0 = URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
        let sibling = argv0
            .deletingLastPathComponent()
            .appendingPathComponent("swiftynotes", isDirectory: false)
        guard FileManager.default.fileExists(atPath: sibling.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return sibling
    }

    /// Binds the gettext domain, runs `body`, and puts the process language
    /// back afterwards whatever happens inside.
    ///
    /// The binding is not incidental: only the app binary runs
    /// `initializeLocalization()` on its startup path, so in a test process
    /// the domain is unbound and every lookup returns its msgid — which would
    /// make these assertions pass for the wrong reason if they expected
    /// English, and fail confusingly when they expect Russian.
    @MainActor
    private func withRestoredLanguage(_ body: () throws -> Void) throws {
        let previous = ProcessInfo.processInfo.environment["LANGUAGE"]
        defer {
            AppLocalizationState.resetForTesting(sessionLanguage: previous)
            _ = applyLanguage(.system)
        }
        initializeLocalization()
        AppLocalizationState.resetForTesting(sessionLanguage: previous)
        try body()
    }
}
#endif
