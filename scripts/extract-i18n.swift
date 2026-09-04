#!/usr/bin/env swift
// swiftlint:disable all

import Foundation

// MARK: - Scanner helpers (ported from LocalizationCatalogTests.swift)

private func stringLiterals(
    in line: String
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


/// The part of `line` that is code: everything before a `//` that is not
/// inside a string literal.
///
/// Whole-line comments were already skipped, but a comment *after* code was
/// scanned as code — so a call quoted in a note to a future reader was filed
/// as a real call site. That was merely a spurious template entry until
/// conflicting plural forms became a hard error, at which point a comment
/// could stop the whole po/ pipeline and point the developer at prose.
///
/// Literal-aware because the alternative breaks the obvious cases: a `//`
/// inside `"https://example.com"` does not start a comment.
private func codePortion(of line: String) -> String {
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

/// Unescapes with `\u{...}` support. Returns `(value, diagnostics)` where diagnostics
/// is non-empty if an unrecognised escape was encountered.
private func unescapeWithSupport(_ raw: String, file: String) -> (value: String?, diagnostics: [String]) {
    var output = ""
    var iterator = raw.makeIterator()
    var diagnostics: [String] = []
    while let character = iterator.next() {
        guard character == "\\" else {
            output.append(character)
            continue
        }
        guard let escaped = iterator.next() else {
            diagnostics.append("\(file): unrecognised escape at end of literal: `\(raw)`")
            return (nil, diagnostics)
        }
        switch escaped {
        case "n": output.append("\n")
        case "t": output.append("\t")
        case "r": output.append("\r")
        case "0": output.append("\0")
        case "\"": output.append("\"")
        case "\\": output.append("\\")
        case "u":
            // Parse \u{...}
            var hex = ""
            var foundOpen = false
            var foundClose = false
            while let ch = iterator.next() {
                if !foundOpen && ch == "{" {
                    foundOpen = true
                    continue
                }
                if foundOpen {
                    if ch == "}" {
                        foundClose = true
                        break
                    }
                    hex.append(ch)
                }
            }
            if foundOpen && foundClose, let codePoint = UInt32(hex, radix: 16),
               let scalar = UnicodeScalar(codePoint) {
                output.append(String(scalar))
            } else if foundOpen {
                // Unterminated \u{ — skip it, treat as unrecognised
                diagnostics.append("\(file): unterminated \\u{...} escape in literal: `\(raw)`")
                return (nil, diagnostics)
            } else {
                diagnostics.append("\(file): unrecognised escape: `\(raw)`")
                return (nil, diagnostics)
            }
        default:
            diagnostics.append("\(file): unrecognised escape: `\(raw)`")
            return (nil, diagnostics)
        }
    }
    return (output, diagnostics)
}

private func localizedLiterals(
    in line: String,
    nextLine: String?,
    file: String
) -> (found: Set<String>, consumed: Set<Int>, diagnostics: [String]) {
    var found: Set<String> = []
    // Where each localized literal starts. The guard that hunts for
    // unlocalized literals reads these: asking it to recognise `.localized`
    // itself gave the wrong answer for the form that wraps onto the next
    // line, which this scanner accepts on purpose.
    var consumed: Set<Int> = []
    var diagnostics: [String] = []
    let literals = stringLiterals(in: line)
    for (offset, (literal, startIndex, endIndex)) in literals.enumerated() {
        let rest = line[endIndex...]
        let afterWhitespace = rest.drop(while: { $0 == " " })
        var isLocalized = afterWhitespace.hasPrefix(".localized")
        if !isLocalized, offset == literals.count - 1, rest.allSatisfy({ $0 == " " }) {
            // `.localized` wrapped onto the next line. Only the last literal on
            // this line can own it, and only if nothing follows it here —
            // otherwise a call like `addResponse("ok", label: "OK"\n.localized)`
            // would file the non-user-visible `"ok"` as a msgid too, and the
            // orphan guard could not catch it because it shares this scanner.
            if let next = nextLine {
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if !nextTrimmed.hasPrefix("//"), nextTrimmed.hasPrefix(".localized") {
                    isLocalized = true
                }
            }
        }
        guard isLocalized else { continue }
        consumed.insert(line.distance(from: line.startIndex, to: startIndex))
        guard !literal.contains("\\(") else { continue }
        let (unescaped, diag) = unescapeWithSupport(literal, file: file)
        if !diag.isEmpty {
            diagnostics.append(contentsOf: diag)
        }
        if let unescaped = unescaped {
            found.insert(unescaped)
        }
    }
    return (found, consumed, diagnostics)
}
// MARK: - Entries

/// One entry as the source asks for it.
///
/// `context` is `nil` for a bare lookup and `plural` for a non-plural one, so
/// all four call forms — `.localized`, `nlocalized`, `localizedWithContext`
/// and `nlocalizedWithContext` — land in the same type. That is deliberate:
/// the context-qualified forms started life as parallel structs and promptly
/// missed the deduplication the bare path had, emitting two entries with the
/// same `msgctxt` and `msgid`, which `msgfmt` rejects outright.
private struct ScannedEntry: Hashable, Comparable {
    let context: String?
    let singular: String
    let plural: String?

    /// gettext's own key: the context, `U+0004`, then the msgid.
    var lookupKey: String {
        guard let context else { return singular }
        return "\(context)\u{4}\(singular)"
    }

    /// Sorts on every field. Comparing a subset would leave two entries that
    /// differ only in their plural form incomparable, and since `Set`
    /// iteration order is seeded per process the template would then churn
    /// between runs.
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.context ?? "", lhs.singular, lhs.plural ?? "")
            < (rhs.context ?? "", rhs.singular, rhs.plural ?? "")
    }
}

