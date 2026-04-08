import Foundation

public struct Note: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let filename: String
    public let createdAt: Date
    public var updatedAt: Date
    public var content: String

    public init(
        id: UUID,
        filename: String,
        createdAt: Date,
        updatedAt: Date,
        content: String
    ) {
        self.id = id
        self.filename = filename
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.content = content
    }

    public var title: String {
        Self.derivedTitle(from: content)
    }

    public var stableID: String {
        id.uuidString.lowercased()
    }

    public var suggestedExportFilename: String {
        let filenameStem = Self.sanitizedFilenameStem(from: title, defaultStem: "note")
        return "\(filenameStem).md"
    }

    public func matches(searchQuery rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = "\(title)\n\(content)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return haystack.contains(needle)
    }

    public func retitled(_ newTitle: String) -> Note {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return self }

        var updated = self
        let replacement = "# \(trimmedTitle)"

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.content = "\(replacement)\n"
            return updated
        }

        if let replaced = Self.replacingFirstMeaningfulLine(in: content, with: trimmedTitle) {
            updated.content = replaced
        } else {
            let existing = content.trimmingCharacters(in: .newlines)
            updated.content = "\(replacement)\n\n\(existing)"
        }
        return updated
    }

    public static func derivedTitle(from content: String) -> String {
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let cleaned = line
                .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^>\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return String(cleaned.prefix(80))
            }
        }
        return "New Note"
    }

    public static func sanitizedFilenameStem(from rawValue: String, defaultStem: String) -> String {
        let fallback = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = fallback.isEmpty ? defaultStem : fallback
        let sanitized = candidate.unicodeScalars.reduce(into: "") { partial, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                partial.unicodeScalars.append(scalar)
            } else if partial.last != "-" {
                partial.append("-")
            }
        }
        let stem = sanitized
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        return stem.isEmpty ? defaultStem : stem
    }

    private static func replacingFirstMeaningfulLine(in content: String, with title: String) -> String? {
        var lines = content.components(separatedBy: .newlines)
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }
                let prefix = hashes.isEmpty ? "#" : String(hashes)
                lines[index] = "\(prefix) \(title)"
                return lines.joined(separator: "\n")
            }

            if !isStructuralMarkdown(trimmed) {
                lines[index] = title
                return lines.joined(separator: "\n")
            }

            return nil
        }
        return nil
    }

    private static func isStructuralMarkdown(_ line: String) -> Bool {
        if line.hasPrefix(">") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }
        if line.hasPrefix("```") || line.hasPrefix("|") || line.hasPrefix("![") {
            return true
        }
        return line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil
    }
}
