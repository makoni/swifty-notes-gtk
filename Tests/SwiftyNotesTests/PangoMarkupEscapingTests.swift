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

    @Test("The breadcrumb strip's markup parses for any heading text") @MainActor
    func breadcrumbMarkupParsesForAnyHeadingText() {
        for (title, section, leaf) in [
            (tricky, tricky, tricky),
            ("Doc", tricky, nil),
            ("", nil, tricky),
        ] {
            let markup = BreadcrumbStrip.buildMarkup(docTitle: title, section: section, leaf: leaf)
            #expect(parses(markup), "\(markup)")
        }
    }

    private func parses(_ markup: String) -> Bool {
        var error: UnsafeMutablePointer<GError>?
        let ok = pango_parse_markup(markup, -1, 0, nil, nil, nil, &error) != 0
        if let error { g_error_free(error) }
        return ok
    }
}