/// Addresses an entry the way gettext does, for deduplication.
private struct EntryKey: Hashable {
    let context: String?
    let msgid: String
}

// MARK: - Call forms

/// A call that puts its literal arguments in the catalogue.
private struct LocalizingCall {
    /// Spelled with the opening parenthesis so a bare identifier cannot match.
    let keyword: String
    let hasContext: Bool
    let hasPlural: Bool

    var name: String { String(keyword.dropLast()) }

    /// Leading arguments that must be literals: context, singular, plural.
    var literalArgumentCount: Int {
        1 + (hasContext ? 1 : 0) + (hasPlural ? 1 : 0)
    }
}

/// Longest keyword first: `nlocalizedWithContext(` contains
/// `localizedWithContext(`, and ``callRanges(of:in:)`` rejects a match that
/// continues an identifier, so order alone does not decide it — but scanning
/// the specific form first keeps the diagnostics attributable.
private let localizingCalls: [LocalizingCall] = [
    LocalizingCall(keyword: "nlocalizedWithContext(", hasContext: true, hasPlural: true),
    LocalizingCall(keyword: "localizedWithContext(", hasContext: true, hasPlural: false),
    LocalizingCall(keyword: "nlocalized(", hasContext: false, hasPlural: true),
]

/// Finds `call(` occurrences that are not the tail of a longer identifier.
///
/// `nlocalizedWithContext(` contains `localizedWithContext(`, so a plain
/// substring search would file every plural context call as a singular one
/// too — with the plural form landing in the catalogue as a separate msgid.
private func callRanges(of call: String, in line: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var search = line.startIndex
    while let found = line.range(of: call, range: search ..< line.endIndex) {
        let precededByIdentifier: Bool
        if found.lowerBound > line.startIndex {
            let previous = line[line.index(before: found.lowerBound)]
            precededByIdentifier = previous.isLetter || previous.isNumber || previous == "_"
        } else {
            precededByIdentifier = false
        }
        if !precededByIdentifier {
            ranges.append(found)
        }
        search = found.upperBound
    }
    return ranges
}

