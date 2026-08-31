import Foundation
import Testing

/// Catalogue integrity and source-level lints.
///
/// These tests read the repository rather than the built product. They exist
/// because the Russian catalogue has repeatedly drifted from the source: a
/// hand-maintained `po/ru.po` accumulates fragments of strings the extractor
/// mangled while the real msgids go missing, and nothing else notices.
/// `msgfmt -c` cannot catch it — the catalogue carries no `#, c-format` flags,
/// so its format checking is inert.
struct LocalizationCatalogTests {
    // MARK: - Catalogue coverage

    @Test("Every translatable source string has a catalogue entry")
    func everyTranslatableSourceStringHasACatalogueEntry() async throws {
        let source = try await LocalizationCatalogFixture.sourceMessageIDs()
        let catalogue = try LocalizationCatalogFixture.catalogueMessageIDs(
            at: LocalizationCatalogFixture.russianCatalogueURL,
        )
        let missing = source.subtracting(catalogue).sorted()
        #expect(
            missing.isEmpty,
            """
            \(missing.count) source msgid(s) have no entry in po/ru.po. Strings \
            containing quote characters are the usual casualty — a regex \
            extractor splits the literal and files the halves instead:
            \(missing.prefix(20).map { "  - \($0.debugDescription)" }.joined(separator: "\n"))
            """,
        )
    }

    @Test("The catalogue carries no entries the source never asks for")
    func catalogueCarriesNoEntriesTheSourceNeverAsksFor() async throws {
        let source = try await LocalizationCatalogFixture.sourceMessageIDs()
        let catalogue = try LocalizationCatalogFixture.catalogueMessageIDs(
            at: LocalizationCatalogFixture.russianCatalogueURL,
        )
        let orphans = catalogue.subtracting(source)
            .subtracting(LocalizationCatalogFixture.permittedOrphans)
            .sorted()
        #expect(
            orphans.isEmpty,
            """
            \(orphans.count) catalogue entry/entries match nothing in Sources/. \
            Leftover fragments and translated dialog response IDs both land \
            here. If the msgid is still referenced in the source, the scanner \
            has lost sight of it (e.g. a wrapped String(format: nlocalized(...)) \
            call across lines); look for a multi-line literal before \
            regenerating:
            \(orphans.prefix(20).map { "  - \($0.debugDescription)" }.joined(separator: "\n"))
            """,
        )
    }

    /// A `.pot` template is the mechanism that keeps the catalogue convergent.
    /// Without one, every fix is a hand-append that leaves the previous debris
    /// in place — which is how the same mangled msgids survived five rounds.
    @Test("A catalogue template exists and covers every source string")
    func catalogueTemplateExistsAndCoversEverySourceString() async throws {
        let template = LocalizationCatalogFixture.templateURL
        #expect(
            FileManager.default.fileExists(atPath: template.path),
            "no template at po/\(template.lastPathComponent) — generate it from the source instead of hand-editing po/ru.po",
        )
        guard FileManager.default.fileExists(atPath: template.path) else { return }

        let source = try await LocalizationCatalogFixture.sourceMessageIDs()
        let templated = try LocalizationCatalogFixture.catalogueMessageIDs(at: template)
        let missing = source.subtracting(templated).sorted()
        #expect(
            missing.isEmpty,
            """
            the template is missing \(missing.count) source msgid(s), so \
            regenerating from it would silently drop them:
            \(missing.prefix(20).map { "  - \($0.debugDescription)" }.joined(separator: "\n"))
            """,
        )
    }

    /// A translation that reverted to English silently ships the source
    /// strings to users. The specifier tests skip empty translations by
    /// design, and the coverage test only checks that a msgid has a key —
    /// neither catches an empty msgstr.
    @Test("Russian translations are not empty")
    func russianTranslationsAreNotEmpty() throws {
        let entries = try LocalizationCatalogFixture.entries(
            at: LocalizationCatalogFixture.russianCatalogueURL,
        )
        let empty = entries.filter { entry in
            entry.translations.contains { $0.isEmpty }
        }
        #expect(
            empty.isEmpty,
            """
            \(empty.count) entry/entries have an empty Russian translation
            (msgstr is blank for singular, or any form is blank for plural):
            \(empty.map { "  - \($0.singular.debugDescription)" }.joined(separator: "\n"))
            """,
        )
    }

    // MARK: - Plural entries

    /// Russian selects form 0 for 1, 21, 31, 101… so a `msgstr[0]` that
    /// hardcodes the digit renders "21 notes" as "1 заметка". Every form has to
    /// keep whatever specifier its msgid declares.
    @Test("Plural entries keep their format specifier in every form")
    func pluralEntriesKeepTheirFormatSpecifierInEveryForm() throws {
        let entries = try LocalizationCatalogFixture.pluralEntries(
            at: LocalizationCatalogFixture.russianCatalogueURL,
        )
        #expect(!entries.isEmpty, "expected plural entries in po/ru.po")

        for entry in entries {
            let expected = LocalizationCatalogFixture.formatSpecifiers(in: entry.singular)
            #expect(
                entry.translations.count == 3,
                "\(entry.singular.debugDescription) has \(entry.translations.count) form(s); Russian needs 3",
            )
            for (index, translation) in entry.translations.enumerated() where !translation.isEmpty {
                #expect(
                    LocalizationCatalogFixture.formatSpecifiers(in: translation) == expected,
                    """
                    \(entry.singular.debugDescription) msgstr[\(index)] = \
                    \(translation.debugDescription) does not carry the msgid's \
                    specifiers \(expected.sorted())
                    """,
                )
            }
        }
    }

    /// A translation has to carry exactly the specifiers its msgid declares.
    /// `String(format:)` matches them positionally, so a missing one shifts
    /// every later argument into the wrong slot and an extra one reads past the
    /// end of the argument list.
    @Test("Translations carry the same format specifiers as their msgid")
    func translationsCarryTheSameFormatSpecifiersAsTheirMsgid() throws {
        let mismatches = try LocalizationCatalogFixture
            .entries(at: LocalizationCatalogFixture.russianCatalogueURL)
            .filter { entry in
                guard entry.plural == nil, let translation = entry.translations.first,
                      !translation.isEmpty else { return false }
                return LocalizationCatalogFixture.formatSpecifiers(in: entry.singular)
                    != LocalizationCatalogFixture.formatSpecifiers(in: translation)
            }
            .map { entry in
                "  - \(entry.singular.debugDescription)\n    -> \(entry.translations[0].debugDescription)"
            }
        #expect(
            mismatches.isEmpty,
            """
            \(mismatches.count) translation(s) do not carry their msgid's format \
            specifiers:
            \(mismatches.prefix(12).joined(separator: "\n"))
            """,
        )
    }

    /// `msgmerge` pairs a new msgid with the most similar old one and copies its
    /// translation across, flagging the guess `#, fuzzy`. That is a proposal,
    /// not a translation — merging the template over a catalogue full of
    /// mangled fragments produced exactly the wrong pairings, and shipping them
    /// unreviewed is worse than shipping English.
    @Test("The catalogue contains no unreviewed fuzzy translations")
    func catalogueContainsNoUnreviewedFuzzyTranslations() throws {
        let catalogue = try String(
            contentsOf: LocalizationCatalogFixture.russianCatalogueURL,
            encoding: .utf8,
        )
        let fuzzy = catalogue
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#,") }
            .filter {
                let flags = $0.split(separator: ",")
                return flags.contains { $0.trimmingCharacters(in: .whitespaces) == "fuzzy" }
            }
        #expect(
            fuzzy.isEmpty,
            """
            \(fuzzy.count) entry/entries are marked fuzzy. Review each one, \
            fix the translation, and drop the flag. Emptying is acceptable \
            only as a temporary step; the completeness test will then hold \
            the line.
            """,
        )
    }

    /// Every `nlocalized` pair the source asks for must be a real plural entry.
    /// Two separate singular entries make `ngettext` return form 0 for every
    /// count, which reads as a grammatical error rather than a missing string.
    @Test("Every nlocalized pair is a plural entry in the catalogue")
    func everyNlocalizedPairIsAPluralEntryInTheCatalogue() async throws {
        let pairs = try await LocalizationCatalogFixture.sourcePluralPairs()
        #expect(!pairs.isEmpty, "expected nlocalized call sites in Sources/")

        let entries = try LocalizationCatalogFixture.pluralEntries(
            at: LocalizationCatalogFixture.russianCatalogueURL,
        )
        let declared = Set(entries.map { $0.singular })
        for pair in pairs {
            #expect(
                declared.contains(pair.singular),
                "nlocalized(\(pair.singular.debugDescription), \(pair.plural.debugDescription)) has no msgid_plural entry",
            )
        }
    }

    // MARK: - Compiled catalogue

    @Test("The source po file is well formed")
    func sourcePoFileIsWellFormed() throws {
        let msgfmt = try #require(
            LocalizationCatalogFixture.toolURL(named: "msgfmt"),
            "msgfmt not found — install gettext; the build needs it to produce the catalogue",
        )
        let discard = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-check-\(UUID().uuidString).mo", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: discard) }

        let diagnostics = try LocalizationCatalogFixture.run(
            msgfmt,
            ["--check", "-o", discard.path, LocalizationCatalogFixture.russianCatalogueURL.path],
        )
        #expect(
            diagnostics.status == 0,
            "msgfmt --check rejected po/ru.po: \(diagnostics.stderr)",
        )
    }

    /// The shipped `.mo` is what the app actually loads, so a `po/ru.po` edit
    /// that never got recompiled means the fix is invisible to users.
    ///
    /// Compared by content rather than by bytes: `PO-Revision-Date` moves on
    /// every edit and says nothing about what the catalogue contains, so a byte
    /// comparison would fail on a meaningless header bump.
    @Test("The compiled catalogue carries the same translations as the po file")
    func compiledCatalogueCarriesTheSameTranslationsAsThePoFile() throws {
        let msgfmt = try #require(
            LocalizationCatalogFixture.toolURL(named: "msgfmt"),
            "msgfmt not found — install gettext",
        )
        let msgunfmt = try #require(
            LocalizationCatalogFixture.toolURL(named: "msgunfmt"),
            "msgunfmt not found — install gettext",
        )
        #expect(
            FileManager.default.fileExists(atPath: LocalizationCatalogFixture.compiledCatalogueURL.path),
            "no compiled catalogue — run scripts/build-locales.sh",
        )
        guard FileManager.default.fileExists(atPath: LocalizationCatalogFixture.compiledCatalogueURL.path) else {
            return
        }

        let fresh = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-fresh-\(UUID().uuidString).mo", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: fresh) }
        _ = try LocalizationCatalogFixture.run(
            msgfmt,
            ["-o", fresh.path, LocalizationCatalogFixture.russianCatalogueURL.path],
        )

        let expected = try LocalizationCatalogFixture.run(msgunfmt, [fresh.path]).stdout
        let shipped = try LocalizationCatalogFixture.run(
            msgunfmt,
            [LocalizationCatalogFixture.compiledCatalogueURL.path],
        ).stdout
        #expect(
            LocalizationCatalogFixture.stripVolatileHeaders(shipped)
                == LocalizationCatalogFixture.stripVolatileHeaders(expected),
            "the shipped .mo does not match po/ru.po — recompile it with scripts/build-locales.sh",
        )
    }

    // MARK: - Source lints

    /// `%s` expects a C string. Handed a Swift `String`, Foundation on Linux
    /// substitutes nothing at all, so the argument silently vanishes from
    /// user-visible text in every language.
    @Test("No localized format string uses %s")
    func noLocalizedFormatStringUsesPercentS() async throws {
        let offenders = try await LocalizationCatalogFixture.sourceMessageIDs()
            .filter { $0.contains("%s") }
            .sorted()
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) localized string(s) use %s, which yields an empty \
            substitution on Linux Foundation — use %@:
            \(offenders.map { "  - \($0.debugDescription)" }.joined(separator: "\n"))
            """,
        )
    }

    /// `nlocalized` only picks the form; the specifier survives in the returned
    /// template. A call site that forgets `String(format:)` prints a literal
    /// `%d` to the user.
    @Test("Plural-aware call sites substitute their count")
    func pluralAwareCallSitesSubstituteTheirCount() throws {
        let offenders = try LocalizationCatalogFixture.unformattedPluralCallSites()
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) nlocalized call site(s) whose msgid contains a \
            specifier are not wrapped in String(format:), so the count is never \
            substituted:
            \(offenders.map { "  - \($0)" }.joined(separator: "\n"))
            """,
        )
    }

    /// A msgid in the catalogue proves the string is meant to be translated.
    /// A call site that writes the same literal without `.localized` therefore
    /// shows English to a Russian user while a finished translation sits in the
    /// catalogue unused — invisible to every other test here, because the
    /// extractor only ever sees the sites that *are* marked.
    @Test("Every call site of a translatable string is localized")
    func everyCallSiteOfATranslatableStringIsLocalized() throws {
        let offenders = try LocalizationCatalogFixture.unlocalizedCatalogueLiterals()
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) literal(s) match a catalogue msgid but are not \
            marked .localized, so they stay English no matter what the \
            catalogue says. Add .localized, or — if the literal is a canonical \
            key rather than user-visible text — list it in \
            LocalizationCatalogFixture.permittedBareLiterals with a reason:
            \(offenders.map { "  - \($0)" }.joined(separator: "\n"))
            """,
        )
    }

    /// `ngettext` picks a form from the count even when the message never
    /// prints it. Russian form 1 (2–4) and form 2 (5+) differ only by the
    /// number that would precede them, so for a countless message the two must
    /// read identically — otherwise adding a fifth image turns a correct toast
    /// into "Изображений добавлено в заметку".
    @Test("A plural entry that prints no count reads the same for every plural form")
    func pluralEntryThatPrintsNoCountReadsTheSameForEveryPluralForm() throws {
        let entries = try LocalizationCatalogFixture.pluralEntries(
            at: LocalizationCatalogFixture.russianCatalogueURL,
        )
        for entry in entries {
            guard LocalizationCatalogFixture.formatSpecifiers(in: entry.singular).isEmpty,
                  LocalizationCatalogFixture.formatSpecifiers(in: entry.plural).isEmpty
            else { continue }
            let pluralForms = Set(entry.translations.dropFirst())
            #expect(
                pluralForms.count <= 1,
                """
                \(entry.singular.debugDescription) substitutes no count, so \
                nothing on screen distinguishes 2 from 5 — yet its plural forms \
                differ: \(entry.translations.dropFirst().map(\.debugDescription).joined(separator: " vs "))
                """,
            )
        }
    }

    // MARK: - Packaging

    /// `localeDirectoryPath()` probes `<App>.app/Contents/Resources/locale` on
    /// macOS. Compiling the catalogue without installing it there leaves that
    /// branch dead and the shipped app English.
    @Test("The macOS bundler installs the catalogue into the app bundle")
    func macOSBundlerInstallsTheCatalogueIntoTheAppBundle() throws {
        let script = try String(
            contentsOf: LocalizationCatalogFixture.packageRoot
                .appendingPathComponent("scripts/bundle-macos-app.sh"),
            encoding: .utf8,
        )
        #expect(
            script.contains("Contents/Resources/locale") || script.contains("RESOURCES_DIR/locale"),
            "bundle-macos-app.sh compiles the catalogue but never copies it into Contents/Resources/locale",
        )
        #expect(
            !script.contains("build-locales.sh\" || true"),
            "the bundler swallows a build-locales.sh failure, so a missing msgfmt ships an English app silently",
        )
    }
}

// MARK: - Fixture

/// Shared parsing helpers. Kept separate from the test bodies so the intent of
/// each assertion stays readable.
private enum LocalizationCatalogFixture {
    /// Catalogue entries that legitimately have no matching `.localized` call:
    /// the gettext header, plus anything a future maintainer deliberately keeps.
    static let permittedOrphans: Set<String> = [""]

    static let packageRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent() // SwiftyNotesTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // <package root>

    static let russianCatalogueURL = packageRoot.appendingPathComponent("po/ru.po")

    static let templateURL = packageRoot
        .appendingPathComponent("po/me.spaceinbox.swiftynotes.pot")

    static let compiledCatalogueURL = packageRoot
        .appendingPathComponent("Sources/SwiftyNotes/locale/ru/LC_MESSAGES/me.spaceinbox.swiftynotes.mo")

    struct PluralPair: Hashable {
        let singular: String
        let plural: String
    }

    struct PluralEntry {
        let singular: String
        let plural: String
        let translations: [String]
    }

    // MARK: Source scanning — delegates to extract-i18n.swift

    private struct EmitResult: Codable {
        let singletons: [String]
        let plurals: [[String]]
    }

    private actor SourceScanner {
        private var cache: EmitResult? = nil
        var diagnostics: [String] = []

        func run() throws -> EmitResult {
            if let cached = cache {
                return cached
            }
            let scriptURL = LocalizationCatalogFixture.packageRoot
                .appendingPathComponent("scripts/extract-i18n.swift")
            // Find swift in PATH
            let swiftBin = { () -> URL? in
                guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
                for dir in path.split(separator: ":") {
                    let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("swift")
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
                return nil
            }()
            guard let swiftBin else { throw FixtureError.noJSONOutput }
            let process = Process()
            process.executableURL = swiftBin
            process.arguments = [scriptURL.path, "--emit-msgids"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()

            // Read both pipes concurrently so stderr overflow can't block stdout.
            let outQ = DispatchQueue(label: "swiftynotes.loc.out")
            let errQ = DispatchQueue(label: "swiftynotes.loc.err")
            let sem = DispatchSemaphore(value: 0)

            var outData = Data()
            var errData = Data()

        let outWork = DispatchWorkItem {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            sem.signal()
        }
        let errWork = DispatchWorkItem {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            sem.signal()
        }
        outQ.async(execute: outWork)
        errQ.async(execute: errWork)
        sem.wait()
        sem.wait()
            outWork.cancel()
            errWork.cancel()
            process.waitUntilExit()

            if let diagText = String(data: errData, encoding: .utf8),
               !diagText.isEmpty {
                diagnostics = diagText.components(separatedBy: "\n").filter { !$0.isEmpty }
            }

            guard let json = String(data: outData, encoding: .utf8) else {
                throw FixtureError.noJSONOutput
            }
            let decoded = try JSONDecoder().decode(EmitResult.self, from: json.data(using: .utf8)!)
            cache = decoded
            return decoded
        }

        func getDiagnostics() -> [String] {
            diagnostics
        }
    }

    private static let scanner = SourceScanner()
    private enum FixtureError: Error {
        case noJSONOutput
    }

    /// Every msgid the source actually looks up: single-line literals followed
    /// by `.localized`, plus both halves of every `nlocalized` pair.
    static func sourceMessageIDs() async throws -> Set<String> {
        let result = try await scanner.run()
        let diags = await scanner.getDiagnostics()
        if !diags.isEmpty {
            throw FixtureError.noJSONOutput
        }
        var ids = Set(result.singletons)
        for pair in result.plurals {
            if pair.count >= 2 {
                ids.insert(pair[0])
                ids.insert(pair[1])
            }
        }
        return ids
    }

    static func sourcePluralPairs() async throws -> Set<PluralPair> {
        let result = try await scanner.run()
        let diags = await scanner.getDiagnostics()
        if !diags.isEmpty {
            throw FixtureError.noJSONOutput
        }
        var pairs: Set<PluralPair> = []
        for arr in result.plurals {
            if arr.count >= 2 {
                pairs.insert(PluralPair(singular: arr[0], plural: arr[1]))
            }
        }
        return pairs
    }

    /// `nlocalized` call sites whose selected msgid declares a specifier but
    /// which are not handed to `String(format:)` on the same line.
    static func unformattedPluralCallSites() throws -> [String] {
        var offenders: [String] = []
        let root = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return offenders
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                let trimmed = lineText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), lineText.contains("nlocalized(") else { continue }
                guard let pairs = try? scanPluralPairs(in: lineText) else { continue }
                guard pairs.contains(where: { !formatSpecifiers(in: $0.singular).isEmpty }) else { continue }
                guard !lineText.contains("String(format:") else { continue }
                offenders.append("\(relative):\(offset + 1): \(trimmed)")
            }
        }
        return offenders.sorted()
    }

    private static func scanPluralPairs(in line: String) throws -> Set<PluralPair>? {
        var pairs: Set<PluralPair> = []
        var search = line.startIndex
        while let call = line.range(of: "nlocalized(", range: search ..< line.endIndex) {
            let afterOpen = line.index(after: call.upperBound)
            let rest = line[afterOpen...]
            var literals: [String] = []
            var scan = rest.startIndex
            while literals.count < 2, scan < rest.endIndex {
                if rest[scan] == "\"" {
                    var body = ""
                    var closed = false
                    var c = line.index(after: scan)
                    while c < rest.endIndex {
                        let ch = line[c]
                        if ch == "\\" {
                            let nx = line.index(after: c)
                            guard nx < rest.endIndex else { break }
                            body.append(ch)
                            body.append(line[nx])
                            c = line.index(after: nx)
                            continue
                        }
                        if ch == "\"" {
                            closed = true
                            c = line.index(after: c)
                            break
                        }
                        body.append(ch)
                        c = line.index(after: c)
                    }
                    if closed, let unescaped = unescape(body) {
                        literals.append(unescaped)
                    }
                    scan = c
                } else if rest[scan] == "," || rest[scan] == " " || rest[scan] == "\t" {
                    scan = line.index(after: scan)
                } else {
                    break
                }
            }
            if literals.count >= 2 {
                pairs.insert(PluralPair(singular: literals[0], plural: literals[1]))
            }
            search = call.upperBound
        }
        return pairs.isEmpty ? nil : pairs
    }

    /// Literals that match a catalogue msgid but must stay bare, keyed by the
    /// source file that holds them. These are canonical keys and seed content,
    /// not user-visible chrome: translating them breaks a lookup or rewrites a
    /// note's body.
    static let permittedBareLiterals: [String: Set<String>] = [
        // Seed note body — sample prose, not UI chrome.
        "Sources/SwiftyNotes/Storage/MarkdownShowcaseSeed.swift": ["Editor", "Split", "Preview"],
        // On-disk directory name.
        "Sources/SwiftyNotes/Storage/NotesRepository.swift": ["assets"],
        // Debug/introspection dictionary keys; the displayed values beside them
        // are localized, and the tests address these sections in English.
        "Sources/SwiftyNotes/UI/ExternalDocumentWindow.swift": ["Document"],
        "Sources/SwiftyNotes/UI/MainWindowPreviewPane.swift": ["Library", "Help"],
        // Context-menu handler keys — debugInvokeContextMenuAction(label:)
        // looks actions up by their canonical English label.
        "Sources/SwiftyNotes/UI/MainWindowActionsAndFiles.swift": [
            "Rename note…", "Duplicate note", "Move to…", "Export note…", "Copy note ID", "Delete…",
        ],
        // "Editor"/"Split"/"Preview": placeholder labels, replaced wholesale by
        // configureViewModeToggleContent() before the window is presented.
        // "Save"/"Delete": MacOSClickWorkaround labels, which only reach
        // debugLog.
        "Sources/SwiftyNotes/UI/MainWindow.swift": [
            "Editor", "Split", "Preview", "Save", "Delete",
        ],
    ]

    /// Literals in `Sources/` that appear verbatim in the catalogue yet carry
    /// no `.localized`. Lines that hand their literals to `nlocalized` are
    /// skipped — that call localizes them itself.
    static func unlocalizedCatalogueLiterals() throws -> [String] {
        let catalogue = try catalogueMessageIDs(at: russianCatalogueURL)
        var offenders: [String] = []
        let root = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return offenders
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
            let permitted = permittedBareLiterals[relative] ?? []
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                let trimmed = lineText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !lineText.contains("nlocalized(") else { continue }
                for hit in stringLiterals(in: lineText) {
                    guard let literal = unescape(hit.literal),
                          !literal.isEmpty,
                          catalogue.contains(literal),
                          !permitted.contains(literal)
                    else { continue }
                    let rest = lineText[hit.end...].drop(while: { $0 == " " })
                    guard !rest.hasPrefix(".localized") else { continue }
                    offenders.append("\(relative):\(offset + 1): \(literal.debugDescription)")
                }
            }
        }
        return offenders.sorted()
    }

    // MARK: PO parsing (keeps its own stringLiterals + unescape)

    static func catalogueMessageIDs(at url: URL) throws -> Set<String> {
        var ids: Set<String> = []
        for entry in try parse(url) {
            ids.insert(entry.singular)
            if let plural = entry.plural {
                ids.insert(plural)
            }
        }
        ids.remove("")
        return ids
    }

    static func pluralEntries(at url: URL) throws -> [PluralEntry] {
        try parse(url).compactMap { entry in
            guard let plural = entry.plural else { return nil }
            return PluralEntry(
                singular: entry.singular,
                plural: plural,
                translations: entry.translations,
            )
        }
    }

    struct Entry {
        let singular: String
        let plural: String?
        let translations: [String]
    }

    static func entries(at url: URL) throws -> [Entry] {
        try parse(url)
            .filter { !$0.singular.isEmpty }
            .map { Entry(singular: $0.singular, plural: $0.plural, translations: $0.translations) }
    }

    private struct RawEntry {
        var singular = ""
        var plural: String?
        var translations: [String] = []
    }

    /// Minimal gettext PO reader: enough for msgid / msgid_plural / msgstr and
    /// their continuation lines, which is all these assertions need.
    private static func parse(_ url: URL) throws -> [RawEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [RawEntry] = []
        var current = RawEntry()
        var field: Field?
        var started = false

        enum Field {
            case singular
            case plural
            case translation(Int)
        }

        func flush() {
            if started {
                entries.append(current)
            }
            current = RawEntry()
            started = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("msgid_plural") {
                field = .plural
                current.plural = ""
            } else if line.hasPrefix("msgid") {
                flush()
                started = true
                field = .singular
            } else if line.hasPrefix("msgstr[") {
                let digits = line.drop(while: { $0 != "[" }).dropFirst().prefix(while: { $0.isNumber })
                let index = Int(digits) ?? 0
                while current.translations.count <= index {
                    current.translations.append("")
                }
                field = .translation(index)
            } else if line.hasPrefix("msgstr") {
                current.translations = [""]
                field = .translation(0)
            } else if !line.hasPrefix("\"") {
                continue
            }

            guard let field, let literal = stringLiterals(in: line).first?.literal,
                  let value = unescape(literal) else { continue }
            switch field {
            case .singular: current.singular += value
            case .plural: current.plural = (current.plural ?? "") + value
            case let .translation(index):
                while current.translations.count <= index {
                    current.translations.append("")
                }
                current.translations[index] += value
            }
        }
        flush()
        return entries
    }

    /// Scans one line for double-quoted literals, honouring backslash escapes.
    /// Returns the raw (still-escaped) body and the index just past the closing
    /// quote. Used by the PO parser.
    private static func stringLiterals(in line: String) -> [(literal: String, end: String.Index)] {
        var results: [(String, String.Index)] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "\"" else {
                index = line.index(after: index)
                continue
            }
            var cursor = line.index(after: index)
            var body = ""
            var closed = false
            while cursor < line.endIndex {
                let character = line[cursor]
                if character == "\\" {
                    let next = line.index(after: cursor)
                    guard next < line.endIndex else { break }
                    body.append(character)
                    body.append(line[next])
                    cursor = line.index(after: next)
                    continue
                }
                if character == "\"" {
                    closed = true
                    cursor = line.index(after: cursor)
                    break
                }
                body.append(character)
                cursor = line.index(after: cursor)
            }
            guard closed else { break }
            results.append((body, cursor))
            index = cursor
        }
        return results
    }

    /// Unescapes a single-quoted Swift string literal body. Used by the PO
    /// parser, which reads PO files that may contain escaped characters.
    private static func unescape(_ raw: String) -> String? {
        var output = ""
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                output.append(character)
                continue
            }
            guard let escaped = iterator.next() else { return nil }
            switch escaped {
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "r": output.append("\r")
            case "0": output.append("\0")
            case "\"": output.append("\"")
            case "\\": output.append("\\")
            default: return nil
            }
        }
        return output
    }

    // MARK: Misc

    static func formatSpecifiers(in text: String) -> [String] {
        var specifiers: [String] = []
        var index = text.startIndex
        while let percent = text[index...].firstIndex(of: "%") {
            let next = text.index(after: percent)
            guard next < text.endIndex else { break }
            let character = text[next]
            if character != "%" {
                specifiers.append("%\(character)")
            }
            index = text.index(after: next)
        }
        return specifiers.sorted()
    }

    struct ToolResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs an external process, reading stdout and stderr concurrently so a
    /// full stderr pipe cannot block reading stdout.
    static func run(_ executable: URL, _ arguments: [String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let outQ = DispatchQueue(label: "swiftynotes.loc.run.out")
        let errQ = DispatchQueue(label: "swiftynotes.loc.run.err")
        let sem = DispatchSemaphore(value: 0)

        var outData = Data()
        var errData = Data()

        let outWork = DispatchWorkItem {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            sem.signal()
        }
        let errWork = DispatchWorkItem {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            sem.signal()
        }
        outQ.async(execute: outWork)
        errQ.async(execute: errWork)
        sem.wait()
        sem.wait()
        outWork.cancel()
        errWork.cancel()
        process.waitUntilExit()

        return ToolResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
        )
    }

    /// Drops header fields that change on every edit without changing what the
    /// catalogue translates.
    static func stripVolatileHeaders(_ catalogue: String) -> String {
        let volatile = ["\"PO-Revision-Date:", "\"POT-Creation-Date:", "\"X-Generator:"]
        return catalogue
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !volatile.contains { trimmed.hasPrefix($0) }
            }
            .joined(separator: "\n")
    }

    static func toolURL(named name: String) -> URL? {
        for directory in ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
