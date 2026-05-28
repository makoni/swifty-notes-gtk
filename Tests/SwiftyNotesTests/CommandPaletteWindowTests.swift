#if !os(macOS)
    import Adwaita
    import CAdwaita
    import Foundation
    @testable import SwiftyNotes
    import Testing

    @Suite(.serialized)
    struct CommandPaletteWindowTests {
        @MainActor
        private static func ensureAdwInit() {
            struct Once { nonisolated(unsafe) static var done = false }
            guard !Once.done else { return }
            adw_init()
            Once.done = true
        }

        @MainActor
        private static func makePalette(
            suffix: String,
            headings: [Heading],
            currentID: String? = nil,
            recents: [String] = [],
            onPick: @escaping (String) -> Void = { _ in },
            onClosed: @escaping () -> Void = {},
        ) throws -> CommandPaletteWindow {
            Self.ensureAdwInit()
            let app = Application(id: "me.spaceinbox.swiftynotes.tests.palette.\(suffix)")
            try app.register()
            let parent = ApplicationWindow(application: app)
            return CommandPaletteWindow(
                transientFor: parent,
                headings: headings,
                currentID: currentID,
                recents: recents,
                onPick: onPick,
                onClosed: onClosed,
            )
        }

        private static let sampleHeadings: [Heading] = [
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
            .init(id: "goals", level: 3, text: "Goals", blockIndex: 1, line: 3),
            .init(id: "features", level: 2, text: "Features", blockIndex: 2, line: 5),
            .init(id: "outline", level: 3, text: "Markdown Outline", blockIndex: 3, line: 7),
            .init(id: "search", level: 3, text: "Search v2", blockIndex: 4, line: 9),
        ]

        @Test @MainActor
        func `empty query shows recents first, then the rest in document order`() throws {
            let palette = try Self.makePalette(
                suffix: "recents",
                headings: Self.sampleHeadings,
                recents: ["search", "goals"],
            )
            // Recents lead (newest first), remaining headings follow in
            // document order excluding already-listed recents.
            #expect(palette.debugItems.map(\.id) == ["search", "goals", "overview", "features", "outline"])
        }

        @Test @MainActor
        func `empty query falls back to document order when there are no recents`() throws {
            let palette = try Self.makePalette(suffix: "norecents", headings: Self.sampleHeadings)
            #expect(palette.debugItems.map(\.id) == ["overview", "goals", "features", "outline", "search"])
        }

        @Test @MainActor
        func `typing a query switches to ranked match list`() throws {
            let palette = try Self.makePalette(suffix: "ranked", headings: Self.sampleHeadings)
            palette.debugSetQuery("outline")
            // Markdown Outline matches title-contains (rank 1); other rows
            // don't contain "outline" so they drop out.
            #expect(palette.debugItems.map(\.id) == ["outline"])
        }

        @Test @MainActor
        func `currentID defaults the highlight to that row when query is empty`() throws {
            let palette = try Self.makePalette(
                suffix: "current",
                headings: Self.sampleHeadings,
                currentID: "features",
            )
            // No recents → items come in document order; "features" is
            // index 2 in that ordering.
            #expect(palette.debugHighlightIndex == 2)
        }

        @Test @MainActor
        func `arrow-down moves highlight forward, clamped at the end`() throws {
            let palette = try Self.makePalette(suffix: "arrow", headings: Self.sampleHeadings)
            #expect(palette.debugHighlightIndex == 0)
            palette.debugMove(by: 1)
            #expect(palette.debugHighlightIndex == 1)
            palette.debugMove(by: 5) // beyond end
            #expect(palette.debugHighlightIndex == Self.sampleHeadings.count - 1)
            palette.debugMove(by: -100) // beyond start
            #expect(palette.debugHighlightIndex == 0)
        }

        @Test @MainActor
        func `enter activates the highlighted row and calls onPick`() throws {
            @MainActor
            final class PickRecorder {
                var picked: String?
            }
            let recorder = PickRecorder()
            let palette = try Self.makePalette(
                suffix: "enter",
                headings: Self.sampleHeadings,
                onPick: { id in
                    recorder.picked = id
                },
            )
            palette.debugMove(by: 2) // highlight Features
            palette.debugActivateHighlighted()
            #expect(recorder.picked == "features")
        }

        /// Regression guard: commit `2d19306` permanently moves focus to SearchEntry.
        /// `GtkSearchEntry` intercepts Escape by emitting `stop-search` + returning
        /// `GDK_EVENT_STOP`, so the `GTK_SHORTCUT_SCOPE_LOCAL` shortcut on the dialog
        /// never fires.  The fix is to connect `onStopSearch` — the GTK4-idiomatic
        /// signal SearchEntry emits precisely so parent containers can dismiss.
        ///
        /// This test emits `stop-search` directly (simulating what GTK does when
        /// the user presses Escape with focus on the search entry) and verifies that
        /// `dialog.close()` is called. We check `debugCloseCallCount` rather than
        /// `onClosed` because `adw_dialog_close` only emits the GLib `closed` signal
        /// for a dialog that has been presented to a window.
        @Test @MainActor
        func `Escape via stop-search signal closes the palette`() throws {
            let palette = try Self.makePalette(
                suffix: "esc-stop-search",
                headings: Self.sampleHeadings,
            )
            // Simulate what GtkSearchEntry does when Escape is pressed.
            palette.debugEmitStopSearch()
            #expect(palette.debugCloseCallCount == 1)
        }
    }
#endif