/// Splits the argument list that starts just after a call's `(`.
///
/// Stops at the call's own closing parenthesis, keeps nested calls and
/// collections whole, and treats commas inside string literals as text.
private func argumentList(
    startingAfter open: String.Index,
    in line: String
) -> [(text: String, start: String.Index)] {
    var arguments: [(text: String, start: String.Index)] = []
    var current = ""
    var currentStart = open
    var depth = 0
    var index = open
    var insideLiteral = false

    while index < line.endIndex {
        let character = line[index]
        if insideLiteral {
            current.append(character)
            if character == "\\" {
                let next = line.index(after: index)
                if next < line.endIndex {
                    current.append(line[next])
                    index = line.index(after: next)
                    continue
                }
            } else if character == "\"" {
                insideLiteral = false
            }
            index = line.index(after: index)
            continue
        }
        switch character {
        case "\"":
            insideLiteral = true
            current.append(character)
        case "(", "[", "{":
            depth += 1
            current.append(character)
        case ")", "]", "}":
            if depth == 0, character == ")" {
                arguments.append((current, currentStart))
                return arguments
            }
            depth -= 1
            current.append(character)
        case "," where depth == 0:
            arguments.append((current, currentStart))
            current = ""
            currentStart = line.index(after: index)
        default:
            current.append(character)
        }
        index = line.index(after: index)
    }
    // The call continues on the next line; hand back what there is so the
    // caller reports "not enough arguments" rather than guessing.
    arguments.append((current, currentStart))
    return arguments
}

/// The raw literal an argument consists of and how far into the argument its
/// opening quote sits, or `nil` when the argument is anything else — a
/// variable, an expression, a ternary, two literals concatenated.
///
/// An argument has to be *nothing but* a literal. Accepting a labelled form
/// (`label: "text"`) meant finding the label by looking for a colon, and a
/// ternary has one of those too, so `flag ? "a" : "b"` came through as `"b"`
/// with nothing reported. None of the three call forms labels the arguments
/// that become msgids, so the leniency bought nothing; if one ever does, this
/// reports it rather than guessing.
private func soleLiteral(in argument: String) -> (literal: String, offset: Int)? {
    let leadingWhitespace = argument.prefix { $0 == " " || $0 == "\t" }.count
    let value = argument.trimmingCharacters(in: .whitespaces)
    guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
    // One literal has to account for the whole argument, which rejects
    // `"a" + "b"` and `"a" "b"` — neither is a msgid.
    let literals = stringLiterals(in: value)
    guard literals.count == 1, literals[0].end == value.endIndex else { return nil }
    return (literals[0].literal, leadingWhitespace)
}

