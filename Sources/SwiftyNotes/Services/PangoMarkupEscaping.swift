import Foundation

// Pango markup escaping for text put into label markup.
//
// It works one code point at a time. Replacing whole characters (what
// `String.replacingOccurrences` and a `for character in text` loop do) misses
// `<` or `&` that a combining mark follows — "≮" decomposes into `<` +
// U+0338 — and the label then fails to parse its markup: GTK logs the whole
// markup (the note's text) and the label keeps its old content.
// swift-adwaita's `PangoMarkup.escape` loops over characters, so the app
// uses these instead.

/// Escapes text for Pango markup, one code point at a time: string
/// replacement matches whole characters, so `&` or `<` followed by a
/// combining mark (`<` + U+0338 is how "≮" decomposes) would slip through
/// and break the markup.
func pangoEscape(_ text: String) -> String {
    escapedForMarkup(text, quotes: false)
}

func pangoEscapeAttribute(_ text: String) -> String {
    escapedForMarkup(text, quotes: true)
}

/// Opens the highlight of a filter match (the outline and command palette
/// filters, ``MathInlineText/markup(for:highlighting:)``).
let pangoHighlightOpenTag = "<span background=\"#f5c211\" foreground=\"#1e1e1e\">"

private func escapedForMarkup(_ text: String, quotes: Bool) -> String {
    var result = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": result.append(contentsOf: "&amp;".unicodeScalars)
        case "<": result.append(contentsOf: "&lt;".unicodeScalars)
        case ">": result.append(contentsOf: "&gt;".unicodeScalars)
        case "\"" where quotes: result.append(contentsOf: "&quot;".unicodeScalars)
        // GTK reads the markup as a C string: a NUL would end it mid-tag.
        case "\u{0}": result.append("\u{FFFD}")
        default: result.append(scalar)
        }
    }
    return String(result)
}
