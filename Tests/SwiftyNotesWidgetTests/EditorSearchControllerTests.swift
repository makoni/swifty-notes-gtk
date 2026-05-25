#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct EditorSearchControllerTests {
    @MainActor
    private static func makeRig(suffix: String, text: String) throws -> (
        editor: MarkdownEditor,
        bar: FindReplaceBar,
        controller: EditorSearchController,
    ) {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.editorsearch.\(suffix)")
        try app.register()
        var editor = MarkdownEditor()
        editor.setText(text)
        let bar = FindReplaceBar()
        let controller = EditorSearchController(bar: bar, view: editor.view, buffer: editor.buffer)
        return (editor, bar, controller)
    }

    @Test @MainActor
    func `typing a query selects the first match at or after the cursor`() throws {
        let rig = try Self.makeRig(suffix: "firstmatch", text: "alpha beta alpha gamma alpha")
        // Cursor at start; first match is "alpha" at 0..<5.
        rig.editor.buffer.placeCursor(at: 0)
        rig.bar.debugTypeQuery("alpha")
        #expect(rig.editor.buffer.selectedRange == 0..<5)
        #expect(rig.controller.debugMatchCount == 3)
        #expect(rig.controller.debugActiveIndex == 0)
        #expect(rig.bar.countLabel.text == "1 of 3")
    }

    @Test @MainActor
    func `next button steps forward and wraps from last to first`() throws {
        let rig = try Self.makeRig(suffix: "next-wrap", text: "alpha beta alpha gamma alpha")
        rig.editor.buffer.placeCursor(at: 0)
        rig.bar.debugTypeQuery("alpha")
        rig.bar.debugClickNext()
        // Match 1 → match 2 (11..<16).
        #expect(rig.editor.buffer.selectedRange == 11..<16)
        #expect(rig.controller.debugActiveIndex == 1)

        rig.bar.debugClickNext()
        #expect(rig.editor.buffer.selectedRange == 23..<28)
        #expect(rig.controller.debugActiveIndex == 2)

        rig.bar.debugClickNext()
        // Wrap to first match.
        #expect(rig.editor.buffer.selectedRange == 0..<5)
        #expect(rig.controller.debugActiveIndex == 0)
    }

    @Test @MainActor
    func `prev button steps backward and wraps from first to last`() throws {
        let rig = try Self.makeRig(suffix: "prev-wrap", text: "alpha beta alpha gamma alpha")
        rig.editor.buffer.placeCursor(at: 0)
        rig.bar.debugTypeQuery("alpha")
        // After first match it's at index 0. Prev should wrap to last.
        rig.bar.debugClickPrev()
        #expect(rig.controller.debugActiveIndex == 2)
        #expect(rig.editor.buffer.selectedRange == 23..<28)
    }

    @Test @MainActor
    func `auto-step lands on the match nearest below the cursor, not always the first one`() throws {
        let rig = try Self.makeRig(suffix: "cursoraware", text: "alpha beta alpha gamma alpha")
        // Place cursor between match #1 and match #2.
        rig.editor.buffer.placeCursor(at: 7)
        rig.bar.debugTypeQuery("alpha")
        // The next match at or after offset 7 is match #2 (11..<16).
        #expect(rig.controller.debugActiveIndex == 1)
        #expect(rig.editor.buffer.selectedRange == 11..<16)
    }

    @Test @MainActor
    func `toggling case-sensitive re-runs the search and updates the count`() throws {
        let rig = try Self.makeRig(suffix: "case-toggle", text: "Test the testing testTube")
        rig.editor.buffer.placeCursor(at: 0)
        rig.bar.debugTypeQuery("test")
        // Case-insensitive default: 3 matches (Test, testing, testTube).
        #expect(rig.controller.debugMatchCount == 3)

        rig.bar.debugToggleCaseSensitive()
        // Only the lowercase "testing" and "testTube" contain "test"
        // with exact case (the "Test" at offset 0 drops out).
        #expect(rig.controller.debugMatchCount == 2)
    }

    @Test @MainActor
    func `clearing the query clears matches + count`() throws {
        let rig = try Self.makeRig(suffix: "clear", text: "alpha beta alpha")
        rig.bar.debugTypeQuery("alpha")
        #expect(rig.controller.debugMatchCount == 2)
        rig.bar.debugTypeQuery("")
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugActiveIndex == nil)
        #expect(rig.bar.countLabel.text.isEmpty)
    }

    @Test @MainActor
    func `closing the bar resets state so a re-open starts fresh`() throws {
        let rig = try Self.makeRig(suffix: "close-reset", text: "alpha alpha")
        rig.bar.setVisible(true)
        rig.bar.debugTypeQuery("alpha")
        #expect(rig.controller.debugMatchCount == 2)
        rig.bar.setVisible(false)
        // onClose path cleared the cached query, so the cached
        // match list is empty even though the buffer still has
        // matches in it.
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugCachedQuery.isEmpty)
    }

    @Test @MainActor
    func `editing the buffer re-scans cached matches`() throws {
        let rig = try Self.makeRig(suffix: "rescan", text: "foo foo foo")
        rig.editor.buffer.placeCursor(at: 0)
        rig.bar.debugTypeQuery("foo")
        #expect(rig.controller.debugMatchCount == 3)
        // Replace the buffer wholesale — the buffer-change handler
        // should pick this up and recompute.
        rig.editor.buffer.text = "foo bar baz qux foo"
        rig.controller.debugRecomputeFromBuffer()
        // Two matches left.
        #expect(rig.controller.debugMatchCount == 2)
    }

    @Test @MainActor
    func `no matches → count stays empty + cursor doesn't move`() throws {
        let rig = try Self.makeRig(suffix: "nomatches", text: "alpha beta gamma")
        rig.editor.buffer.placeCursor(at: 7)
        let cursorBefore = rig.editor.buffer.selectedRange
        rig.bar.debugTypeQuery("zzz")
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugActiveIndex == nil)
        #expect(rig.editor.buffer.selectedRange == cursorBefore)
        #expect(rig.bar.countLabel.text.isEmpty)
    }
}
#endif