/// The entries a line's context and plural calls ask for.
///
/// A call this cannot read is reported rather than skipped. Skipping is what
/// makes a missing translation invisible: the string keeps working, in
/// English, and nothing in the pipeline says why.
private func callEntries(
    in line: String,
    file: String
) -> (entries: Set<ScannedEntry>, consumed: Set<Int>, diagnostics: [String]) {
    var entries: Set<ScannedEntry> = []
    // Character offsets of the opening quotes this line's localizing calls
    // consume. A guard elsewhere needs to tell a literal that is already
    // localized by the call around it from one that was left bare, and only
    // the position distinguishes them: the same text can be both on one line.
    var consumed: Set<Int> = []
    var diagnostics: [String] = []
    // Almost no line calls any of these; skip the Unicode-aware searches.
    // Read off the same list the loop below iterates, so adding a call form
    // cannot silently skip every line that uses it.
    guard localizingCalls.contains(where: { line.contains($0.keyword) }) else {
        return (entries, consumed, diagnostics)
    }
    let context = line.trimmingCharacters(in: .whitespaces)

    for call in localizingCalls {
        for range in callRanges(of: call.keyword, in: line) {
            let arguments = argumentList(startingAfter: range.upperBound, in: line)
            let needed = call.literalArgumentCount
            guard arguments.count >= needed else {
                diagnostics.append(
                    "\(file): \(call.name) needs its \(needed) leading arguments as literals "
                        + "on one line: `\(context)`"
                )
                continue
            }
            var values: [String] = []
            var offsets: [Int] = []
            var failed = false
            for position in 0 ..< needed {
                let argument = arguments[position]
                guard let (raw, offsetInArgument) = soleLiteral(in: argument.text) else {
                    diagnostics.append(
                        "\(file): \(call.name) argument \(position + 1) must be a string literal, "
                            + "not `\(argument.text.trimmingCharacters(in: .whitespaces))`: `\(context)`"
                    )
                    failed = true
                    break
                }
                offsets.append(
                    line.distance(from: line.startIndex, to: argument.start) + offsetInArgument
                )
                guard !raw.contains("\\(") else {
                    diagnostics.append(
                        "\(file): \(call.name) argument \(position + 1) is interpolated, so it can "
                            + "never match a catalogue entry: `\(context)`"
                    )
                    failed = true
                    break
                }
                let (value, diagnostic) = unescapeWithSupport(raw, file: file)
                diagnostics.append(contentsOf: diagnostic)
                guard let value else {
                    failed = true
                    break
                }
                values.append(value)
            }
            guard !failed else { continue }
            consumed.formUnion(offsets)
            var cursor = 0
            let entryContext = call.hasContext ? values[cursor] : nil
            if call.hasContext { cursor += 1 }
            let singular = values[cursor]
            cursor += 1
            let plural = call.hasPlural ? values[cursor] : nil
            entries.insert(ScannedEntry(context: entryContext, singular: singular, plural: plural))
        }
    }
    return (entries, consumed, diagnostics)
}

// MARK: - Source scanning

/// The directory to scan. `--sources PATH` exists so the extractor's own
/// behaviour can be tested against a source tree written for the occasion,
/// rather than only against the app it happens to ship with.
private func sourceRoot(packageRoot: URL) -> URL {
    let argument = CommandLine.arguments.firstIndex(of: "--sources")
        .flatMap { index -> String? in
            let next = CommandLine.arguments.index(after: index)
            return next < CommandLine.arguments.endIndex ? CommandLine.arguments[next] : nil
        }
    return argument.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? packageRoot.appendingPathComponent("Sources", isDirectory: true)
}

private let packageRoot = URL(fileURLWithPath: #file, isDirectory: true)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// Every entry the source asks for, with every place it asks from.
///
/// Keyed rather than a plain set because the sites are what let a test report
/// *where* a bad call site is without scanning the tree a second time — a
/// second scanner is how the keyword list drifted out of step before.
private func scanSources() throws -> (
    entries: [ScannedEntry: Set<String>],
    consumed: [String: Set<Int>],
    diagnostics: [String]
) {
    var entries: [ScannedEntry: Set<String>] = [:]
    var consumed: [String: Set<Int>] = [:]
    var diagnostics: [String] = []

    let root = sourceRoot(packageRoot: packageRoot)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return (entries, consumed, diagnostics)
    }

    for case let url as URL in walker where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let relative = url.path.replacingOccurrences(of: root.deletingLastPathComponent().path + "/", with: "")

        for i in 0..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }

            // Check for `"""` on this line — skip multi-line literals
            let lineStr = codePortion(of: String(line))
            if lineStr.contains("\"\"\"") {
                // Detect if a `"""` literal has `.localized` applied — that's an error
                // Simple heuristic: if `.localized` appears on the same line as `"""`
                // or within a few characters after the closing `"""`
                let tripleQuoteCount = lineStr.components(separatedBy: "\"\"\"").count - 1
                if tripleQuoteCount == 1 || tripleQuoteCount == 3 {
                    // Odd number of `"""` delimiters means the literal spans this line
                    // Check for `.localized` right after closing `"""`
                    let afterTriple = lineStr.components(separatedBy: "\"\"\"")
                    for part in afterTriple {
                        if part.hasPrefix(".localized") || part.drop(while: { $0 == " " }).hasPrefix(".localized") {
                            diagnostics.append("\(relative): .localized applied to \"\"\" literal: `\(lineStr)`")
                            break
                        }
                    }
                }
                continue
            }

            let site = "\(relative):\(i + 1)"
            let nextLine: String? = (i + 1 < lines.count ? String(lines[i + 1]) : nil)
                .map(codePortion(of:))
            let (found, bareConsumed, localDiagnostics) = localizedLiterals(
                in: lineStr,
                nextLine: nextLine,
                file: relative
            )
            for msgid in found {
                entries[ScannedEntry(context: nil, singular: msgid, plural: nil), default: []].insert(site)
            }
            diagnostics.append(contentsOf: localDiagnostics)

            let (called, callConsumed, callDiagnostics) = callEntries(in: lineStr, file: relative)
            for entry in called {
                entries[entry, default: []].insert(site)
            }
            // Both scanners report offsets on the same line, so the two sets
            // merge — but each site is visited once, so this is an
            // assignment rather than an accumulation.
            let lineConsumed = bareConsumed.union(callConsumed)
            if !lineConsumed.isEmpty {
                consumed[site] = lineConsumed
            }
            diagnostics.append(contentsOf: callDiagnostics)
        }
    }

    return (entries, consumed, diagnostics)
}

