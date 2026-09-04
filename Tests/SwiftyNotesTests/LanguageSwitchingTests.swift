#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// The interface-language picker: the preference, the gettext switch behind
/// it, and the live retranslation of an already-built window.
///
/// `LANGUAGE`, `LC_MESSAGES` and gettext's catalogue cache are all
/// process-global, so every test that moves them is `@MainActor`, does so
/// synchronously — no `await` between the switch and the restore — and puts
/// all three back afterwards.
///
/// That covers other `@MainActor` suites, which cannot interleave with a
/// synchronous body. It does **not** cover a suite running off the main actor:
/// `CLITests` drives `NotesCLI` in-process and asserts English error text, so
/// under a fully parallel `swift test` it could sample a Russian process. Both
/// CI and the `swift test --no-parallel` that `AGENTS.md` prescribes run
/// serially, which is what makes that safe rather than lucky.
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
            applySessionLanguage(nil)
            try #require(applyLanguage(.russian))
            #expect("Notes".localized == "Заметки")

            #expect(applyLanguage(.system))
            #expect("Notes".localized == "Notes", "an unset session LANGUAGE means untranslated")
        }
    }

    // MARK: - Contexts

    /// The test the original i18n plan asked for and that could not be written
    /// until the extractor read contexts: one English string, two meanings,
    /// each translated on its own.
    ///
    /// `Preview` is the real case. It labels the view-mode toggle, where it
    /// sits beside «Редактор» in a segmented control and «Предварительный
    /// просмотр» does not fit, and it heads a Settings group, where the long
    /// form is the right one.
    @Test("One msgid can be translated two ways through contexts") @MainActor
    func oneMsgidCanBeTranslatedTwoWaysThroughContexts() throws {
        try withRestoredLanguage {
            try #require(
                applyLanguage(.russian),
                "no usable locale on this host — gettext ignores LANGUAGE under C",
            )

            let viewMode = localizedWithContext("view mode", "Preview")
            let settingsGroup = localizedWithContext("settings group", "Preview")

            #expect(viewMode == "Просмотр")
            #expect(settingsGroup == "Предварительный просмотр")
            #expect(viewMode != settingsGroup, "the split has to actually produce two strings")

            // A context nobody translated falls back to the bare msgid rather
            // than leaking the `\u{4}`-joined key at the user.
            let unknown = localizedWithContext("nonexistent context", "Preview")
            #expect(unknown == "Preview")
            #expect(!unknown.contains("\u{4}"))
        }
    }

    /// The second msgid that was serving two masters. As a sort criterion
    /// `Title` names what the list is ordered by, and Russian puts that in the
    /// prepositional case («По названию»); as the placeholder of the rename
    /// field it is the bare noun («Название»). One English word, two
    /// grammatical roles — which is what the context split buys.
    @Test("A sort criterion and a field label read differently in Russian") @MainActor
    func aSortCriterionAndAFieldLabelReadDifferentlyInRussian() throws {
        try withRestoredLanguage {
            try #require(
                applyLanguage(.russian),
                "no usable locale on this host — gettext ignores LANGUAGE under C",
            )

            let criterion = NotesSortMode.title.displayName
            let fieldLabel = "Title".localized

            #expect(criterion == "По названию")
            #expect(fieldLabel == "Название")
            // The point of the split: pinning both to the same string is what
            // this replaced, and a merge that dropped the context would put
            // the field label back in the sort menu.
            #expect(criterion != fieldLabel)
        }
    }

    // MARK: - Dates and the session locale

    /// The `.system` case, which was the one that was wrong.
    ///
    /// `Locale.current` does not follow the environment on Linux — measured
    /// on Swift 6.3.2 it is `en_001` whatever `LANG`, `LC_ALL` or `LC_TIME`
    /// say — so a German or Japanese desktop got English dates unless its
    /// user pinned a language by hand. Nothing asserted anything about this
    /// path, which is why it went unnoticed while every other string was
    /// being translated.
    @Test("A system-language interface formats dates in the session's locale") @MainActor
    func aSystemLanguageInterfaceFormatsDatesInTheSessionsLocale() throws {
        try withRestoredLanguage {
            try withSessionLocale(lang: "de_DE.UTF-8", time: nil) {
                #expect(interfaceLocale().identifier == "de_DE")
            }
            // The category's own variable wins: one language, another
            // region's date format, which is a real configuration.
            try withSessionLocale(lang: "de_DE.UTF-8", time: "en_GB.UTF-8") {
                #expect(interfaceLocale().identifier == "en_GB")
            }
        }
    }

    /// A pinned language still decides, because the interface it labels is
    /// the thing the date sits beside.
    @Test("A pinned language outranks the session locale for dates") @MainActor
    func aPinnedLanguageOutranksTheSessionLocaleForDates() throws {
        try withRestoredLanguage {
            try withSessionLocale(lang: "de_DE.UTF-8", time: nil) {
                try #require(
                    applyLanguage(.russian),
                    "no usable locale on this host — gettext ignores LANGUAGE under C",
                )
                #expect(interfaceLocale().identifier == "ru")
            }
        }
    }

    /// A session that asked for nothing usable leaves `Locale.current`, which
    /// is the honest fallback rather than a guess.
    @Test("A C-locale session falls back to Locale.current for dates") @MainActor
    func aCLocaleSessionFallsBackToLocaleCurrentForDates() throws {
        try withRestoredLanguage {
            try withSessionLocale(lang: "C.UTF-8", time: nil) {
                #expect(interfaceLocale().identifier == Locale.current.identifier)
            }
        }
    }

    /// What the user sees: the sidebar's own formatter, not just the locale.
    @Test("The notes sidebar writes its dates in the session's language") @MainActor
    func theNotesSidebarWritesItsDatesInTheSessionsLanguage() throws {
        let moment = Date(timeIntervalSince1970: 1_756_000_000)
        try withRestoredLanguage {
            try withSessionLocale(lang: "ru_RU.UTF-8", time: nil) {
                let formatter = DateFormatter()
                formatter.locale = interfaceLocale()
                formatter.dateStyle = .medium
                let rendered = formatter.string(from: moment)
                #expect(
                    rendered.contains("авг"),
                    "a Russian session should see a Russian month name, got \(rendered.debugDescription)",
                )
            }
        }
    }

    /// Sets the session's locale variables for the duration of `body`, and
    /// re-captures so the library reads them as the session's own.
    @MainActor
    private func withSessionLocale(lang: String?, time: String?, _ body: () throws -> Void) throws {
        let names = ["LC_ALL", "LC_TIME", "LANG"]
        let previous = names.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (name, value) in previous {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
            recaptureSessionLanguage()
        }
        unsetenv("LC_ALL")
        if let lang { setenv("LANG", lang, 1) } else { unsetenv("LANG") }
        if let time { setenv("LC_TIME", time, 1) } else { unsetenv("LC_TIME") }
        recaptureSessionLanguage()
        try body()
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

            // An empty value means the label was never applied in *either*
            // language, which is the stronger form of the bug — so assert
            // non-emptiness rather than skipping those keys, or deleting a
            // `setAccessibleLabel` call entirely would pass.
            let empty = english.filter { $0.value.isEmpty }.keys.sorted()
            #expect(
                empty.isEmpty,
                """
                \(empty.count) chrome label(s) are empty, so they were never \
                applied at all: \(empty.joined(separator: ", "))
                """,
            )

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
    ///
    /// The deferral is asserted, not incidental. A language change arrives from
    /// inside the language ComboRow's own `notify::selected` emission, and
    /// retranslating rebuilds that row's model; doing it synchronously left GTK
    /// unwinding through a freed model and crashed the app on every switch.
    @Test("Changing the preference retranslates the window on its own") @MainActor
    func changingThePreferenceRetranslatesTheWindowOnItsOwn() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.language-preference")
        try app.register()
        let deferredScheduler = TestMainActorScheduler()

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
            deferredUIActionScheduler: deferredScheduler.schedule,
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
            #expect(window.appSettings.appLanguage == .russian, "the preference lands immediately")
            #expect(
                window.debugLocalizedChrome["tooltip.new"] == "New Note",
                """
                the chrome must not be touched yet — retranslating inside the \
                settings row's signal emission is what crashed the app
                """,
            )
            #expect(externalWindowsNotified == 0, "the fan-out waits too")

            deferredScheduler.runPendingActions()
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
            deferredScheduler.runPendingActions()
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
            let empty = english.filter { $0.value.isEmpty }.keys.sorted()
            #expect(empty.isEmpty, "never-applied label(s): \(empty.joined(separator: ", "))")

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

        let recorder = LocalizationTestSupport.SettingsRecorder()
        let rig = try LocalizationTestSupport.makeSettingsWindow(
            suffix: "language-settings",
            directory: temp,
            applySettingsChange: { settings in
                recorder.settings = settings
                return settings
            },
        )
        let window = rig.window

        try withRestoredLanguage {
            let english = window.debugLocalizedChrome

            // Selecting Russian is what a user does; the row reports it back
            // through applySettingsChange, which in the app is MainWindow.
            window.debugSetLanguage(.russian)
            #expect(recorder.settings?.appLanguage == .russian)

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

    // MARK: - Catalogue reachability

    /// The warning branch cannot be reached in a SwiftPM build — the Russian
    /// `.mo` is tracked and declared as a resource, so a catalogue is always
    /// found — which is why the message is a pure function rather than an
    /// inline `if`. Untested, its text, condition and stream would all be
    /// unverified.
    @Test("A missing catalogue produces a diagnostic that can diagnose it") @MainActor
    func missingCatalogueProducesADiagnosticThatCanDiagnoseIt() {
        #expect(
            missingCatalogueDiagnostic(localeDirectory: "/app/share/locale") == nil,
            "a resolved directory means a catalogue was found"
        )

        let diagnostic = try? #require(missingCatalogueDiagnostic(localeDirectory: nil))
        let message = diagnostic ?? ""
        // It exists to tell a packager where to look, so the domain and the
        // layout gettext insists on both have to be in it.
        #expect(message.contains(AppIdentity.identifier))
        #expect(message.contains("LC_MESSAGES"))
        #expect(message.contains(systemLocaleDirectory))
        #expect(message.contains("untranslated"))
    }

    /// The shipped build must never hit that branch: if it does, the resource
    /// rule that carries the catalogue has broken.
    @Test("This build resolves a catalogue") @MainActor
    func thisBuildResolvesACatalogue() {
        #expect(
            localeDirectoryPath() != nil,
            "no catalogue reachable from the test build — the locale resource rule has broken"
        )
        #expect(installedCatalogueLanguages().contains("ru"))
    }

    // MARK: - Reading direction

    /// The case behind the Flathub complaint: an Arabic desktop, no Arabic
    /// catalogue of our own. The interface stays English, but the layout has
    /// to mirror — and it cannot be left to GTK, which decides direction from
    /// *its* catalogue and so comes up left-to-right wherever GTK's own
    /// Arabic translation is not installed, which is most bare systems.
    @Test("Following a right-to-left session asks for a mirrored layout") @MainActor
    func followingARightToLeftSessionAsksForAMirroredLayout() throws {
        try withRestoredLanguage {
            applySessionLanguage("ar")
            #expect(interfaceIsRightToLeft(for: .system))

            applySessionLanguage("he_IL.UTF-8")
            #expect(interfaceIsRightToLeft(for: .system), "a full locale resolves too")

            applySessionLanguage("fa")
            #expect(interfaceIsRightToLeft(for: .system))

            applySessionLanguage("ru_RU.UTF-8")
            #expect(!interfaceIsRightToLeft(for: .system))
        }
    }

    /// Pinning a language pins its direction too, regardless of the session —
    /// so a Russian interface on an Arabic desktop reads left-to-right, and an
    /// Arabic interface on an English desktop reads right-to-left.
    @Test("A pinned language decides the direction, not the session") @MainActor
    func pinnedLanguageDecidesTheDirectionNotTheSession() throws {
        try withRestoredLanguage {
            applySessionLanguage("ar")
            #expect(!interfaceIsRightToLeft(for: .russian))
            #expect(!interfaceIsRightToLeft(for: .english))
        }
    }

    // MARK: - Dates

    /// `Locale.current` follows `LC_ALL` / `LANG`, the interface language
    /// follows `LANGUAGE`. Without ``interfaceLocale()`` bridging them, a
    /// Russian sidebar printed English dates.
    @Test("Dates follow the interface language, not the session locale") @MainActor
    func datesFollowTheInterfaceLanguageNotTheSessionLocale() throws {
        try withRestoredLanguage {
            let date = Date(timeIntervalSince1970: 1_756_600_000)

            try #require(
                applyLanguage(.russian),
                "no usable locale on this host — gettext ignores LANGUAGE under C",
            )
            let russian = NotesSidebar.displayDate(date)

            _ = applyLanguage(.english)
            let english = NotesSidebar.displayDate(date)

            #expect(
                russian != english,
                "the same instant rendered identically in both languages: \(russian)",
            )
            #expect(
                russian.contains("авг") || russian.contains("Авг"),
                "expected a Russian month name, got: \(russian)",
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
        try LocalizationTestSupport.withRestoredLanguage(body)
    }

    @MainActor
    private func applySessionLanguage(_ language: String?) {
        LocalizationTestSupport.applySessionLanguage(language)
    }
}
#endif
