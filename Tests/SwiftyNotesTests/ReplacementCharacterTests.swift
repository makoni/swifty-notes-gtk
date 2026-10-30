import Foundation
@testable import SwiftyNotes
import Testing

struct ReplacementCharacterTests {
    @Test("Each NUL becomes one replacement character")
    func eachNULBecomesOneReplacementCharacter() {
        let text = "\u{0}a\u{0}\u{0}b👍🏽\u{0}"
        let replaced = text.replacingNULs()
        #expect(replaced == "\u{FFFD}a\u{FFFD}\u{FFFD}b👍🏽\u{FFFD}")
        // One for one: scalar offsets stay where they were.
        #expect(replaced.unicodeScalars.count == text.unicodeScalars.count)
    }

    @Test("Text without a NUL comes back unchanged")
    func textWithoutANULComesBackUnchanged() {
        let text = "Plain \u{FFFC} text, é and e\u{301}"
        #expect(text.replacingNULs().unicodeScalars.elementsEqual(text.unicodeScalars))
        #expect("".replacingNULs() == "")
    }

    @Test("Any code point can be picked for replacement")
    func anyCodePointCanBePickedForReplacement() {
        #expect("a\u{FFFC}b".replacingScalars { $0 == "\u{FFFC}" } == "a\u{FFFD}b")
        // A combining mark is replaced on its own, not with its base.
        #expect("e\u{301}".replacingScalars { $0 == "\u{301}" }.unicodeScalars.map(\.value) == [0x65, 0xFFFD])
    }

    @Test("Label markup and math sanitising share the replacement")
    func labelMarkupAndMathSanitisingShareTheReplacement() {
        #expect(pangoEscape("\u{0}&") == "\u{FFFD}&amp;")
        #expect(MathSpanExtractor.markerFree("x\u{FFFC}y") == "x\u{FFFD}y")
        // A reserved noncharacter typed in the note cannot pose as a placeholder.
        let typed = "a\(MathSpanExtractor.placeholder(for: 0)) $x$"
        #expect(MathSpanExtractor.extract(from: typed).markdown.hasPrefix("a\u{FFFD}\u{FFFD}\u{FFFD} "))
    }
}
