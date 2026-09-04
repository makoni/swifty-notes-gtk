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
        let metadata = try LocalizationCatalogFixture.metadataMessageIDs()
        let orphans = catalogue.subtracting(source)
            .subtracting(metadata)
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
                "\(entry.lookupKey.debugDescription) has \(entry.translations.count) form(s); Russian needs 3",
            )
            for (index, translation) in entry.translations.enumerated() where !translation.isEmpty {
                #expect(
                    LocalizationCatalogFixture.formatSpecifiers(in: translation) == expected,
                    """
                    \(entry.lookupKey.debugDescription) msgstr[\(index)] = \
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
                "  - \(entry.lookupKey.debugDescription)\n    -> \(entry.translations[0].debugDescription)"
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
        // Keyed with the context, so a plural asked for under a `msgctxt`
        // needs a plural entry *under that context* — the bare entry of the
        // same msgid would never be reached.
        let declared = Set(entries.map(\.lookupKey))
        for pair in pairs {
            #expect(
                declared.contains(pair.lookupKey),
                """
                \(pair.lookupKey.debugDescription) / \(pair.plural.debugDescription) is asked for \
                as a plural but has no msgid_plural entry, so ngettext returns \
                form 0 for every count
                """,
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
    func pluralAwareCallSitesSubstituteTheirCount() async throws {
        let offenders = try await LocalizationCatalogFixture.unformattedPluralCallSites()
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
    func everyCallSiteOfATranslatableStringIsLocalized() async throws {
        // Metadata-only msgids prove nothing about Swift code. The desktop
        // entry's keywords are "notes", "markdown", "cli"; the metainfo names
        // the app and its developer. Those collide with ordinary identifiers
        // — a directory name, a file extension, a window title — that must
        // stay bare. A msgid the Swift scanner also sees stays guarded, so a
        // real UI string is still caught when one of its call sites drops
        // `.localized`.
        // Bare msgids on both sides: the guard compares plain English
        // literals, so subtracting lookup keys would leave a context-qualified
        // string looking metadata-only and drop it from the guard.
        let source = try await LocalizationCatalogFixture.sourceBareMessageIDs()
        let metadataOnly = try LocalizationCatalogFixture.metadataMessageIDs()
            .subtracting(source)
        let offenders = try await LocalizationCatalogFixture.unlocalizedCatalogueLiterals(
            ignoring: metadataOnly,
        )
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

    /// The guard's own behaviour, on a source tree written for it.
    ///
    /// Driven only by the real `Sources/`, `everyCallSiteOfATranslatableStringIsLocalized`
    /// asserts an empty list against an empty list: every candidate there is
    /// metadata-only and filtered out, so the assertion held whether the
    /// guard worked or returned nothing. Each rewrite of how it decides —
    /// three of them — went in with that as its only coverage.
    @Test("The bare-literal guard reports what is bare and spares what is not")
    func theBareLiteralGuardReportsWhatIsBareAndSparesWhatIsNot() throws {
        let source = #"""
        let a = "Preview".localized
        let b = "Preview"
        let c = view.set(localizedWithContext("view mode", "Preview"), "Preview")
        let d = "Preview".localized // "Preview" in a comment
        let e = "Preview"
            .localized
        let f = "Preview".localizedLowercase
        let g = """
            "Preview" inside a multi-line literal
            """
        """#

        let scan = try LocalizationCatalogFixture.scan(source: source)
        let offenders = LocalizationCatalogFixture.unlocalizedLiterals(
            in: source,
            file: "Sources/Fixture.swift",
            scanned: scan.scannedLiterals.mapValues(Set.init),
            consumed: scan.consumedLiterals.mapValues(Set.init),
            catalogue: ["Preview"],
        )

        #expect(
            offenders == [
                // Line 2: bare, nothing localizes it.
                "Sources/Fixture.swift:2: \"Preview\"",
                // Line 3: the call localizes the second literal; the third is
                // a bare copy on the same line, which only its column
                // distinguishes.
                "Sources/Fixture.swift:3: \"Preview\"",
                // Line 7: `.localizedLowercase` is not a gettext lookup.
                "Sources/Fixture.swift:7: \"Preview\"",
            ],
            "got: \(offenders)",
        )
    }

    @Test("A literal the extractor never scanned is not judged")
    func aLiteralTheExtractorNeverScannedIsNotJudged() throws {
        // The line opening a `"""` block is skipped by the extractor
        // outright, so nothing on it can be filed as a msgid — and nothing on
        // it can be reported as bare either. Judging it anyway reported a
        // correctly localized literal and told the developer to add a suffix
        // that was already there.
        let source = #"""
        let a = debugLog("Preview".localized, detail: """
            body
            """)
        """#

        let scan = try LocalizationCatalogFixture.scan(source: source)
        #expect(scan.scannedLiterals["Sources/Fixture.swift:1"] == nil)
        let offenders = LocalizationCatalogFixture.unlocalizedLiterals(
            in: source,
            file: "Sources/Fixture.swift",
            scanned: scan.scannedLiterals.mapValues(Set.init),
            consumed: scan.consumedLiterals.mapValues(Set.init),
            catalogue: ["Preview"],
        )
        #expect(offenders.isEmpty, "got: \(offenders)")
    }

    @Test("A permitted literal stays permitted")
    func aPermittedLiteralStaysPermitted() throws {
        let source = "let a = \"Preview\"\n"
        let scan = try LocalizationCatalogFixture.scan(source: source)
        let offenders = LocalizationCatalogFixture.unlocalizedLiterals(
            in: source,
            file: "Sources/Fixture.swift",
            scanned: scan.scannedLiterals.mapValues(Set.init),
            consumed: scan.consumedLiterals.mapValues(Set.init),
            catalogue: ["Preview"],
            permitted: ["Preview"],
        )
        #expect(offenders.isEmpty)
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
                \(entry.lookupKey.debugDescription) substitutes no count, so \
                nothing on screen distinguishes 2 from 5 — yet its plural forms \
                differ: \(entry.translations.dropFirst().map(\.debugDescription).joined(separator: " vs "))
                """,
            )
        }
    }

    /// The desktop entry and the AppStream metainfo are English templates;
    /// their translations come from `po/` at build time via
    /// `scripts/render-metadata.sh`. A hand-written `xml:lang` or `Name[xx]`
    /// in a template is a second, silent source of truth — it survives the
    /// merge and then disagrees with the catalogue as soon as one of them is
    /// edited.
    @Test("Metadata templates carry no hand-written translations")
    func metadataTemplatesCarryNoHandWrittenTranslations() throws {
        let metainfo = try String(
            contentsOf: LocalizationCatalogFixture.metainfoTemplateURL,
            encoding: .utf8,
        )
        #expect(
            !metainfo.contains("xml:lang="),
            """
            the metainfo template carries an xml:lang variant. Translations \
            belong in po/; scripts/render-metadata.sh merges them in.
            """,
        )

        let desktop = try String(
            contentsOf: LocalizationCatalogFixture.desktopTemplateURL,
            encoding: .utf8,
        )
        let localizedKeys = desktop
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.range(of: #"^[A-Za-z]+\[[a-zA-Z_@.-]+\]="#, options: .regularExpression) != nil }
        #expect(
            localizedKeys.isEmpty,
            """
            the desktop template carries translated keys: \
            \(localizedKeys.joined(separator: ", ")). Translations belong in \
            po/; scripts/render-metadata.sh merges them in.
            """,
        )
    }

    /// Every string the metadata templates expose must reach the catalogue,
    /// or it ships English in the store listing while the rest of the app is
    /// translated.
    @Test("The catalogue covers the packaging metadata too")
    func catalogueCoversThePackagingMetadataToo() throws {
        let metadata = try LocalizationCatalogFixture.metadataMessageIDs()
        try #require(!metadata.isEmpty, "xgettext or the AppStream ITS rules are missing")

        let catalogue = try LocalizationCatalogFixture.catalogueMessageIDs(
            at: LocalizationCatalogFixture.russianCatalogueURL,
        )
        let missing = metadata.subtracting(catalogue).sorted()
        #expect(
            missing.isEmpty,
            """
            \(missing.count) metadata string(s) are not in po/ru.po, so the \
            desktop entry or store listing stays English. Re-run \
            scripts/extract-i18n.sh and translate them:
            \(missing.prefix(10).map { "  - \($0.debugDescription)" }.joined(separator: "\n"))
            """,
        )
    }

    /// `po/LINGUAS` drives both the catalogue compilation and the metadata
    /// merge, so a language present as a `.po` but missing from LINGUAS
    /// silently ships untranslated metadata.
    @Test("Every catalogue in po/ is listed in LINGUAS")
    func everyCatalogueInPoIsListedInLinguas() throws {
        let poDirectory = LocalizationCatalogFixture.packageRoot
            .appendingPathComponent("po", isDirectory: true)
        let catalogues = try FileManager.default
            .contentsOfDirectory(at: poDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "po" }
            .map { $0.deletingPathExtension().lastPathComponent }

        let linguas = try String(
            contentsOf: poDirectory.appendingPathComponent("LINGUAS", isDirectory: false),
            encoding: .utf8,
        )
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let unlisted = Set(catalogues).subtracting(linguas).sorted()
        #expect(
            unlisted.isEmpty,
            "\(unlisted.joined(separator: ", ")) has a .po but is missing from po/LINGUAS",
        )
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
        /// `nil` for a plural without a `msgctxt`.
        let context: String?
        let singular: String
        let plural: String

        /// gettext's own key for the singular form.
        var lookupKey: String {
            guard let context else { return singular }
            return "\(context)\u{4}\(singular)"
        }
    }

    struct PluralEntry {
        let context: String?
        let singular: String
        let plural: String
        let translations: [String]

        /// How to name this entry in a failure message. Two entries can share
        /// a singular and differ only in context, so the msgid alone is
        /// ambiguous the moment any string is context-qualified.
        var lookupKey: String {
            guard let context else { return singular }
            return "\(context)\u{4}\(singular)"
        }
    }

    // MARK: Source scanning — delegates to extract-i18n.swift

    /// What `extract-i18n.swift --emit-msgids` reports: one entry per
    /// catalogue key, whatever call form asked for it, with every place that
    /// asks. The sites are what let these guards name a bad call site without
    /// scanning `Sources/` a second time — a second scanner is how the list of
    /// localizing keywords drifted out of step with the extractor before.
    struct EmitResult: Codable {
        struct Entry: Codable {
            /// Absent for a bare lookup.
            let context: String?
            let singular: String
            /// Absent for a non-plural lookup.
            let plural: String?
            /// `file:line`, ordered by file and then line.
            let sites: [String]

            /// gettext's own key for the singular form.
            var lookupKey: String {
                guard let context else { return singular }
                return "\(context)\u{4}\(singular)"
            }

            /// gettext's own key for the plural form, when there is one.
            var pluralLookupKey: String? {
                guard let plural else { return nil }
                guard let context else { return plural }
                return "\(context)\u{4}\(plural)"
            }
        }

        let entries: [Entry]

        /// Character offsets, per `file:line`, of the opening quotes a
        /// localizing call consumes.
        let consumedLiterals: [String: [Int]]

        /// Character offsets, per `file:line`, of every literal the extractor
        /// considered — comments, raw literals and `"""` lines already
        /// decided.
        let scannedLiterals: [String: [Int]]
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
            guard let swift = ToolRunner.onPath("swift") else { throw FixtureError.noJSONOutput }
            let result = try ToolRunner.run(swift, [scriptURL.path, "--emit-msgids"])

            if !result.stderr.isEmpty {
                diagnostics = result.stderr.components(separatedBy: "\n").filter { !$0.isEmpty }
            }
            guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
                // The extractor prints nothing when it refuses the tree, so a
                // diagnostic is the answer here rather than a parse failure.
                throw diagnostics.isEmpty
                    ? FixtureError.noJSONOutput
                    : FixtureError.diagnostics(diagnostics)
            }
            let decoded = try JSONDecoder().decode(EmitResult.self, from: data)
            cache = decoded
            return decoded
        }

        func getDiagnostics() -> [String] {
            diagnostics
        }
    }

    private static let scanner = SourceScanner()
    private enum FixtureError: Error, CustomStringConvertible {
        case noJSONOutput
        /// The extractor refused to run and said why. Carrying the text
        /// matters: the message names the call site to fix, and reporting
        /// `noJSONOutput` instead points at a broken subprocess.
        case diagnostics([String])

        var description: String {
            switch self {
            case .noJSONOutput:
                "extract-i18n.swift produced no JSON"
            case let .diagnostics(lines):
                """
                extract-i18n.swift rejected the source tree:
                \(lines.map { "  - \($0)" }.joined(separator: "\n"))
                """
            }
        }
    }

    /// Every entry the source asks for, with its call sites.
    static func sourceEntries() async throws -> [EmitResult.Entry] {
        try await scanned().entries
    }

    /// Where a localizing call already localizes the literal in it, keyed by
    /// `file:line` and by the character offset of the literal's opening quote.
    static func consumedLiteralOffsets() async throws -> [String: Set<Int>] {
        try await scanned().consumedLiterals.mapValues(Set.init)
    }

    /// Every literal the extractor considered, same keying.
    static func scannedLiteralOffsets() async throws -> [String: Set<Int>] {
        try await scanned().scannedLiterals.mapValues(Set.init)
    }

    private static func scanned() async throws -> EmitResult {
        let result = try await scanner.run()
        let diagnostics = await scanner.getDiagnostics()
        if !diagnostics.isEmpty {
            throw FixtureError.diagnostics(diagnostics)
        }
        return result
    }

    /// Every key the source can look a string up by — bare msgids, both
    /// halves of a plural pair, and the `context\u{4}msgid` form for anything
    /// qualified by a context, exactly as gettext keys them.
    static func sourceMessageIDs() async throws -> Set<String> {
        var ids: Set<String> = []
        for entry in try await sourceEntries() {
            ids.insert(entry.lookupKey)
            if let pluralKey = entry.pluralLookupKey {
                ids.insert(pluralKey)
            }
        }
        return ids
    }

    /// The bare msgids the source asks for, contexts stripped.
    ///
    /// The bare-literal guard needs these rather than lookup keys: moving a
    /// string under a `msgctxt` changes its key, and a guard that only knew
    /// keys would quietly stop noticing an unlocalized copy of that same
    /// English literal.
    static func sourceBareMessageIDs() async throws -> Set<String> {
        var ids: Set<String> = []
        for entry in try await sourceEntries() {
            ids.insert(entry.singular)
            if let plural = entry.plural {
                ids.insert(plural)
            }
        }
        return ids
    }

    static func sourcePluralPairs() async throws -> Set<PluralPair> {
        var pairs: Set<PluralPair> = []
        for entry in try await sourceEntries() {
            guard let plural = entry.plural else { continue }
            pairs.insert(PluralPair(context: entry.context, singular: entry.singular, plural: plural))
        }
        return pairs
    }

    /// Plural call sites whose selected msgid declares a format specifier but
    /// which are not handed to `String(format:)` on the same line.
    ///
    /// The sites come from the extractor rather than from a scanner of its
    /// own. The scanner this replaced matched the literal `"nlocalized("`,
    /// which is not a substring of `"nlocalizedWithContext("` — so it was
    /// blind to a keyword the extractor already understood, and would have
    /// stayed blind to the next one.
    static func unformattedPluralCallSites() async throws -> [String] {
        var offenders: [String] = []
        var lineCache: [String: [String]] = [:]
        for entry in try await sourceEntries() {
            guard entry.plural != nil, !formatSpecifiers(in: entry.singular).isEmpty else { continue }
            for site in entry.sites {
                guard let colon = site.lastIndex(of: ":"),
                      let number = Int(site[site.index(after: colon)...])
                else { continue }
                let relative = String(site[site.startIndex ..< colon])
                let lines: [String]
                if let cached = lineCache[relative] {
                    lines = cached
                } else {
                    let url = packageRoot.appendingPathComponent(relative)
                    lines = try String(contentsOf: url, encoding: .utf8)
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                    lineCache[relative] = lines
                }
                guard number >= 1, number <= lines.count else { continue }
                // The code, not the whole line: a `// TODO: wrap in
                // String(format:)` would otherwise answer for the call site
                // and hide a real offender.
                let text = codePortion(of: lines[number - 1])
                guard !text.contains("String(format:") else { continue }
                offenders.append("\(site): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        return offenders.sorted()
    }

    static let metainfoTemplateURL = packageRoot
        .appendingPathComponent("data/me.spaceinbox.swiftynotes.metainfo.xml.in")

    static let desktopTemplateURL = packageRoot
        .appendingPathComponent("data/me.spaceinbox.swiftynotes.desktop.in")

    /// msgids contributed by the AppStream metainfo and the desktop entry
    /// rather than by Swift source.
    ///
    /// Extracted with the same xgettext invocations `scripts/extract-i18n.sh`
    /// uses, so the tests cannot drift from the build.
    static func metadataMessageIDs() throws -> Set<String> {
        guard let xgettext = toolURL(named: "xgettext") else { return [] }
        let itsRules = "/usr/share/gettext/its/metainfo.its"
        guard FileManager.default.fileExists(atPath: itsRules) else { return [] }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var ids: Set<String> = []
        let extractions: [(arguments: [String], input: URL)] = [
            (["--from-code=UTF-8", "--its=\(itsRules)", "--omit-header"], metainfoTemplateURL),
            (["-L", "Desktop", "--omit-header"], desktopTemplateURL),
        ]
        for (index, extraction) in extractions.enumerated() {
            let output = scratch.appendingPathComponent("meta-\(index).pot", isDirectory: false)
            let result = try run(
                xgettext,
                extraction.arguments + ["--output=\(output.path)", extraction.input.path],
            )
            guard result.status == 0 else { continue }
            ids.formUnion(try catalogueMessageIDs(at: output))
        }
        return ids
    }

    /// Literals that match a catalogue msgid but must stay bare, keyed by the
    /// source file that holds them. These are canonical keys and seed content,
    /// not user-visible chrome: translating them breaks a lookup or rewrites a
    /// note's body.
    static let permittedBareLiterals: [String: Set<String>] = [
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

    /// The part of a line that is code: everything before a `//` outside a
    /// string literal.
    ///
    /// Used only by ``unformattedPluralCallSites()``, which asks whether a
    /// call site is wrapped in `String(format:)` and must not be answered by
    /// a mention in a comment. Everything else reads the extractor's own
    /// account of what it scanned rather than deciding again here — the
    /// extractor understands block comments, raw literals and the `"""` skip,
    /// and a second opinion that differs on any of them turns a correct call
    /// site into a reported offender.
    static func codePortion(of line: String) -> String {
        var index = line.startIndex
        var insideLiteral = false
        while index < line.endIndex {
            let character = line[index]
            if insideLiteral {
                if character == "\\" {
                    let next = line.index(after: index)
                    index = next < line.endIndex ? line.index(after: next) : next
                    continue
                }
                if character == "\"" {
                    insideLiteral = false
                }
                index = line.index(after: index)
                continue
            }
            if character == "\"" {
                insideLiteral = true
                index = line.index(after: index)
                continue
            }
            if character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" {
                    return String(line[line.startIndex ..< index])
                }
            }
            index = line.index(after: index)
        }
        return line
    }

    /// Literals in `Sources/` that appear verbatim in the catalogue yet are
    /// not localized.
    ///
    /// Both halves come from the extractor: which literals it considered, and
    /// which of those it localizes. This guard adds only the question the
    /// extractor cannot answer — is the text a catalogue msgid — because
    /// every earlier attempt to decide the rest here lost real offenders:
    ///
    /// * Skipping any line that mentioned a localizing call hid every literal
    ///   on it.
    /// * Skipping any literal whose *text* a call consumed hid a bare second
    ///   copy of the same string on the same line.
    /// * Recognising `.localized` here rather than asking the extractor got
    ///   the wrapped form backwards: the suffix is on the next line, so a
    ///   literal the extractor had already filed as a msgid was reported.
    /// * Cutting comments here meant a line the extractor skips outright —
    ///   one opening a `"""` block — was still judged, and reported a
    ///   correctly localized literal on it.
    /// * Walking back over the line counting parentheses counted the ones
    ///   inside string literals, so a msgid holding an unbalanced `(` turned
    ///   a correct call site into a reported offender.
    static func unlocalizedCatalogueLiterals(
        ignoring ignored: Set<String> = [],
    ) async throws -> [String] {
        // Bare msgids, not lookup keys: a string moved under a `msgctxt` is
        // still the same English literal, and a guard keyed on
        // `context\u{4}msgid` would quietly stop noticing an unlocalized copy
        // of it.
        let catalogue = try catalogueBareMessageIDs(at: russianCatalogueURL).subtracting(ignored)
        let consumed = try await consumedLiteralOffsets()
        let scanned = try await scannedLiteralOffsets()

        var offenders: [String] = []
        let root = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return offenders
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
            offenders += unlocalizedLiterals(
                in: text,
                file: relative,
                scanned: scanned,
                consumed: consumed,
                catalogue: catalogue,
                permitted: permittedBareLiterals[relative] ?? [],
            )
        }
        return offenders.sorted()
    }

    /// The decision, for one file, separated from walking the tree.
    ///
    /// Split out so it can be run against a source tree written for the
    /// occasion. Driven only by the real `Sources/`, the guard reports
    /// nothing — every candidate there is metadata-only and filtered — so
    /// `#expect(offenders.isEmpty)` passed identically whether the guard
    /// worked or returned an empty array, which is what it did after each of
    /// the rewrites listed above.
    static func unlocalizedLiterals(
        in text: String,
        file: String,
        scanned: [String: Set<Int>],
        consumed: [String: Set<Int>],
        catalogue: Set<String>,
        permitted: Set<String> = [],
    ) -> [String] {
        var offenders: [String] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let site = "\(file):\(offset + 1)"
            // A line the extractor did not scan — a comment, or one opening a
            // `"""` block — is not one this can judge either.
            guard let considered = scanned[site] else { continue }
            let localized = consumed[site] ?? []
            let lineText = String(line)
            for hit in stringLiterals(in: lineText) {
                let column = lineText.distance(from: lineText.startIndex, to: hit.start)
                guard considered.contains(column), !localized.contains(column) else { continue }
                guard let literal = unescape(hit.literal),
                      !literal.isEmpty,
                      catalogue.contains(literal),
                      !permitted.contains(literal)
                else { continue }
                offenders.append("\(site): \(literal.debugDescription)")
            }
        }
        return offenders.sorted()
    }

    /// Runs the extractor over a source tree of the caller's making.
    static func scan(source: String) throws -> EmitResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-guard-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try source.write(
            to: sources.appendingPathComponent("Fixture.swift", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )
        let script = packageRoot.appendingPathComponent("scripts/extract-i18n.swift")
        let swift = try #require(ToolRunner.onPath("swift"), "swift is not on PATH")
        let result = try ToolRunner.run(swift, [script.path, "--sources", sources.path, "--emit-msgids"])
        try #require(result.status == 0, "extraction failed:\n\(result.stderr)")
        let data = try #require(result.stdout.data(using: .utf8))
        return try JSONDecoder().decode(EmitResult.self, from: data)
    }

    // MARK: PO parsing (keeps its own stringLiterals + unescape)

    /// Every key the catalogue can be looked up by.
    ///
    /// A context-qualified entry is keyed `context\u{4}msgid`, exactly as
    /// gettext keys it — so the same English string carrying a context is a
    /// different key from the bare one, which is the whole point of having
    /// contexts.
    static func catalogueMessageIDs(at url: URL) throws -> Set<String> {
        var ids: Set<String> = []
        for entry in try parse(url) {
            ids.insert(entry.lookupKey)
            if let plural = entry.plural {
                if let context = entry.context {
                    ids.insert("\(context)\u{4}\(plural)")
                } else {
                    ids.insert(plural)
                }
            }
        }
        ids.remove("")
        return ids
    }

    /// The same msgids with their contexts stripped.
    ///
    /// For the guards that ask "is this English literal a translatable string"
    /// rather than "is this a catalogue key" — moving a string under a
    /// `msgctxt` must not take it out of their reach.
    static func catalogueBareMessageIDs(at url: URL) throws -> Set<String> {
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
                context: entry.context,
                singular: entry.singular,
                plural: plural,
                translations: entry.translations,
            )
        }
    }

    struct Entry {
        let context: String?
        let singular: String
        let plural: String?
        let translations: [String]

        /// How to name this entry in a failure message: two entries can share
        /// a singular and differ only in context, so the msgid alone stopped
        /// being unambiguous the moment any string gained one.
        var lookupKey: String {
            guard let context else { return singular }
            return "\(context)\u{4}\(singular)"
        }
    }

    static func entries(at url: URL) throws -> [Entry] {
        try parse(url)
            .filter { !$0.singular.isEmpty }
            .map {
                Entry(
                    context: $0.context,
                    singular: $0.singular,
                    plural: $0.plural,
                    translations: $0.translations,
                )
            }
    }

    private struct RawEntry {
        var context: String?
        var singular = ""
        var plural: String?
        var translations: [String] = []

        /// The key gettext looks entries up by: a context-qualified entry is a
        /// different entry from the bare msgid, separated by `\u{4}`.
        var lookupKey: String {
            guard let context else { return singular }
            return "\(context)\u{4}\(singular)"
        }
    }

    /// Minimal gettext PO reader: enough for msgid / msgid_plural / msgstr and
    /// their continuation lines, which is all these assertions need.
    private static func parse(_ url: URL) throws -> [RawEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [RawEntry] = []
        var current = RawEntry()
        var field: Field?
        var started = false
        var contextOpen = false

        enum Field {
            case context
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
            contextOpen = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("msgctxt") {
                flush()
                started = true
                contextOpen = true
                current.context = ""
                field = .context
            } else if line.hasPrefix("msgid_plural") {
                field = .plural
                current.plural = ""
            } else if line.hasPrefix("msgid") {
                // An entry starts at `msgid` unless a `msgctxt` line just
                // opened one. Keying off `current.context != nil` instead
                // would stop flushing for every entry that follows a
                // context-qualified one, silently concatenating the rest of
                // the catalogue into a single entry.
                if contextOpen {
                    contextOpen = false
                } else {
                    flush()
                    started = true
                }
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
            case .context: current.context = (current.context ?? "") + value
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
    private static func stringLiterals(
        in line: String,
    ) -> [(literal: String, start: String.Index, end: String.Index)] {
        var results: [(String, String.Index, String.Index)] = []
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
            results.append((body, index, cursor))
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

    /// Drops header fields that change on every edit without changing what the
    /// catalogue translates.
    static func stripVolatileHeaders(_ catalogue: String) -> String {
        catalogue
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // X-Generator says which tool last wrote the file, which is
                // exactly the kind of change that must not fail a test about
                // what the catalogue translates.
                return !trimmed.hasPrefix("\"POT-Creation-Date:")
                    && !trimmed.hasPrefix("\"PO-Revision-Date:")
                    && !trimmed.hasPrefix("\"X-Generator:")
            }
            .joined(separator: "\n")
    }

    static func toolURL(named name: String) -> URL? {
        ToolRunner.systemTool(name)
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> ToolRunner.Result {
        try ToolRunner.run(executable, arguments)
    }
}
