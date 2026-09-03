import Foundation
@testable import SwiftyNotes
import Testing

/// Runtime localization behaviour.
///
/// `setlocale` / `textdomain` / `bindtextdomain` are process-global and not
/// thread-safe, so this suite is serialized. The end-to-end assertions spawn
/// the real `swiftynotes` binary rather than driving gettext in-process: the
/// binary is the only thing that runs `initializeLocalization()` on its actual
/// startup path, and a subprocess lets us pin `LANGUAGE` without changing the
/// locale of the test process itself.
///
/// `ru_RU.UTF-8` is not generated on every machine, so the Russian assertions
/// use `LANGUAGE=ru` over a valid base locale — the one form that works
/// regardless of which locales the host has compiled.
@Suite(.serialized)
struct LocalizationTests {
    private static let domain = "me.spaceinbox.swiftynotes"

    // MARK: - Catalogue reachability

    /// Asserting `localeDirectoryPath() != nil` is not enough. A flattened
    /// resource bundle also returns non-nil while translating nothing, which is
    /// exactly how a broken `.process("locale")` rule passed unnoticed. gettext
    /// only ever loads `<dir>/<lang>/LC_MESSAGES/<domain>.mo`, so the layout is
    /// what has to hold.
    @Test("Locale directory resolves to a gettext catalogue layout")
    func localeDirectoryResolvesToGettextCatalogueLayout() throws {
        let dir = try #require(
            localeDirectoryPath(),
            "localeDirectoryPath() returned nil in a plain build",
        )
        let catalogue = URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("ru", isDirectory: true)
            .appendingPathComponent("LC_MESSAGES", isDirectory: true)
            .appendingPathComponent("\(Self.domain).mo", isDirectory: false)
        #expect(
            FileManager.default.fileExists(atPath: catalogue.path),
            """
            no catalogue at \(catalogue.path)
            gettext resolves <dir>/<lang>/LC_MESSAGES/<domain>.mo and cannot \
            load a .mo sitting directly in the bound directory
            """,
        )
    }

    @Test("Repeated initialization keeps resolving the same directory")
    func repeatedInitializationKeepsResolvingTheSameDirectory() {
        let first = localeDirectoryPath()
        #expect(localeDirectoryPath() == first)
    }

    /// A directory that does not carry our domain must be rejected. Otherwise
    /// the Flatpak branch binds `/app/share/locale` — which always exists
    /// inside the sandbox because GTK owns it — and the app silently falls back
    /// to English even though the bundled catalogue would have worked.
    @Test("A locale directory without our domain is rejected")
    func localeDirectoryWithoutOurDomainIsRejected() throws {
        let empty = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(
            localeDirectoryContainsCatalog(empty.path) == false,
            "a directory with no \(Self.domain).mo must not be accepted",
        )

        let populated = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: populated) }
        let messages = populated
            .appendingPathComponent("ru", isDirectory: true)
            .appendingPathComponent("LC_MESSAGES", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try Data().write(to: messages.appendingPathComponent("\(Self.domain).mo", isDirectory: false))
        #expect(localeDirectoryContainsCatalog(populated.path))
    }

    /// The catalogue has to sit at `<lang>/LC_MESSAGES/<domain>.mo`. A `.mo`
    /// lying anywhere else — in particular flattened into the directory root,
    /// which is what a `.process` resource rule produces — is unloadable, so
    /// accepting it hands `bindtextdomain` a path that silently translates
    /// nothing. This is the exact shape of the bug that survived five review
    /// rounds; finding a `.mo` somewhere below the directory is not the same
    /// question as the directory being a usable catalogue root.
    @Test("A flattened catalogue is not mistaken for a locale directory")
    func flattenedCatalogueIsNotMistakenForALocaleDirectory() throws {
        let flattened = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: flattened) }
        try Data().write(to: flattened.appendingPathComponent("\(Self.domain).mo", isDirectory: false))
        #expect(
            localeDirectoryContainsCatalog(flattened.path) == false,
            "a .mo in the directory root is not a catalogue gettext can load",
        )

        let misplaced = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: misplaced) }
        let wrongDepth = misplaced
            .appendingPathComponent("ru", isDirectory: true)
            .appendingPathComponent("LC_MESSAGES", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongDepth, withIntermediateDirectories: true)
        try Data().write(to: wrongDepth.appendingPathComponent("\(Self.domain).mo", isDirectory: false))
        #expect(
            localeDirectoryContainsCatalog(misplaced.path) == false,
            "a .mo below LC_MESSAGES is not on the path gettext resolves",
        )
    }

    // MARK: - End-to-end CLI output

    @Test("CLI errors are translated under LANGUAGE=ru")
    func cliErrorsAreTranslatedUnderRussianLanguage() throws {
        let result = try Self.runSwiftyNotes(["cli", "definitely-not-a-verb"], language: "ru")
        #expect(
            result.contains("Неизвестная команда CLI"),
            "expected a translated error, got: \(result)",
        )
    }

    @Test("CLI errors stay English when no language is requested")
    func cliErrorsStayEnglishWhenNoLanguageIsRequested() throws {
        let result = try Self.runSwiftyNotes(["cli", "definitely-not-a-verb"], language: nil)
        #expect(
            result.contains("Unknown CLI command"),
            "expected the untranslated msgid as the fallback, got: \(result)",
        )
    }

    /// `nlocalized(_:_:count:)` selects a plural form but returns the template
    /// with `%d` intact — the caller still has to run it through
    /// `String(format:)`. Skipping that leaks a raw format specifier into a
    /// destructive-action confirmation.
    @Test(
        "Folder delete confirmation substitutes the counts",
        arguments: [1, 2, 5],
    )
    func folderDeleteConfirmationSubstitutesTheCounts(noteCount: Int) throws {
        let vault = try Self.makeVault(noteCount: noteCount)
        defer { try? FileManager.default.removeItem(at: vault) }

        let result = try Self.runSwiftyNotes(
            ["cli", "folders", "rm", "Work", "--notes-dir", vault.path],
            language: nil,
        )
        #expect(
            !result.contains("%d"),
            "the count was never substituted: \(result)",
        )
        #expect(
            result.contains("\(noteCount) note"),
            "expected the note count in the confirmation, got: \(result)",
        )
        #expect(
            result.contains("1 subfolder"),
            "expected the subfolder count in the confirmation, got: \(result)",
        )
    }

    /// Russian needs three plural forms. Form 0 covers 1, 21, 31, 101…, so the
    /// n=21 case is the one that catches a catalogue whose `msgstr[0]`
    /// hardcodes the digit instead of keeping `%d`.
    @Test(
        "Folder delete confirmation agrees in Russian",
        arguments: [
            (1, "1 заметку"),
            (2, "2 заметки"),
            (5, "5 заметок"),
            (21, "21 заметку"),
        ],
    )
    func folderDeleteConfirmationAgreesInRussian(
        noteCount: Int,
        expectedPhrase: String,
    ) throws {
        let vault = try Self.makeVault(noteCount: noteCount)
        defer { try? FileManager.default.removeItem(at: vault) }

        let result = try Self.runSwiftyNotes(
            ["cli", "folders", "rm", "Work", "--notes-dir", vault.path],
            language: "ru",
        )
        #expect(!result.contains("%d"), "the count was never substituted: \(result)")
        #expect(
            result.contains(expectedPhrase),
            "expected \"\(expectedPhrase)\" for n=\(noteCount), got: \(result)",
        )
        // The surrounding sentence must be translated too. It contains escaped
        // quotes, which is precisely the msgid class a naive extractor mangles,
        // so a half-Russian sentence here means the catalogue is out of sync.
        #expect(
            !result.contains("Pass --yes"),
            "the surrounding sentence is still English: \(result)",
        )
    }

    // MARK: - Helpers

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-localization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a vault holding `Work` with `noteCount` notes plus one subfolder,
    /// driving the CLI so the notes land in the index rather than merely on
    /// disk.
    private static func makeVault(noteCount: Int) throws -> URL {
        let vault = try makeTemporaryDirectory()
        _ = try runSwiftyNotes(
            ["cli", "folders", "create", "Work", "--notes-dir", vault.path],
            language: nil,
        )
        _ = try runSwiftyNotes(
            ["cli", "folders", "create", "Work/Sub", "--notes-dir", vault.path],
            language: nil,
        )
        for index in 1 ... noteCount {
            _ = try runSwiftyNotes(
                [
                    "cli", "create",
                    "--content", "# note \(index)",
                    "--folder", "Work",
                    "--notes-dir", vault.path,
                ],
                language: nil,
            )
        }
        return vault
    }

    /// Runs the built binary with a pinned locale and returns stdout+stderr.
    ///
    /// `LC_ALL` is pinned to a UTF-8 English base locale so gettext is active
    /// at all (in the `C` locale it refuses to translate and ignores
    /// `LANGUAGE`), and `LANGUAGE` alone selects the catalogue. Passing `nil`
    /// clears `LANGUAGE` so an ambient value in the developer's environment
    /// cannot decide the outcome.
    private static func runSwiftyNotes(
        _ arguments: [String],
        language: String?,
    ) throws -> String {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        environment["LANGUAGE"] = language ?? ""
        environment.removeValue(forKey: "SWIFTY_NOTES_LOCALE_DIR")
        // The binary honours the interface language stored in settings, so
        // without an isolated config home the developer's own preference — set
        // by using the app — decides what language this subprocess answers in.
        environment["XDG_CONFIG_HOME"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-l10n-\(UUID().uuidString)", isDirectory: true)
            .path(percentEncoded: false)
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self)
        return out + err
    }

    private static func executableURL() throws -> URL {
        let fileManager = FileManager.default
        let argv0 = URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
        let sibling = argv0
            .deletingLastPathComponent()
            .appendingPathComponent("swiftynotes", isDirectory: false)
        if fileManager.fileExists(atPath: sibling.path) {
            return sibling
        }
        // On macOS the tests run as an `.xctest` bundle loaded by a helper, so
        // `argv[0]` is inside the toolchain rather than the products directory.
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("swiftynotes", isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw LocalizationTestError.executableNotFound
    }

    private enum LocalizationTestError: Error {
        case executableNotFound
    }
}
