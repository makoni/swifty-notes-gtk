import Foundation

/// Renders GitHub-style Markdown emoji shortcodes (`:white_check_mark:` → ✅)
/// using the bundled gemoji vocabulary (`Resources/emoji-shortcodes.tsv`,
/// regenerate with `scripts/generate-emoji-table.sh`).
///
/// This is pure text substitution — the emoji *glyphs* are drawn by the
/// platform's color-emoji font (Noto Color Emoji on Linux, Apple Color Emoji
/// on macOS) via Pango, so we ship only the ~34 KB name→character map, never
/// any images.
///
/// Matching mirrors gemoji: well-formed `:word:` spans are scanned
/// left-to-right and replaced when the word is a known alias. An unknown
/// well-formed span is left verbatim and scanning resumes past its closing
/// colon (so `:notreal:rocket:` stays literal, while `:smile::rocket:` and
/// `:tada: well done :rocket:` both render). The alphabet is GitHub's
/// lowercase `[a-z0-9_+-]`, so `:SMILE:` and bare colons in `12:30` are
/// untouched.
enum EmojiShortcodes {
    /// Shortcode (without the surrounding colons) → emoji character.
    /// Parsed once from the bundled table on first use. Immutable value of a
    /// `Sendable` type, so it is safe to read from any actor under Swift 6
    /// strict concurrency without isolation.
    static let map: [String: String] = load()

    private static let colon: UInt8 = 0x3A

    /// Upper bound on the inline scan past a `:`. The longest real gemoji
    /// alias is 40 bytes; 64 leaves headroom and keeps a stray colon from
    /// triggering an unbounded forward search (worst case stays O(n · 64)).
    private static let maxShortcodeLength = 64

    private static func load() -> [String: String] {
        guard let url = Bundle.module.url(forResource: "emoji-shortcodes", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        result.reserveCapacity(2048)
        // Split on any newline (handles LF and CRLF, so a future
        // regeneration on a CRLF host can't leave \r on every emoji value).
        for line in text.split(whereSeparator: \.isNewline) {
            if line.first == "#" { continue }
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let code = line[line.startIndex..<tab]
            let emoji = line[line.index(after: tab)...]
            if !code.isEmpty, !emoji.isEmpty {
                result[String(code)] = String(emoji)
            }
        }
        return result
    }

    /// Replaces every recognised `:shortcode:` in `text` with its emoji.
    /// Returns `text` unchanged (no allocation) when it contains no `:`.
    static func render(_ text: String) -> String {
        // Fast path: the overwhelming majority of text runs have no ':' at
        // all, so bail before touching the map or allocating anything.
        guard text.utf8.contains(colon) else { return text }

        let src = Array(text.utf8)
        let count = src.count
        var out: [UInt8] = []
        var replaced = false
        // Bytes in `src[copiedUpTo..<i]` are verbatim and not yet flushed to
        // `out`; we copy them as a single slice right before each emoji (and
        // once at the end), so `out` is only allocated after the first match.
        var copiedUpTo = 0
        var index = 0

        while index < count {
            guard src[index] == colon else {
                index += 1
                continue
            }
            // Scan a candidate shortcode body [a-z0-9_+-] after the ':'.
            var end = index + 1
            let limit = min(count, index + 1 + maxShortcodeLength)
            while end < limit, isShortcodeByte(src[end]) {
                end += 1
            }
            // A well-formed span needs a non-empty body closed by ':'.
            if end > index + 1, end < count, src[end] == colon {
                let key = String(decoding: src[(index + 1)..<end], as: UTF8.self)
                if let emoji = map[key] {
                    if !replaced {
                        replaced = true
                        out.reserveCapacity(count)
                    }
                    out.append(contentsOf: src[copiedUpTo..<index])
                    out.append(contentsOf: emoji.utf8)
                    index = end + 1
                    copiedUpTo = index
                    continue
                }
                // Well-formed but unknown: leave the whole span literal and
                // resume past its closing colon (gemoji-greedy).
                index = end + 1
                continue
            }
            // Lone ':' or unterminated token: skip just this colon so a later
            // colon can still open a shortcode.
            index += 1
        }

        guard replaced else { return text }
        out.append(contentsOf: src[copiedUpTo..<count])
        return String(decoding: out, as: UTF8.self)
    }

    private static func isShortcodeByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x61...0x7A, // a-z
             0x30...0x39, // 0-9
             0x5F,        // _
             0x2B,        // +
             0x2D:        // -
            true
        default:
            false
        }
    }
}