/// Orders `file:line` sites by file, then numerically by line.
private func siteIsBefore(_ lhs: String, _ rhs: String) -> Bool {
    func split(_ site: String) -> (String, Int) {
        guard let colon = site.lastIndex(of: ":"),
              let line = Int(site[site.index(after: colon)...])
        else { return (site, 0) }
        return (String(site[site.startIndex ..< colon]), line)
    }
    return split(lhs) < split(rhs)
}

/// Drops the singular-only entries that a plural entry already covers.
///
/// A string reached through both `"X".localized` and `nlocalized("X", "Xs")`
/// is one catalogue entry, not two, and gettext refuses a file that defines
/// the same key twice — so this is what keeps the template compilable.
///
/// Only the *singular* absorbs its bare twin. A bare lookup of the plural
/// form is a different key that a plural entry does not answer: measured
/// against glibc, `dgettext(domain, "%d notes")` beside an entry declaring
/// `msgid "%d note" / msgid_plural "%d notes"` hands back the msgid
/// untranslated. Dropping it — which is what the version before this did —
/// deletes a real key from the template, and the string then ships English
/// with nothing anywhere to say why.
private func deduplicated(_ entries: [ScannedEntry: Set<String>]) -> [(entry: ScannedEntry, sites: [String])] {
    var pluralSingulars: Set<EntryKey> = []
    for entry in entries.keys where entry.plural != nil {
        pluralSingulars.insert(EntryKey(context: entry.context, msgid: entry.singular))
    }
    return entries
        .filter { entry, _ in
            entry.plural != nil
                || !pluralSingulars.contains(EntryKey(context: entry.context, msgid: entry.singular))
        }
        // Sorted by line number, not lexically, so `:87` does not follow
        // `:509` in a failure message.
        .map { (entry: $0.key, sites: $0.value.sorted(by: siteIsBefore)) }
        .sorted { $0.entry < $1.entry }
}

