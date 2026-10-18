import Adwaita
import CAdwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct PangoMarkupEscapingTests {
    /// Text whose markup characters are followed by combining marks: "≮"
    /// decomposed, `&` + acute, `>` + acute, a quote + acute.
    private let tricky = "a <\u{338} b &\u{301}lt; c >\u{301} \"\u{301} d"

    @Test("Escaping works per code point, so combining marks cannot hide markup characters")
    func escapingWorksPerCodePoint() {
        // Built outside #expect: the macro mis-renders a string literal with
        // an escaped quote followed by a combining mark.
        let expected = "a &lt;\u{338} b &amp;\u{301}lt; c &gt;\u{301} \"\u{301} d"
        let escaped = pangoEscape(tricky)
        #expect(escaped == expected)
        #expect(pangoEscapeAttribute(tricky).contains("&quot;\u{301}"))
        #expect(parses(pangoEscape(tricky)))
    }

    @Test("Toasts show their text as written, not as markup") @MainActor
    func toastsShowTheirTextAsWritten() {
        #expect(!Toast.plain("A & B <draft>").useMarkup)
    }

    @Test("Every toast in the app is a plain one")
    func everyToastInTheAppIsAPlainOne() throws {
        // A note's title or an error message in a markup toast breaks it.
        let sources = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SwiftyNotes", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        // Over whole files: a call may be split across lines.
        let markupToast = try Regex(#"\bToast\s*\(|\.showToast\s*\("#)
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "PlainToasts.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in text.matches(of: markupToast) {
                let line = text[..<match.range.lowerBound].count { $0 == "\n" } + 1
                offenders.append("\(url.lastPathComponent):\(line)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("A NUL becomes a replacement character, since GTK reads markup as a C string")
    func aNULBecomesAReplacementCharacter() {
        let escaped = pangoEscape("a\u{0}<b>")
        #expect(escaped == "a\u{FFFD}&lt;b&gt;")
        #expect(parses("<span>\(escaped)</span>"))
    }

    @Test("The breadcrumb strip's markup parses for any heading text") @MainActor
    func breadcrumbMarkupParsesForAnyHeadingText() {
        for (title, section, leaf) in [
            (tricky, tricky, tricky),
            ("Doc", tricky, nil),
            ("", nil, tricky),
        ] {
            let markup = BreadcrumbStrip.buildMathMarkup(docTitle: title, section: section, leaf: leaf).markup
            #expect(parses(markup), "\(markup)")
        }
    }

    @Test("Filter highlights survive text that lowercasing makes longer")
    func filterHighlightsSurviveTextThatLowercasingMakesLonger() {
        // "İ" lowercases to two code points, so ranges found in the
        // lowercased text used to run past the end of the original.
        let markup = MathInlineText.markup(for: "İİİİİİ x", highlighting: "x").markup
        #expect(markup == "İİİİİİ <span background=\"#f5c211\" foreground=\"#1e1e1e\">x</span>")
        #expect(MathInlineText.markup(for: "Area <b>", highlighting: "AREA").markup.hasPrefix("<span background=\"#f5c211\" foreground=\"#1e1e1e\">Area</span>"))
        #expect(parses(MathInlineText.markup(for: tricky, highlighting: "a").markup))
        #expect(MathInlineText.markup(for: "a<b").markup == "a&lt;b")
    }

    private func parses(_ markup: String) -> Bool {
        var error: UnsafeMutablePointer<GError>?
        let ok = pango_parse_markup(markup, -1, 0, nil, nil, nil, &error) != 0
        if let error { g_error_free(error) }
        return ok
    }
}
