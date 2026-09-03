#!/usr/bin/env swift
// swiftlint:disable all

import Foundation

// MARK: - Scanner helpers (ported from LocalizationCatalogTests.swift)

private func stringLiterals(in line: String) -> [(literal: String, end: String.Index)] {
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

private func localizedLiterals(in line: String, nextLine: String?, file: String) -> (found: Set<String>, diagnostics: [String]) {
    var found: Set<String> = []
    var diagnostics: [String] = []
    let literals = stringLiterals(in: line)
    for (offset, (literal, endIndex)) in literals.enumerated() {
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
        guard !literal.contains("\\(") else { continue }
        let (unescaped, diag) = unescapeWithSupport(literal, file: file)
        if !diag.isEmpty {
            diagnostics.append(contentsOf: diag)
        }
        if let unescaped = unescaped {
            found.insert(unescaped)
        }
    }
    return (found, diagnostics)
}

private struct PluralPair: Hashable {
    let singular: String
    let plural: String
}

private func pluralPairs(in line: String, file: String) -> (pairs: Set<PluralPair>, diagnostics: [String]) {
    var pairs: Set<PluralPair> = []
    var diagnostics: [String] = []
    var search = line.startIndex
    while let call = line.range(of: "nlocalized(", range: search ..< line.endIndex) {
        let literals = stringLiterals(in: String(line[call.upperBound...]))
        if literals.count >= 2 {
            let (singular, diag1) = unescapeWithSupport(literals[0].literal, file: file)
            let (plural, diag2) = unescapeWithSupport(literals[1].literal, file: file)
            if !diag1.isEmpty { diagnostics.append(contentsOf: diag1) }
            if !diag2.isEmpty { diagnostics.append(contentsOf: diag2) }
            if let singular = singular, let plural = plural {
                pairs.insert(PluralPair(singular: singular, plural: plural))
            }
        }
        search = call.upperBound
    }
    return (pairs, diagnostics)
}

// MARK: - Source scanning

private func scanSources() throws -> (singletons: Set<String>, pairs: Set<PluralPair>, diagnostics: [String]) {
    var singletons: Set<String> = []
    var pairs: Set<PluralPair> = []
    var diagnostics: [String] = []

    let packageRoot = URL(fileURLWithPath: #file, isDirectory: true)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let root = packageRoot.appendingPathComponent("Sources", isDirectory: true)

    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return (singletons, pairs, diagnostics)
    }

    for case let url as URL in walker where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let relative = url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")

        for i in 0..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }

            // Check for `"""` on this line — skip multi-line literals
            let lineStr = String(line)
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

            let nextLine: String? = i + 1 < lines.count ? String(lines[i + 1]) : nil
            let (found, localDiag) = localizedLiterals(in: lineStr, nextLine: nextLine, file: relative)
            singletons.formUnion(found)
            diagnostics.append(contentsOf: localDiag)
            let (pairResult, pairDiag) = pluralPairs(in: lineStr, file: relative)
            pairs.formUnion(pairResult)
            diagnostics.append(contentsOf: pairDiag)
        }
    }

    return (singletons, pairs, diagnostics)
}

// MARK: - PO escaping

private func escapePO(_ string: String) -> String {
    var output = ""
    for character in string {
        switch character {
        case "\"": output.append("\\\"")
        case "\n": output.append("\\n")
        case "\t": output.append("\\t")
        case "\r": output.append("\\r")
        case "\\": output.append("\\\\")
        default: output.append(character)
        }
    }
    return output
}

// MARK: - Catalogue plural forms (xgettext convention for .pot)

private func pluralFormsExpression() -> String {
    // xgettext convention: nplurals=INTEGER; plural=EXPRESSION;
    return "nplurals=INTEGER; plural=EXPRESSION;"
}

// MARK: - JSON output (for --emit-msgids)

private struct EmitMsgidsResult: Codable {
    let singletons: [String]
    let plurals: [[String]]
}

// MARK: - Main

do {
    if CommandLine.arguments.contains("--emit-msgids") {
        let (singletons, pairs, diagnostics) = try scanSources()
        let result = EmitMsgidsResult(
            singletons: singletons.sorted(),
            plurals: pairs.sorted(by: { $0.singular < $1.singular }).map { [$0.singular, $0.plural] }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        if !diagnostics.isEmpty {
            for diag in diagnostics {
                fputs(diag + "\n", stderr)
            }
            exit(1)
        }
        exit(0)
    }

    let (singletons, pairs, diagnostics) = try scanSources()
    if !diagnostics.isEmpty {
        for diag in diagnostics {
            fputs(diag + "\n", stderr)
        }
        exit(1)
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

    // Separate plural singles from the singleton set
    let pluralSingles = pairs.map { $0.singular }
    let pluralPlurals = pairs.map { $0.plural }
    let remaining = singletons.subtracting(pluralSingles).subtracting(pluralPlurals)

    // Sort all entries for stable output
    let sorted: [String] = remaining.sorted() + pairs.map { $0.singular }.sorted()

    for msgid in sorted {

        let escaped = escapePO(msgid)
        lines.append("msgid \"\(escaped)\"")

        // Check if this singular has a matching plural pair
        if let pair = pairs.first(where: { $0.singular == msgid }) {
            lines.append("msgid_plural \"\(escapePO(pair.plural))\"")
            lines.append("msgstr[0] \"\"")
            lines.append("msgstr[1] \"\"")
        } else {
            lines.append("msgstr \"\"")
        }
        lines.append("")
    }

    // Write POT file
    let packageRoot = URL(fileURLWithPath: #file, isDirectory: true)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
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

    print("Wrote \(sorted.count) entries to \(potURL.path)")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
