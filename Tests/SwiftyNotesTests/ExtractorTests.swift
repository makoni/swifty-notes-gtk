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
        let pot = try String(
            contentsOf: try template(
                """
                let d = nlocalizedWithContext("search", "%d match", "%d matches", count: n)
                """,
            ),
            encoding: .utf8,
        )
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
        let potURL = try template(source)
        let compile = try run(tool: "msgfmt", arguments: ["-o", "/dev/null", potURL.path])
        #expect(compile.status == 0, "msgfmt rejected the template:\n\(compile.stderr)")
    }

    @Test("A plural form is not also emitted as an entry of its own")
    func aPluralFormIsNotAlsoEmittedAsAnEntryOfItsOwn() throws {
        // "%d notes" reached bare *and* as the plural half: one entry, or the
        // template defines the same msgid twice.
        let entries = try extract(
            """
            let a = nlocalized("%d note", "%d notes", count: n)
            let b = "%d notes".localized
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
        #expect(
            !result.stdout.contains("text-x-generic"),
            "the icon name must not become a msgid: \(result.stdout)",
        )
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

    // MARK: - Determinism

    @Test("Two plurals sharing a context and singular keep a stable order")
    func twoPluralsSharingAContextAndSingularKeepAStableOrder() throws {
        // Sorting on a subset of the fields leaves these two incomparable, and
        // Set iteration order is seeded per process — so the template churns
        // between runs and every diff carries noise.
        let source = """
        let a = nlocalizedWithContext("search", "%d match", "%d matches", count: n)
        let b = nlocalizedWithContext("search", "%d match", "%d hits", count: n)
        """
        let first = try template(source)
        let firstBody = try body(of: first)
        for _ in 0 ..< 4 {
            #expect(try body(of: try template(source)) == firstBody)
        }
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
        let json = try extractJSON(
            """
            let a = "Repeat".localized
            let b = 0
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
        #expect(entry.sites == ["Sources/Fixture.swift:1", "Sources/Fixture.swift:11"])
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
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Writes `source` as the only file of a throwaway source tree and runs
    /// the extractor over it.
    private func extractRaw(
        _ source: String,
        emitMsgids: Bool = true,
    ) throws -> RunResult {
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
        let result = try extractRaw(source)
        #expect(result.status == 0, "\(result.stderr)")
        let data = try #require(result.stdout.data(using: .utf8))
        return try JSONDecoder().decode(Emitted.self, from: data).entries
    }

    private func extract(_ source: String) throws -> Set<Entry> {
        Set(try extractJSON(source).map {
            Entry(context: $0.context, singular: $0.singular, plural: $0.plural)
        })
    }

    /// The template the extractor writes for `source`, as a file on disk.
    private func template(_ source: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-template-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
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
        return output
    }

    /// A template's entries, with the generated timestamp dropped.
    private func body(of url: URL) throws -> String {
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

    private func run(tool: String, arguments: [String]) throws -> RunResult {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let executable = path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        let resolved = try #require(executable, "\(tool) is not on PATH")

        let process = Process()
        process.executableURL = resolved
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
        )
    }
}
#endif
