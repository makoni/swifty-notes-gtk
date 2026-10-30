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
        let root = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Over whole files: a call may be split across lines. A toast made
        // any other way than Toast.plain, or one set back to markup.
        let markupToast = try Regex(
            #"\bToast\s*\(|\bToast\.init\s*\(|\.init\s*\(\s*title\s*:|\.showToast\s*\(|[Tt]oast\w*\s*\.useMarkup\s*=\s*true"#
        )
        var offenders: [String] = []
        var scanned: [String] = []
        for directory in ["Sources/SwiftyNotes", "Sources/SwiftyNotesApp"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            let files = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                scanned.append(file.lastPathComponent)
                guard file.lastPathComponent != "PlainToasts.swift" else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                for match in text.matches(of: markupToast) {
                    let line = text[..<match.range.lowerBound].count { $0 == "\n" } + 1
                    offenders.append("\(file.lastPathComponent):\(line)")
                }
            }
        }
        // The scan read the app, not an empty or moved directory.
        #expect(scanned.contains("PlainToasts.swift") && scanned.count > 50, "\(scanned.count) files")
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
        #expect(markup == "İİİİİİ \(pangoHighlightOpenTag)x</span>")
        #expect(MathInlineText.markup(for: "Area <b>", highlighting: "AREA").markup.hasPrefix("\(pangoHighlightOpenTag)Area</span>"))
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