/// Reports a msgid asked for with two different plural forms.
///
/// gettext keys a plural entry on its singular alone, so two such calls
/// define the same key twice and `msgfmt` refuses the file — the po/ pipeline
/// stops dead. Picking a winner would bury a real source bug: two call sites
/// disagree about what the message says, and only their author can say which
/// is right.
private func conflictingPluralForms(_ entries: [ScannedEntry: Set<String>]) -> [String] {
    var formsByKey: [EntryKey: [String: [String]]] = [:]
    for (entry, sites) in entries {
        guard let plural = entry.plural else { continue }
        let key = EntryKey(context: entry.context, msgid: entry.singular)
        formsByKey[key, default: [:]][plural, default: []].append(contentsOf: sites)
    }

    var diagnostics: [String] = []
    for (key, forms) in formsByKey where forms.count > 1 {
        let described = forms
            .sorted { $0.key < $1.key }
            .map { form, sites in
                "  \(form.debugDescription) at \(sites.sorted(by: siteIsBefore).joined(separator: ", "))"
            }
            .joined(separator: "\n")
        let name = ScannedEntry(context: key.context, singular: key.msgid, plural: nil).lookupKey
        diagnostics.append(
            "\(name.debugDescription) is asked for with \(forms.count) different plural forms; "
                + "gettext keys a plural entry on its singular alone, so this cannot be "
                + "compiled:\n\(described)"
        )
    }
    return diagnostics.sorted()
}

// MARK: - PO escaping

/// Escapes a msgid for a PO file.
///
/// Iterates unicode scalars rather than characters on purpose: Swift reads
/// CR+LF as a single `Character`, so a switch over characters matches neither
/// half of it and writes a raw line break inside the quoted string — which
/// msgfmt refuses outright ("end-of-line within string"). A lone CR is the
/// quieter version of the same bug: it compiles, and then an editor or
/// msgmerge normalises the line ending and rewrites the msgid out from under
/// the lookup.
///
/// The escapes are the ones gettext defines. Anything else in the C0 range
/// has no PO spelling at all and is dropped here — ``unrepresentableScalars``
/// reports those before a template is written, so the drop is unreachable in
/// practice.
private func escapePO(_ string: String) -> String {
    var output = ""
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\\":
            output += "\\\\"
        case "\"":
            output += "\\\""
        case "\u{07}":
            output += "\\a"
        case "\u{08}":
            output += "\\b"
        case "\u{0C}":
            output += "\\f"
        case "\n":
            output += "\\n"
        case "\r":
            output += "\\r"
        case "\t":
            output += "\\t"
        case "\u{0B}":
            output += "\\v"
        default:
            guard !isUnrepresentableInPO(scalar) else { continue }
            output.unicodeScalars.append(scalar)
        }
    }
    return output
}

/// Whether a scalar has no PO spelling: a control character that gettext
/// defines no escape for.
///
/// Writing one raw is worse than useless — a NUL terminates the string for
/// every C consumer downstream of msgfmt, and this template is merged with
/// one xgettext wrote, so the two have to agree on what is representable.
private func isUnrepresentableInPO(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "\u{07}", "\u{08}", "\u{0B}", "\u{0C}", "\n", "\r", "\t":
        false
    default:
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}

/// Reports every msgid holding a character a PO file cannot carry.
///
/// `unescapeWithSupport` accepts `\0` and arbitrary `\u{…}`, so a source
/// literal can hold anything; this is where that stops.
private func unrepresentableScalars(_ entries: [ScannedEntry: Set<String>]) -> [String] {
    var diagnostics: [String] = []
    for (entry, sites) in entries {
        let site = sites.sorted(by: siteIsBefore).first ?? "?"
        for text in [entry.context, entry.singular, entry.plural].compactMap({ $0 }) {
            for scalar in text.unicodeScalars where isUnrepresentableInPO(scalar) {
                let code = String(format: "%04X", scalar.value)
                diagnostics.append(
                    "\(site): a msgid cannot carry U+\(code); gettext defines no escape for it: "
                        + text.debugDescription
                )
            }
        }
    }
    return diagnostics.sorted()
}

// MARK: - Catalogue plural forms (xgettext convention for .pot)

private func pluralFormsExpression() -> String {
    "nplurals=INTEGER; plural=EXPRESSION;"
}

// MARK: - JSON output (for --emit-msgids)

private struct EmitMsgidsResult: Codable {
    struct Entry: Codable {
        /// Absent for a bare lookup.
        let context: String?
        let singular: String
        /// Absent for a non-plural lookup.
        let plural: String?
        /// Every place the source asks for it, as `file:line`.
        let sites: [String]
    }

