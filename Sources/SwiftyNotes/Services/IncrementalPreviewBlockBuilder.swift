import Foundation

/// Reuses previously rendered markdown blocks for safe text-only typing
/// edits so long documents do not need a full markdown->HTML->block pass
/// on every debounced preview refresh.
///
/// The incremental path is intentionally conservative: it only activates
/// for documents that segment cleanly into 1:1 heading / paragraph /
/// blockquote / thematic-break blocks. Anything involving lists, tables,
/// images, code fences, task markers, or other structural markdown falls
/// back to the existing full render pipeline.
struct IncrementalPreviewBlockBuilder {
    private struct Snapshot {
        let markdown: String
        let darkAppearance: Bool
        let blocks: [RenderedBlock]
        let segments: [Segment]?
    }

    private enum SegmentKind: Equatable {
        case heading
        case paragraph
        case blockquote
        case thematicBreak
    }

    private struct Segment: Equatable {
        let markdown: String
        let kind: SegmentKind
    }

    private struct SegmentDiff {
        let prefixCount: Int
        let oldChangedRange: Range<Int>
        let newChangedRange: Range<Int>

        var hasChanges: Bool {
            !oldChangedRange.isEmpty || !newChangedRange.isEmpty
        }

        static func between(old oldSegments: [Segment], new newSegments: [Segment]) -> Self {
            let sharedCount = min(oldSegments.count, newSegments.count)
            var prefixCount = 0
            while prefixCount < sharedCount, oldSegments[prefixCount] == newSegments[prefixCount] {
                prefixCount += 1
            }

            var suffixCount = 0
            while suffixCount < sharedCount - prefixCount,
                  oldSegments[oldSegments.count - 1 - suffixCount] == newSegments[newSegments.count - 1 - suffixCount]
            {
                suffixCount += 1
            }

            return .init(
                prefixCount: prefixCount,
                oldChangedRange: prefixCount ..< (oldSegments.count - suffixCount),
                newChangedRange: prefixCount ..< (newSegments.count - suffixCount),
            )
        }
    }

    private static let maximumIncrementalSegmentCount = 8

    private var snapshot: Snapshot?

    private(set) var debugFullRenderCount = 0
    private(set) var debugIncrementalRenderCount = 0

    mutating func blocks(for markdown: String, darkAppearance: Bool) -> [RenderedBlock] {
        if let snapshot,
           snapshot.markdown == markdown,
           snapshot.darkAppearance == darkAppearance
        {
            return snapshot.blocks
        }

        if let snapshot,
           snapshot.darkAppearance == darkAppearance,
           let oldSegments = snapshot.segments,
           let newSegments = Self.parseSegments(from: markdown),
           let incrementallyRendered = Self.incrementalBlocks(
               oldBlocks: snapshot.blocks,
               oldSegments: oldSegments,
               newSegments: newSegments,
               darkAppearance: darkAppearance,
           )
        {
            debugIncrementalRenderCount += 1
            self.snapshot = Snapshot(
                markdown: markdown,
                darkAppearance: darkAppearance,
                blocks: incrementallyRendered,
                segments: newSegments,
            )
            return incrementallyRendered
        }

        let fullyRendered = Self.fullRender(markdown: markdown, darkAppearance: darkAppearance)
        debugFullRenderCount += 1
        snapshot = Snapshot(
            markdown: markdown,
            darkAppearance: darkAppearance,
            blocks: fullyRendered,
            segments: Self.validatedSegments(for: markdown, blocks: fullyRendered),
        )
        return fullyRendered
    }

    private static func fullRender(markdown: String, darkAppearance: Bool) -> [RenderedBlock] {
        HTMLPreviewDocumentBuilder(darkAppearance: darkAppearance).render(markdown: markdown)
    }

    private static func validatedSegments(for markdown: String, blocks: [RenderedBlock]) -> [Segment]? {
        guard let segments = parseSegments(from: markdown),
              segments.count == blocks.count
        else {
            return nil
        }

        for (segment, block) in zip(segments, blocks) {
            guard isCompatible(block: block, with: segment.kind) else {
                return nil
            }
        }

        return segments
    }

    private static func incrementalBlocks(
        oldBlocks: [RenderedBlock],
        oldSegments: [Segment],
        newSegments: [Segment],
        darkAppearance: Bool,
    ) -> [RenderedBlock]? {
        guard oldBlocks.count == oldSegments.count else { return nil }

        let diff = SegmentDiff.between(old: oldSegments, new: newSegments)
        guard diff.hasChanges else { return oldBlocks }

        let changedSegmentCount = max(diff.oldChangedRange.count, diff.newChangedRange.count)
        guard changedSegmentCount <= maximumIncrementalSegmentCount else { return nil }

        var replacementBlocks: [RenderedBlock] = []
        replacementBlocks.reserveCapacity(diff.newChangedRange.count)
        for segment in newSegments[diff.newChangedRange] {
            guard let rendered = renderSegment(segment, darkAppearance: darkAppearance) else {
                return nil
            }
            replacementBlocks.append(rendered)
        }

        let prefix = oldBlocks.prefix(diff.prefixCount)
        let suffix = oldBlocks.suffix(oldBlocks.count - diff.oldChangedRange.upperBound)
        return Array(prefix) + replacementBlocks + suffix
    }

