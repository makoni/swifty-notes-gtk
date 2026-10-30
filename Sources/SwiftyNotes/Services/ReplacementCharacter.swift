import Foundation

extension Unicode.Scalar {
    /// U+FFFD REPLACEMENT CHARACTER: what a code point the app cannot pass
    /// on as it is becomes.
    static let replacementCharacter: Unicode.Scalar = "\u{FFFD}"
}

extension String {
    /// The string with every code point `shouldReplace` picks turned into
    /// U+FFFD — one for one, so scalar offsets stay where they were — or the
    /// string itself when it picks none.
    func replacingScalars(where shouldReplace: (Unicode.Scalar) -> Bool) -> String {
        guard unicodeScalars.contains(where: shouldReplace) else { return self }
        return String(String.UnicodeScalarView(unicodeScalars.map { shouldReplace($0) ? .replacementCharacter : $0 }))
    }

    /// The string with each NUL turned into U+FFFD. GTK takes text as C
    /// strings, where a NUL ends it: a text buffer refuses such text
    /// outright, and label markup would be cut off mid-tag.
    func replacingNULs() -> String {
        replacingScalars { $0 == "\u{0}" }
    }
}
