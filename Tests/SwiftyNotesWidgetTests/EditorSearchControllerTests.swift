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

    @Test("Typing a query selects the first match at or after the cursor") @MainActor
    func typingAQuerySelectsTheFirstMatchAtOrAfterTheCursor() throws {
        let rig = try Self.makeRig(suffix: "firstmatch", text: "alpha beta alpha gamma alpha")
        // Cursor at start; first match is "alpha" at 0..<5.
        rig.editor.buffer.placeCursor(at: 0)
        rig.bar.debugTypeQuery("alpha")
        #expect(rig.editor.buffer.selectedRange == 0..<5)
        #expect(rig.controller.debugMatchCount == 3)
        #expect(rig.controller.debugActiveIndex == 0)
        #expect(rig.bar.countLabel.text == "1 of 3")
    }

    @Test("Next button steps forward and wraps from last to first") @MainActor
    func nextButtonStepsForwardAndWrapsFromLastToFirst() throws {
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

    @Test("Prev button steps backward and wraps from first to last") @MainActor
    func prevButtonStepsBackwardAndWrapsFromFirstToLast() throws {
        let rig = try Self.makeRig(suffix: "prev-wrap", text: "alpha beta alpha gamma alpha")
        rig.editor.buffer.placeCursor(at: 0)
        rig.bar.debugTypeQuery("alpha")
        // After first match it's at index 0. Prev should wrap to last.
        rig.bar.debugClickPrev()
        #expect(rig.controller.debugActiveIndex == 2)
        #expect(rig.editor.buffer.selectedRange == 23..<28)
    }

    @Test("Auto-step lands on the match nearest below the cursor, not always the first one") @MainActor
    func autoStepLandsOnTheMatchNearestBelowTheCursorNotAlways() throws {
        let rig = try Self.makeRig(suffix: "cursoraware", text: "alpha beta alpha gamma alpha")
        // Place cursor between match #1 and match #2.
        rig.editor.buffer.placeCursor(at: 7)
        rig.bar.debugTypeQuery("alpha")
        // The next match at or after offset 7 is match #2 (11..<16).
        #expect(rig.controller.debugActiveIndex == 1)
        #expect(rig.editor.buffer.selectedRange == 11..<16)
    }

    @Test("Toggling case-sensitive re-runs the search and updates the count") @MainActor
    func togglingCaseSensitiveReRunsTheSearchAndUpdatesTheCount() throws {
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

    @Test("Clearing the query clears matches + count") @MainActor
    func clearingTheQueryClearsMatchesCount() throws {
        let rig = try Self.makeRig(suffix: "clear", text: "alpha beta alpha")
        rig.bar.debugTypeQuery("alpha")
        #expect(rig.controller.debugMatchCount == 2)
        rig.bar.debugTypeQuery("")
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugActiveIndex == nil)
        #expect(rig.bar.countLabel.text.isEmpty)
    }

    @Test("Closing the bar resets state so a re-open starts fresh") @MainActor
    func closingTheBarResetsStateSoAReOpenStartsFresh() throws {
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

    @Test("Editing the buffer re-scans cached matches") @MainActor
    func editingTheBufferReScansCachedMatches() throws {
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

    @Test("Replace one swaps the active match and steps to the next") @MainActor
    func replaceOneSwapsTheActiveMatchAndStepsToTheNext() throws {
        let rig = try Self.makeRig(suffix: "replaceone", text: "foo bar foo baz foo")
        rig.bar.setVisible(true, mode: .replace)
        rig.bar.debugTypeQuery("foo")
        rig.bar.replacement = "X"
        // First match (offset 0..<3) is active. Replace.
        rig.bar.debugClickReplace()
        #expect(rig.editor.buffer.text == "X bar foo baz foo")
        // After replace, controller auto-steps to the next match
        // (which used to be at offset 8 and is now at offset 6).
        #expect(rig.editor.buffer.selectedRange == 6..<9)
        #expect(rig.controller.debugMatchCount == 2)
    }

    @Test("Replace all swaps every match and reports the count") @MainActor
    func replaceAllSwapsEveryMatchAndReportsTheCount() throws {
        let rig = try Self.makeRig(suffix: "replaceall", text: "foo bar foo baz foo")
        rig.bar.setVisible(true, mode: .replace)
        var observed: Int?
        rig.controller.onReplaceAllCompleted = { observed = $0 }
        rig.bar.debugTypeQuery("foo")
        rig.bar.replacement = "X"
        rig.bar.debugClickReplaceAll()
        #expect(rig.editor.buffer.text == "X bar X baz X")
        #expect(observed == 3)
        // After mass replace, matches against the new buffer are 0.
        #expect(rig.controller.debugMatchCount == 0)
    }

    @Test("Replace in regex mode expands backrefs") @MainActor
    func replaceInRegexModeExpandsBackrefs() throws {
        let rig = try Self.makeRig(suffix: "regexreplace", text: "hello world hello")
        rig.bar.setVisible(true, mode: .replace)
        rig.bar.options = SearchOptions(regex: true)
        rig.bar.debugTypeQuery("(h)ello")
        rig.bar.replacement = "[$1]ELLO"
        rig.bar.debugClickReplaceAll()
        #expect(rig.editor.buffer.text == "[h]ELLO world [h]ELLO")
    }

    @Test("Replace in read-only bar is a no-op") @MainActor
    func replaceInReadOnlyBarIsANoOp() throws {
        let rig = try Self.makeRig(suffix: "readonly-replace", text: "foo foo")
        rig.bar.isReadOnly = true
        rig.bar.setVisible(true, mode: .replace)
        rig.bar.debugTypeQuery("foo")
        rig.bar.replacement = "X"
        let before = rig.editor.buffer.text
        rig.bar.debugClickReplace()
        rig.bar.debugClickReplaceAll()
        #expect(rig.editor.buffer.text == before)
    }

    @Test("Replace with no active match is a no-op") @MainActor
    func replaceWithNoActiveMatchIsANoOp() throws {
        let rig = try Self.makeRig(suffix: "noactive-replace", text: "alpha beta")
        rig.bar.setVisible(true, mode: .replace)
        // Don't type anything — nothing active.
        let before = rig.editor.buffer.text
        rig.bar.replacement = "X"
        rig.bar.debugClickReplace()
        rig.bar.debugClickReplaceAll()
        #expect(rig.editor.buffer.text == before)
    }

    @Test("Highlight tags are created on first non-empty query") @MainActor
    func highlightTagsAreCreatedOnFirstNonEmptyQuery() throws {
        let rig = try Self.makeRig(suffix: "tag-created", text: "needle in a haystack with needle")
        // No tags exist before searching.
        #expect(rig.controller.debugMatchTagCreated == false)
        #expect(rig.controller.debugActiveTagCreated == false)
        rig.bar.debugTypeQuery("needle")
        // Both tags exist after the first match recomputation.
        #expect(rig.controller.debugMatchTagCreated == true)
        #expect(rig.controller.debugActiveTagCreated == true)
    }

    @Test("Clearing the bar removes match highlights from the buffer") @MainActor
    func clearingTheBarRemovesMatchHighlightsFromTheBuffer() throws {
        // We can't easily introspect which characters carry the tag
        // in a headless test, but the contract is: after close,
        // clear is called. Cover the path by ensuring the bar
        // transitions through close + the controller releases its
        // cached query.
        let rig = try Self.makeRig(suffix: "highlight-clear", text: "alpha alpha alpha")
        rig.bar.setVisible(true)
        rig.bar.debugTypeQuery("alpha")
        #expect(rig.controller.debugMatchCount == 3)
        rig.bar.setVisible(false)
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugActiveIndex == nil)
    }

    @Test("No matches → shows \"No matches\" + cursor doesn't move") @MainActor
    func noMatchesShowsNoMatchesCursorDoesntMove() throws {
        let rig = try Self.makeRig(suffix: "nomatches", text: "alpha beta gamma")
        rig.editor.buffer.placeCursor(at: 7)
        let cursorBefore = rig.editor.buffer.selectedRange
        rig.bar.debugTypeQuery("zzz")
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugActiveIndex == nil)
        #expect(rig.editor.buffer.selectedRange == cursorBefore)
        // Phase 7 polish: when the query is non-empty but produces
        // zero hits, the count label flips to "No matches" rather
        // than going invisible — gives users feedback that the
        // search actually ran.
        #expect(rig.bar.countLabel.text == "No matches")
        #expect(rig.bar.countLabel.visible == true)
    }
}
#endif