    private static func renderSegment(_ segment: Segment, darkAppearance: Bool) -> RenderedBlock? {
        let rendered = fullRender(markdown: segment.markdown, darkAppearance: darkAppearance)
        guard rendered.count == 1, let block = rendered.first, isCompatible(block: block, with: segment.kind) else {
            return nil
        }
        return block
    }

    private static func isCompatible(block: RenderedBlock, with kind: SegmentKind) -> Bool {
        switch (block, kind) {
        case (.heading, .heading),
             (.paragraph, .paragraph),
             (.blockquote, .blockquote),
             (.thematicBreak, .thematicBreak):
            true
        default:
            false
        }
    }

    private static func parseSegments(from markdown: String) -> [Segment]? {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var rawSegments: [String] = []
        var currentLines: [String] = []

        func flushCurrentSegment() {
            guard !currentLines.isEmpty else { return }
            rawSegments.append(currentLines.joined(separator: "\n"))
            currentLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if isBlankLine(line) {
                flushCurrentSegment()
                continue
            }
            currentLines.append(line)
        }
        flushCurrentSegment()

        var segments: [Segment] = []
        segments.reserveCapacity(rawSegments.count)
        for rawSegment in rawSegments {
            guard let segment = parseSegment(rawSegment) else {
                return nil
            }
            segments.append(segment)
        }
        return segments
    }

    private static func parseSegment(_ markdown: String) -> Segment? {
        let lines = markdown.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        if lines.contains(where: lineHasUnsafeStructure(_:)) {
            return nil
        }

        if lines.count == 1, isAtxHeadingLine(lines[0]) {
            return .init(markdown: markdown, kind: .heading)
        }

        if lines.count == 1, isThematicBreakLine(lines[0]) {
            return .init(markdown: markdown, kind: .thematicBreak)
        }

        if lines.allSatisfy(isBlockquoteLine(_:)) {
            return .init(markdown: markdown, kind: .blockquote)
        }

        if lines.dropFirst().contains(where: { isAtxHeadingLine($0) || isThematicBreakLine($0) || isSetextHeadingUnderline($0) }) {
            return nil
        }

        return .init(markdown: markdown, kind: .paragraph)
    }

    private static func isBlankLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isBlockquoteLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(">")
    }

    private static func isAtxHeadingLine(_ line: String) -> Bool {
        var trimmed = line[...]
        var leadingSpaces = 0
        while leadingSpaces < 3, trimmed.first == " " {
            trimmed.removeFirst()
            leadingSpaces += 1
        }
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return false }
        let afterHashes = trimmed.dropFirst(hashes.count)
        return afterHashes.first?.isWhitespace == true
    }

    private static func isThematicBreakLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let characters = Set(trimmed)
        guard characters.count == 1, let marker = characters.first else { return false }
        return marker == "-" || marker == "*" || marker == "_"
    }

    private static func isSetextHeadingUnderline(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let characters = Set(trimmed)
        if characters.count != 1 { return false }
        return characters.first == "=" || characters.first == "-"
    }

    private static func lineHasUnsafeStructure(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return false
        }

        if line.hasPrefix("\t") || line.hasPrefix("    ") {
            return true
        }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            return true
        }
        if trimmed.hasPrefix("![") || trimmed.contains("<img") {
            return true
        }
        if trimmed.hasPrefix("|") || trimmed.contains("| ---") || trimmed.contains("|---") {
            return true
        }
        if trimmed.hasPrefix("<") {
            return true
        }
        if isBulletListLine(trimmed) || isOrderedListLine(trimmed) {
            return true
        }
        return false
    }

    private static func isBulletListLine(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "+" else {
            return false
        }
        let nextIndex = trimmed.index(after: trimmed.startIndex)
        return nextIndex < trimmed.endIndex && trimmed[nextIndex].isWhitespace
    }

    private static func isOrderedListLine(_ trimmed: String) -> Bool {
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            index = trimmed.index(after: index)
        }
        guard index != trimmed.startIndex, index < trimmed.endIndex else { return false }
        let marker = trimmed[index]
        guard marker == "." || marker == ")" else { return false }
        let afterMarker = trimmed.index(after: index)
        return afterMarker < trimmed.endIndex && trimmed[afterMarker].isWhitespace
    }
}