    let entries: [Entry]

    /// Character offsets, per `file:line`, of the opening quotes that a
    /// localizing call consumes as one of its arguments.
    ///
    /// A literal is legitimately bare when the call around it localizes it,
    /// and on a line that both localizes one copy of a string and leaves
    /// another bare, position is the only thing that tells them apart.
    let consumedLiterals: [String: [Int]]
}

// MARK: - Main

do {
    let (entries, consumed, scanDiagnostics) = try scanSources()
    // Reported alongside the scan's own: two call sites disagreeing about a
    // plural form is a source bug, not a scanning failure, but it stops the
    // catalogue from compiling all the same.
    let diagnostics = scanDiagnostics
        + conflictingPluralForms(entries)
        + unrepresentableScalars(entries)

    // Before anything is printed, either way: a template that cannot compile
    // must not reach a consumer at all. Emitting the JSON first and exiting 1
    // afterwards hands well-formed-looking JSON with a duplicate key in it to
    // anything that reads stdout without checking the status.
    if !diagnostics.isEmpty {
        for diagnostic in diagnostics {
            fputs(diagnostic + "\n", stderr)
        }
        exit(1)
    }

    if CommandLine.arguments.contains("--emit-msgids") {
        let result = EmitMsgidsResult(
            entries: deduplicated(entries).map {
                EmitMsgidsResult.Entry(
                    context: $0.entry.context,
                    singular: $0.entry.singular,
                    plural: $0.entry.plural,
                    sites: $0.sites
                )
            },
            consumedLiterals: consumed.mapValues { $0.sorted() }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(0)
    }

    let now = Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mmZ"
    let timestamp = formatter.string(from: now)

    var lines: [String] = []
    lines.append("msgid \"\"")
    lines.append("msgstr \"\"")
    lines.append("\"MIME-Version: 1.0\\n\"")
    lines.append("\"Content-Type: text/plain; charset=UTF-8\\n\"")
    lines.append("\"Content-Transfer-Encoding: 8bit\\n\"")
    lines.append("\"Plural-Forms: \(pluralFormsExpression())\\n\"")
    lines.append("\"Project-Id-Version: swifty-notes-gtk\\n\"")
    lines.append("\"Language: \\n\"")
    lines.append("\"POT-Creation-Date: \(timestamp)\\n\"")
    lines.append("")

    // One loop for every form. `msgctxt` is what lets one English string be
    // translated two ways; the same msgid may appear both with and without a
    // context, and gettext treats those as different entries.
    let emitted = deduplicated(entries).map(\.entry)
    for entry in emitted {
        if let context = entry.context {
            lines.append("msgctxt \"\(escapePO(context))\"")
        }
        lines.append("msgid \"\(escapePO(entry.singular))\"")
        if let plural = entry.plural {
            lines.append("msgid_plural \"\(escapePO(plural))\"")
            lines.append("msgstr[0] \"\"")
            lines.append("msgstr[1] \"\"")
        } else {
            lines.append("msgstr \"\"")
        }
        lines.append("")
    }

    // Default output is the shipped template; `--output PATH` lets
    // scripts/extract-i18n.sh collect the Swift half separately before
    // merging it with the strings extracted from the packaging metadata.
    let outputArgument = CommandLine.arguments.firstIndex(of: "--output")
        .flatMap { index -> String? in
            let next = CommandLine.arguments.index(after: index)
            return next < CommandLine.arguments.endIndex ? CommandLine.arguments[next] : nil
        }
    let potURL = outputArgument.map { URL(fileURLWithPath: $0) }
        ?? packageRoot.appendingPathComponent("po/me.spaceinbox.swiftynotes.pot")
    let content = lines.joined(separator: "\n") + "\n"
    try content.write(to: potURL, atomically: true, encoding: .utf8)

    print("Wrote \(emitted.count) entries to \(potURL.path)")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
