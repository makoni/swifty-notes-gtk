#if !os(macOS)
import Foundation
import Testing

/// What `scripts/extract-i18n.swift` does with call sites the app does not
/// happen to contain.
///
/// The extractor is the only thing standing between a translatable string and
/// a catalogue that never hears about it, and every guard in
/// `LocalizationCatalogTests` reads the world through it — so a defect here is
/// invisible to all of them. Driving it over a source tree written for the
/// occasion (`--sources`) is what makes its own behaviour testable, rather
/// than only its output for this app on this day.
@Suite(.serialized)
struct ExtractorTests {
    // MARK: - Every call form reaches the catalogue

    @Test("Each of the four call forms produces the entry gettext needs")
    func eachOfTheFourCallFormsProducesTheEntryGettextNeeds() throws {
        let entries = try extract(
            """
            let a = "Bare".localized
            let b = nlocalized("%d note", "%d notes", count: n)
            let c = localizedWithContext("view mode", "Preview")
            let d = nlocalizedWithContext("search", "%d match", "%d matches", count: n)
            """,
        )

        #expect(entries.contains(Entry(context: nil, singular: "Bare", plural: nil)))
        #expect(entries.contains(Entry(context: nil, singular: "%d note", plural: "%d notes")))
        #expect(entries.contains(Entry(context: "view mode", singular: "Preview", plural: nil)))
        #expect(
            entries.contains(Entry(context: "search", singular: "%d match", plural: "%d matches")),
            "the plural-with-context form had no call site in the app, so nothing had ever run it",
        )
        #expect(entries.count == 4)
    }

    @Test("A context plural emits msgctxt with both forms, in gettext's order")
    func aContextPluralEmitsMsgctxtWithBothFormsInGettextsOrder() throws {
        let pot = try template(
            """
            let d = nlocalizedWithContext("search", "%d match", "%d matches", count: n)
            """,
        ) { try String(contentsOf: $0, encoding: .utf8) }
        let block = try #require(
            pot.components(separatedBy: "\n\n").first { $0.contains("msgctxt \"search\"") },
            "no msgctxt block in the template",
        )
        #expect(
            block.split(separator: "\n").map(String.init) == [
                "msgctxt \"search\"",
                "msgid \"%d match\"",
                "msgid_plural \"%d matches\"",
                "msgstr[0] \"\"",
                "msgstr[1] \"\"",
            ],
            "got:\n\(block)",
        )
    }

    @Test("Awkward but legal Swift around a call still parses")
    func awkwardButLegalSwiftAroundACallStillParses() throws {
        // Splitting the argument list means handling what can appear inside
        // it: commas and quotes that belong to a literal, the call nested
        // inside another, two calls in one collection, and a literal argument
        // that follows the call and must not be mistaken for part of it.
        let entries = try extract(
            #"""
            let a = nlocalized("a, b", "c, d", count: n)
            let b = nlocalized("say \"hi\"", "say \"his\"", count: n)
            let c = String(format: nlocalized("%d x", "%d xs", count: n), n)
            let d = [localizedWithContext("one", "One"), localizedWithContext("two", "Two")]
            let e = view.set(label: localizedWithContext("three", "Three"), icon: "icon-name")
            let f = build { localizedWithContext("four", "Four (unbalanced") }
            """#,
        )

        #expect(entries.contains(Entry(context: nil, singular: "a, b", plural: "c, d")))
        #expect(entries.contains(Entry(context: nil, singular: #"say "hi""#, plural: #"say "his""#)))
        #expect(entries.contains(Entry(context: nil, singular: "%d x", plural: "%d xs")))
        #expect(entries.contains(Entry(context: "one", singular: "One", plural: nil)))
        #expect(entries.contains(Entry(context: "two", singular: "Two", plural: nil)))
        #expect(entries.contains(Entry(context: "three", singular: "Three", plural: nil)))
        #expect(entries.contains(Entry(context: "four", singular: "Four (unbalanced", plural: nil)))
        #expect(
            !entries.contains(where: { $0.singular == "icon-name" }),
            "a literal after the call is not part of it: \(entries)",
        )
        #expect(entries.count == 7)
    }

    // MARK: - The template has to compile

    @Test("One key reached through two call forms is a single entry")
    func oneKeyReachedThroughTwoCallFormsIsASingleEntry() throws {
        // The bare path always deduplicated this; the context path was a
        // parallel copy that did not, and emitted the same msgctxt+msgid
        // twice — which msgfmt refuses outright, taking the whole po/
        // pipeline down with it.
        let source = """
        let a = localizedWithContext("ctx", "X")
        let b = nlocalizedWithContext("ctx", "X", "Xs", count: n)
        let c = "Y".localized
        let d = nlocalized("Y", "Ys", count: n)
        """
        let entries = try extract(source)
        #expect(entries.count == 2, "expected the plural entries to absorb the singulars, got \(entries)")

        // Plain `msgfmt`, not `--check`: a duplicate definition is fatal
        // either way, while `--check` also checks the header and a template
        // legitimately carries xgettext's `nplurals=INTEGER` placeholder.
        try template(source) { url in
            let compile = try run(tool: "msgfmt", arguments: ["-o", "/dev/null", url.path])
            #expect(compile.status == 0, "msgfmt rejected the template:\n\(compile.stderr)")
        }
    }

    @Test("A plural form asked for bare keeps an entry of its own")
    func aPluralFormAskedForBareKeepsAnEntryOfItsOwn() throws {
        // Measured against glibc rather than assumed: with a catalogue
        // declaring `msgid "%d note" / msgid_plural "%d notes"`,
        // `dgettext(domain, "%d notes")` returns the msgid untranslated —
        // only ngettext reaches msgstr[1]. So a bare lookup of the plural
        // form is a separate key, and folding it into the plural entry (which
        // is what this did at first) deletes it from the template and ships
        // the string in English.
        let source = """
        let a = nlocalized("%d note", "%d notes", count: n)
        let b = "%d notes".localized
        """
        let entries = try extract(source)
        #expect(entries.contains(Entry(context: nil, singular: "%d note", plural: "%d notes")))
        #expect(entries.contains(Entry(context: nil, singular: "%d notes", plural: nil)))

        // Both keys, and gettext accepts them side by side.
        try template(source) { url in
            let compile = try run(tool: "msgfmt", arguments: ["-o", "/dev/null", url.path])
            #expect(compile.status == 0, "msgfmt rejected the template:\n\(compile.stderr)")
        }
    }

    @Test("A singular reached bare and as a plural stays one entry")
    func aSingularReachedBareAndAsAPluralStaysOneEntry() throws {
        // The singular *is* the plural entry's key, so these are one entry —
        // emitting both defines the same msgid twice and msgfmt refuses it.
        let entries = try extract(
            """
            let a = nlocalized("%d note", "%d notes", count: n)
            let b = "%d note".localized
            """,
        )
        #expect(entries == [Entry(context: nil, singular: "%d note", plural: "%d notes")])
    }

    // MARK: - Unreadable call sites are reported, not skipped

    @Test("A context built from a variable is reported, not filed as a msgid")
    func aContextBuiltFromAVariableIsReportedNotFiledAsAMsgid() throws {
        // Reading "the next two literals on the line" instead files whatever
        // literals happen to follow — here an icon name — as the msgid, and
        // says nothing. The real string then ships English while the
        // catalogue carries a nonsense entry.
        let result = try extractRaw(
            """
            setContent(toggle, label: localizedWithContext(mode.context, "Preview"), icon: "text-x-generic")
            """,
        )
        #expect(result.status != 0, "an unreadable call site has to fail the extraction")
        #expect(result.stderr.contains("argument 1 must be a string literal"))
        #expect(result.stderr.contains("mode.context"))
    }

    @Test("A call wrapped across lines is reported")
    func aCallWrappedAcrossLinesIsReported() throws {
        let result = try extractRaw(
            """
            let a = localizedWithContext(
                "sort mode",
                "Title",
            )
            """,
        )
        #expect(result.status != 0)
        #expect(result.stderr.contains("needs its 2 leading arguments as literals"))
    }

    @Test("An interpolated msgid is reported as interpolated, not as wrapped")
    func anInterpolatedMsgidIsReportedAsInterpolatedNotAsWrapped() throws {
        // Two diagnostics for one mistake, one of them naming the wrong cause,
        // is worse than one: the developer unwraps a call that was never
        // wrapped.
        let result = try extractRaw(
            """
            let a = localizedWithContext("greeting", "Hi \\(name)")
            """,
        )
        #expect(result.status != 0)
        #expect(result.stderr.contains("argument 2 is interpolated"))
        #expect(
            !result.stderr.contains("needs its 2 leading arguments"),
            "the wrapped-call diagnostic must not fire too:\n\(result.stderr)",
        )
    }

    @Test("A plural call with a computed form is reported")
    func aPluralCallWithAComputedFormIsReported() throws {
        // `nlocalized` used to read the rest of the line the same way, so a
        // computed plural form silently took the next literal instead.
        let result = try extractRaw(
            """
            let a = nlocalized("%d note", pluralForm, count: n) + "%d of %d".localized
            """,
        )
        #expect(result.status != 0)
        #expect(result.stderr.contains("argument 2 must be a string literal"))
        #expect(result.stderr.contains("pluralForm"))
    }

    @Test("A ternary argument is refused, not half-read")
    func aTernaryArgumentIsRefusedNotHalfRead() throws {
        // A label is stripped by looking for a colon, and a ternary has one
        // too: taking everything before the first colon leaves only the
        // else-branch, so `flag ? "view mode" : "settings group"` filed
        // `settings group` and said nothing — one of the two keys then ships
        // English with every tool reporting success.
        let result = try extractRaw(
            """
            let a = localizedWithContext(flag ? "view mode" : "settings group", "Preview")
            """,
        )
        #expect(result.status != 0, "a ternary argument has to fail the extraction")
        #expect(result.stderr.contains("argument 1 must be a string literal"))
    }

    @Test("A labelled leading argument is reported rather than guessed at")
    func aLabelledLeadingArgumentIsReportedRatherThanGuessedAt() throws {
        // None of the three call forms labels the arguments that become
        // msgids, and accepting a label meant finding it by looking for a
        // colon — which is what let a ternary through. If a call form ever
        // does label them, this says so instead of guessing.
        let result = try extractRaw(
            """
            let a = localizedWithContext(context: "ctx", "Labelled")
            """,
        )
        #expect(result.status != 0)
        #expect(result.stderr.contains("argument 1 must be a string literal"))
    }

    @Test("Carriage returns are escaped rather than written raw")
    func carriageReturnsAreEscapedRatherThanWrittenRaw() throws {
        // Swift reads CR+LF as one Character, so a switch over characters
        // matches neither half and writes a raw line break inside the quoted
        // msgid — msgfmt then reports "end-of-line within string". A lone CR
        // is the quiet version: it compiles, and the next tool to normalise
        // line endings rewrites the msgid out from under the lookup.
        let source = #"let a = "one\rtwo".localized"# + "\n"
            + #"let b = "three\r\nfour".localized"#
        try template(source) { url in
            let pot = try String(contentsOf: url, encoding: .utf8)
            #expect(pot.contains(#"msgid "one\rtwo""#), "got:\n\(pot)")
            #expect(pot.contains(#"msgid "three\r\nfour""#), "got:\n\(pot)")
            #expect(
                !pot.unicodeScalars.contains("\r"),
                "a raw carriage return reached the template: \(pot.debugDescription)",
            )
            let compile = try run(tool: "msgfmt", arguments: ["-o", "/dev/null", url.path])
            #expect(compile.status == 0, "msgfmt rejected the template:\n\(compile.stderr)")
        }
    }

    // MARK: - Where a literal already is localized

    @Test("Localized literals are reported by position, bare ones included")
    func localizedLiteralsAreReportedByPositionBareOnesIncluded() throws {
        // What the bare-literal guard reads. It cannot work from the text: a
        // line can localize one copy of a string and leave another bare, and
        // only the column tells them apart.
        let source = #"let a = view.set(localizedWithContext("ctx", "Preview"), "Preview")"#
        let result = try emitted(source)
        let offsets = try #require(result.consumedLiterals["Sources/Fixture.swift:1"])

        let quotes = source.indices.filter { source[$0] == "\"" }
        let openingQuotes = stride(from: 0, to: quotes.count, by: 2)
            .map { source.distance(from: source.startIndex, to: quotes[$0]) }
        #expect(openingQuotes.count == 3, "fixture should hold three literals")
        // The call consumes its context and its msgid; the third literal is
        // the bare copy, and it must not be reported as consumed.
        #expect(offsets.sorted() == Array(openingQuotes.prefix(2)))
    }

    @Test("A literal handed to .localized on the next line is still reported")
    func aLiteralHandedToLocalizedOnTheNextLineIsStillReported() throws {
        // This shape is deliberately supported, and its offset has to be
        // reported too — a guard that recognised `.localized` itself instead
        // looks at the end of the first line, finds nothing, and reports a
        // correctly localized literal as bare.
        let result = try emitted(
            """
            let title = "Wrapped String"
                .localized
            """,
        )
        #expect(result.entries.contains { $0.singular == "Wrapped String" })
        #expect(result.consumedLiterals["Sources/Fixture.swift:1"] == [12])
    }

    // MARK: - Comments are not code

    @Test("A call inside a trailing comment is not a call site")
    func aCallInsideATrailingCommentIsNotACallSite() throws {
        // Whole-line comments were always skipped; a comment after code was
        // scanned as code. That was a spurious template entry until
        // conflicting plural forms became a hard error, at which point a note
        // to a future reader could stop the whole po/ pipeline.
        let result = try emitted(
            """
            let a = nlocalized("%d file", "%d files", count: n)
            let b = 1 // this used to be nlocalized("%d file", "%d docs", count: n)
            let c = "Real".localized // and "Phantom".localized here
            """,
        )
        #expect(result.entries.count == 2, "got \(result.entries.map(\.singular))")
        #expect(result.entries.contains { $0.singular == "%d file" && $0.plural == "%d files" })
        #expect(result.entries.contains { $0.singular == "Real" })
        #expect(!result.entries.contains { $0.singular == "Phantom" })
    }

    @Test("Block comments are not code either")
    func blockCommentsAreNotCodeEither() throws {
        // `//` was handled and `/* … */` was not, so the same phantom call
        // site survived in block-comment form — and a `/* label */` inside an
        // argument list, which this tree already writes elsewhere, made a
        // real call unreadable and stopped the build.
        let result = try emitted(
            """
            let a = nlocalized("%d file", "%d files", count: n)
            let b = 1 /* was nlocalized("%d file", "%d docs", count: n) */
            let c = nlocalized(/* singular */ "%d x", "%d xs", count: n)
            let d = 2 /* unterminated, mentioning nlocalized("%d file", "%d oops", count: n)
            """,
        )
        #expect(result.entries.count == 2, "got \(result.entries.map(\.singular))")
        #expect(result.entries.contains { $0.singular == "%d file" && $0.plural == "%d files" })
        #expect(result.entries.contains { $0.singular == "%d x" && $0.plural == "%d xs" })
    }

    @Test("A raw literal ends where its hashes say, not at a backslash")
    func aRawLiteralEndsWhereItsHashesSayNotAtABackslash() throws {
        // A backslash escapes nothing in a raw literal. Treating it as one
        // leaves the scanner inside a literal to the end of the line, so a
        // comment after it is read as code — the phantom call site again, by
        // another route. Two hashes on the fixture so its own `"#` needs no
        // escaping, and the backslash under test survives verbatim.
        let source = ##"""
        let a = #"C:\"# // nlocalized("%d file", "%d bad", count: n)
        let b = #"raw "quoted" body"#.localized
        """##
        let result = try emitted(source)
        #expect(
            result.entries.map(\.singular) == ["raw \"quoted\" body"],
            "fixture:\n\(source)",
        )
    }

    @Test("The body of a multi-line literal is prose, not code")
    func theBodyOfAMultiLineLiteralIsProseNotCode() throws {
        // Seed-note bodies quote UI strings, and reading those lines as code
        // filed them as bare literals — which the guard's
        // `permittedBareLiterals` was working around for one file.
        let result = try emitted(
            #"""
            let seed = """
                Use the "Editor" and "Preview" buttons.
                """
            let real = "Editor".localized
            """#,
        )
        #expect(result.entries.map(\.singular) == ["Editor"])
        #expect(result.entries.first?.sites == ["Sources/Fixture.swift:4"])
        #expect(result.scannedLiterals["Sources/Fixture.swift:2"] == nil)
    }

    @Test("A double slash inside a literal does not start a comment")
    func aDoubleSlashInsideALiteralDoesNotStartAComment() throws {
        let entries = try extract(#"let a = "https://example.com".localized"#)
        #expect(entries == [Entry(context: nil, singular: "https://example.com", plural: nil)])
    }

    // MARK: - What a PO file can carry

    @Test("A NUL is refused; every other control character is escaped")
    func aNULIsRefusedEveryOtherControlCharacterIsEscaped() throws {
        // Measured against the installed gettext rather than assumed. A raw
        // NUL in a PO file truncates the entry silently — `msgid "nul<NUL>x"`
        // compiles and reads back as `nul` — and even escaped it could not be
        // looked up, since `g_dgettext` takes a C string and the key Swift
        // hands it stops at the NUL too. Everything else is representable:
        // msgfmt accepts `\xNN`, octal, and even raw control bytes, and
        // xgettext writes `\a` and `\v` by name while passing ESC through raw.
        let refused = try extractRaw(##"let a = "nul\0x".localized"##)
        #expect(refused.status != 0)
        #expect(refused.stderr.contains("cannot carry a NUL"))
        #expect(refused.stdout.isEmpty)

        try template(
            ##"""
            let a = "bell\u{7}x".localized
            let b = "vt\u{B}x".localized
            let c = "esc\u{1B}[0m".localized
            let d = "del\u{7F}y".localized
            """##,
        ) { url in
            let pot = try String(contentsOf: url, encoding: .utf8)
            // Named where gettext names them, hex where it does not.
            #expect(pot.contains(##"msgid "bell\ax""##), "got:\n\(pot)")
            #expect(pot.contains(##"msgid "vt\vx""##), "got:\n\(pot)")
            #expect(pot.contains(##"msgid "esc\x1b[0m""##), "got:\n\(pot)")
            #expect(pot.contains(##"msgid "del\x7fy""##), "got:\n\(pot)")
            #expect(
                !pot.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" },
                "a raw control character reached the template",
            )
            let compile = try run(tool: "msgfmt", arguments: ["-o", "/dev/null", url.path])
            #expect(compile.status == 0, "msgfmt rejected the template:\n\(compile.stderr)")
        }
    }

    @Test("Nothing is printed when the source tree is refused")
    func nothingIsPrintedWhenTheSourceTreeIsRefused() throws {
        // The JSON used to be encoded and printed before the diagnostics were
        // checked, so a consumer reading stdout without also testing the exit
        // status ingested a catalogue with a duplicate key in it.
        let result = try extractRaw(
            """
            let a = nlocalized("%d file", "%d files", count: n)
            let b = nlocalized("%d file", "%d docs", count: n)
            """,
        )
        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, "got: \(result.stdout)")
    }

    // MARK: - Determinism

    @Test("The template comes out in one defined order")
    func theTemplateComesOutInOneDefinedOrder() throws {
        // Entries come out of a `Set`, whose iteration order is seeded per
        // process, so the sort is the only thing standing between the
        // template and a diff full of noise. Asserting one exact expected
        // order catches a comparator that leaves two entries incomparable;
        // re-running and comparing would agree by chance.
        //
        // Bare entries sort before context-qualified ones, and within a
        // context by msgid. Two plural forms for the same key would exercise
        // the last tiebreaker, but that is a source bug the extractor refuses
        // outright, so no successful run can contain one.
        try template(
            """
            let a = nlocalizedWithContext("search", "%d match", "%d matches", count: n)
            let b = nlocalizedWithContext("search", "%d hit", "%d hits", count: n)
            let c = localizedWithContext("search", "Search")
            let d = "Bare".localized
            """,
        ) { url in
            let entries = try entryBody(of: url)
                .split(separator: "\n\n", omittingEmptySubsequences: true)
                .dropFirst() // the header
                .map(String.init)
            #expect(
                entries == [
                    """
                    msgid "Bare"
                    msgstr ""
                    """,
                    """
                    msgctxt "search"
                    msgid "%d hit"
                    msgid_plural "%d hits"
                    msgstr[0] ""
                    msgstr[1] ""
                    """,
                    """
                    msgctxt "search"
                    msgid "%d match"
                    msgid_plural "%d matches"
                    msgstr[0] ""
                    msgstr[1] ""
                    """,
                    """
                    msgctxt "search"
                    msgid "Search"
                    msgstr ""
                    """,
                ],
                "got:\n\(entries.joined(separator: "\n--\n"))",
            )
        }
    }

    @Test("One msgid asked for with two plural forms is refused")
    func oneMsgidAskedForWithTwoPluralFormsIsRefused() throws {
        // gettext keys a plural entry on its singular alone, so these two
        // calls define the same key twice and msgfmt refuses the file —
        // taking the whole po/ pipeline with it. Picking a winner would bury
        // the real bug: the call sites disagree about what the message says.
        let result = try extractRaw(
            """
            let a = nlocalized("%d file", "%d files", count: n)
            let b = nlocalized("%d file", "%d docs", count: n)
            """,
        )
        #expect(result.status != 0, "a key with two plural forms has to fail the extraction")
        #expect(result.stderr.contains("is asked for with 2 different plural forms"))
        // Both sites, so the disagreement can be settled.
        #expect(result.stderr.contains("Fixture.swift:1"))
        #expect(result.stderr.contains("Fixture.swift:2"))
    }

    @Test("The reported entry count includes every form")
    func theReportedEntryCountIncludesEveryForm() throws {
        let output = try extractRaw(
            """
            let a = "Bare".localized
            let b = nlocalized("%d note", "%d notes", count: n)
            let c = localizedWithContext("view mode", "Preview")
            let d = nlocalizedWithContext("search", "%d match", "%d matches", count: n)
            """,
            emitMsgids: false,
        )
        #expect(output.status == 0, "\(output.stderr)")
        #expect(
            output.stdout.contains("Wrote 4 entries"),
            "the count skipped the context entries: \(output.stdout)",
        )
    }

    @Test("Call sites are reported by file and line, ordered numerically")
    func callSitesAreReportedByFileAndLineOrderedNumerically() throws {
        // The guards report *where* a bad call site is from these, and read
        // the line back off disk to check it — so both halves have to be right.
        // Lines 2 and 11, not 1 and 11: `"…:11" < "…:2"` lexically, so the
        // test fails if the numeric split is replaced by a plain string
        // comparison. With line 1 the two orders agree and it proves nothing.
        let json = try extractJSON(
            """
            let a = 0
            let b = "Repeat".localized
            let c = 0
            let d = 0
            let e = 0
            let f = 0
            let g = 0
            let h = 0
            let i = 0
            let j = 0
            let k = "Repeat".localized
            """,
        )
        let entry = try #require(json.first { $0.singular == "Repeat" })
        #expect(entry.sites == ["Sources/Fixture.swift:2", "Sources/Fixture.swift:11"])
    }

    // MARK: - Harness

    private struct Entry: Hashable, CustomStringConvertible {
        let context: String?
        let singular: String
        let plural: String?

        var description: String {
            "(\(context ?? "-"), \(singular), \(plural ?? "-"))"
        }
    }

    private struct DecodedEntry: Codable {
        let context: String?
        let singular: String
        let plural: String?
        let sites: [String]
    }

    private struct Emitted: Codable {
        let entries: [DecodedEntry]
        let consumedLiterals: [String: [Int]]
        let scannedLiterals: [String: [Int]]
    }

    /// Writes `source` as the only file of a throwaway source tree and runs
    /// the extractor over it.
    private func extractRaw(
        _ source: String,
        emitMsgids: Bool = true,
    ) throws -> ToolRunner.Result {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-extractor-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try source.write(
            to: sources.appendingPathComponent("Fixture.swift", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )
        let output = root.appendingPathComponent("out.pot", isDirectory: false)
        var arguments = [scriptURL.path, "--sources", sources.path]
        arguments += emitMsgids ? ["--emit-msgids"] : ["--output", output.path]
        return try run(tool: "swift", arguments: arguments)
    }

    private func extractJSON(_ source: String) throws -> [DecodedEntry] {
        try emitted(source).entries
    }

    private func emitted(_ source: String) throws -> Emitted {
        let result = try extractRaw(source)
        // The diagnostics, not a decoding failure: a refused run prints
        // nothing, and `"".data(using: .utf8)` is a non-nil empty Data, so
        // requiring the Data alone reported `dataCorrupted` and named nothing
        // about the call site that caused it.
        let data = try #require(
            result.stdout.data(using: .utf8).flatMap { $0.isEmpty ? nil : $0 },
            "the extractor refused the tree (status \(result.status)):\n\(result.stderr)",
        )
        return try JSONDecoder().decode(Emitted.self, from: data)
    }

    private func extract(_ source: String) throws -> Set<Entry> {
        Set(try extractJSON(source).map {
            Entry(context: $0.context, singular: $0.singular, plural: $0.plural)
        })
    }

    /// Runs `body` with the template the extractor writes for `source`.
    ///
    /// Scoped to a closure rather than returning the URL so the temporary
    /// tree can be removed afterwards — returning it left one directory per
    /// call behind under /tmp, and some tests call this five times.
    private func template<T>(_ source: String, _ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-template-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try source.write(
            to: sources.appendingPathComponent("Fixture.swift", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )
        let output = root.appendingPathComponent("out.pot", isDirectory: false)
        let result = try run(
            tool: "swift",
            arguments: [scriptURL.path, "--sources", sources.path, "--output", output.path],
        )
        try #require(result.status == 0, "extraction failed:\n\(result.stderr)")
        return try body(output)
    }

    /// A template's entries, with the generated timestamp dropped.
    private func entryBody(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("\"POT-Creation-Date:") }
            .joined(separator: "\n")
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/extract-i18n.swift")
    }

    /// Runs `tool` from PATH.
    private func run(tool: String, arguments: [String]) throws -> ToolRunner.Result {
        let resolved = try #require(ToolRunner.onPath(tool), "\(tool) is not on PATH")
        return try ToolRunner.run(resolved, arguments)
    }
}
#endif
