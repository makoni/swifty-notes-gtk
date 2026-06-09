import Foundation
@testable import SwiftyNotes
import Testing

struct EmojiShortcodesTests {
    @Test
    func `known shortcodes render to their emoji`() {
        #expect(EmojiShortcodes.render("done :white_check_mark: yes") == "done ✅ yes")
        #expect(EmojiShortcodes.render(":rocket:") == "🚀")
        #expect(EmojiShortcodes.render("hi :smile: there") == "hi 😄 there")
        // No surrounding whitespace — the realistic typo case.
        #expect(EmojiShortcodes.render("x:rocket:y") == "x🚀y")
    }

    @Test
    func `plus and minus shortcodes render`() {
        // :+1: / :-1: exercise the '+' and '-' chars in the shortcode alphabet.
        #expect(EmojiShortcodes.render(":+1:") == "👍")
        #expect(EmojiShortcodes.render(":-1:") == "👎")
        #expect(EmojiShortcodes.render("lgtm :+1: :-1:") == "lgtm 👍 👎")
    }

    @Test
    func `unknown shortcode is left literal`() {
        #expect(EmojiShortcodes.render(":definitely_not_a_real_code:") == ":definitely_not_a_real_code:")
        #expect(EmojiShortcodes.render("a :nope: b") == "a :nope: b")
    }

    @Test
    func `text with no colon is returned unchanged`() {
        let input = "Just some plain prose without any shortcodes at all."
        #expect(EmojiShortcodes.render(input) == input)
    }

    @Test
    func `adjacent shortcodes both render`() {
        // The closing ':' of one shortcode is the opening ':' of the next —
        // the scanner must resume correctly, not swallow the boundary.
        #expect(EmojiShortcodes.render(":smile::rocket:") == "😄🚀")
        #expect(EmojiShortcodes.render(":rocket::rocket::rocket:") == "🚀🚀🚀")
    }

    @Test
    func `empty and degenerate colon runs stay literal`() {
        #expect(EmojiShortcodes.render("::") == "::")
        #expect(EmojiShortcodes.render(":::") == ":::")
        #expect(EmojiShortcodes.render("a :: b") == "a :: b")
        #expect(EmojiShortcodes.render(": :") == ": :")
    }

    @Test
    func `unterminated shortcode is left literal`() {
        #expect(EmojiShortcodes.render("look :smile at this") == "look :smile at this")
        #expect(EmojiShortcodes.render(":rocket") == ":rocket")
    }

    @Test
    func `colon inside non-shortcode text is untouched`() {
        // Times and ratios contain ':' but no valid :word: token.
        #expect(EmojiShortcodes.render("meet at 12:30 today") == "meet at 12:30 today")
        #expect(EmojiShortcodes.render("ratio 16:9") == "ratio 16:9")
        // A space inside the braces means it is not a shortcode.
        #expect(EmojiShortcodes.render(":not a code:") == ":not a code:")
    }

    @Test
    func `shortcodes are case-sensitive lowercase like GitHub`() {
        // gemoji keys are lowercase; uppercase must not match.
        #expect(EmojiShortcodes.render(":SMILE:") == ":SMILE:")
        #expect(EmojiShortcodes.render(":Rocket:") == ":Rocket:")
    }

    @Test
    func `overlong colon token does not match and stays literal`() {
        // Longer than the longest real shortcode — must bail to literal, not hang.
        let long = ":" + String(repeating: "a", count: 200) + ":"
        #expect(EmojiShortcodes.render(long) == long)
    }

    @Test
    func `a failed match does not break a later valid one`() {
        // The unknown span is left literal; a later, well-separated valid
        // shortcode still renders.
        #expect(EmojiShortcodes.render(":nope: then :rocket:") == ":nope: then 🚀")
    }

    @Test
    func `an unknown well-formed span keeps its own colons (gemoji-greedy)`() {
        // gemoji matches `:word:` spans left-to-right; an unknown span is left
        // verbatim and scanning resumes past its closing colon, so the shared
        // colon is not reused to open the next token. Rare abutting edge case.
        #expect(EmojiShortcodes.render(":notreal:rocket:") == ":notreal:rocket:")
    }

    @Test
    func `multiple matches across a longer string`() {
        let input = "tasks :white_check_mark: shipped :rocket: celebrate :tada:"
        #expect(EmojiShortcodes.render(input) == "tasks ✅ shipped 🚀 celebrate 🎉")
    }

    @Test
    func `the map is populated from the bundled gemoji table`() {
        // Guards that the Bundle.module resource actually loaded.
        #expect(EmojiShortcodes.map.count > 1500)
        #expect(EmojiShortcodes.map["white_check_mark"] == "✅")
        #expect(EmojiShortcodes.map["+1"] == "👍")
    }
}
