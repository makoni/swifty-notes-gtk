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

private func unescape(_ raw: String) -> String? {
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

private func localizedLiterals(in line: String) -> Set<String> {
    var found: Set<String> = []
    for (literal, endIndex) in stringLiterals(in: line) {
        let rest = line[endIndex...]
        let afterWhitespace = rest.drop(while: { $0 == " " })
        guard afterWhitespace.hasPrefix(".localized") else { continue }
        guard !literal.contains("\\(") else { continue }
        if let unescaped = unescape(literal) {
            found.insert(unescaped)
        }
    }
    return found
}

private struct PluralPair: Hashable {
    let singular: String
    let plural: String
}

private func pluralPairs(in line: String) -> Set<PluralPair> {
    var pairs: Set<PluralPair> = []
    var search = line.startIndex
    while let call = line.range(of: "nlocalized(", range: search ..< line.endIndex) {
        let literals = stringLiterals(in: String(line[call.upperBound...]))
        if literals.count >= 2,
           let singular = unescape(literals[0].literal),
           let plural = unescape(literals[1].literal) {
            pairs.insert(PluralPair(singular: singular, plural: plural))
        }
        search = call.upperBound
    }
    return pairs
}

// MARK: - Source scanning

private func scanSources() throws -> (singletons: Set<String>, pairs: Set<PluralPair>) {
    var singletons: Set<String> = []
    var pairs: Set<PluralPair> = []

    let packageRoot = URL(fileURLWithPath: #file, isDirectory: true)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let root = packageRoot.appendingPathComponent("Sources", isDirectory: true)

    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return (singletons, pairs)
    }

    for case let url as URL in walker where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            singletons.formUnion(localizedLiterals(in: String(line)))
            for pair in pluralPairs(in: String(line)) {
                pairs.insert(pair)
            }
        }
    }

    return (singletons, pairs)
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

// MARK: - Catalogue plural forms (Russian-style)

private func pluralFormsExpression() -> String {
    // Russian plural forms: n%100==1 ? 0 : n%100>=2 && n%100<=4 ? 1 : 2
    return "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);"
}

// MARK: - Main

do {
    let (singletons, pairs) = try scanSources()

    let now = Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mmzzzz"
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
    let sorted: [String] = remaining.sorted() + pairs.map { $0.singular }.sorted() + pairs.map { $0.plural }.sorted()

    // Deduplicate while writing (singulars can appear in both sets)
    var written: Set<String> = []

    for msgid in sorted {
        guard !written.contains(msgid) else { continue }
        written.insert(msgid)

        let escaped = escapePO(msgid)
        lines.append("msgid \"\(escaped)\"")

        // Check if this singular has a matching plural pair
        if let pair = pairs.first(where: { $0.singular == msgid }) {
            lines.append("msgid_plural \"\(escapePO(pair.plural))\"")
            lines.append("msgstr[0] \"\"")
            lines.append("msgstr[1] \"\"")
            lines.append("msgstr[2] \"\"")
        } else {
            lines.append("msgstr \"\"")
        }
        lines.append("")
    }

    // Write POT file
    let packageRoot = URL(fileURLWithPath: #file, isDirectory: true)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let potURL = packageRoot.appendingPathComponent("po/me.spaceinbox.swiftynotes.pot")
    let content = lines.joined(separator: "\n") + "\n"
    try content.write(to: potURL, atomically: true, encoding: .utf8)

    print("Wrote \(written.count) entries to \(potURL.path)")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
