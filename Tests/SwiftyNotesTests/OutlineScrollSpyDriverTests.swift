#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct OutlineScrollSpyDriverTests {
    @MainActor
    private static func makeDriver(suffix: String, onActive: @escaping (String?) -> Void) throws -> OutlineScrollSpyDriver {
        // Driver doesn't actually wire signals until `rebind(mode:)`
        // is called, but it still needs realistic widgets to ask for
        // adjustments on — so we build a minimal Application + couple
        // of ScrolledWindows and stitch them in.
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.spy.\(suffix)")
        try app.register()
        let editorScroll = ScrolledWindow()
        let previewScroll = ScrolledWindow()
        return OutlineScrollSpyDriver(
            editorScroll: editorScroll,
            previewScroll: previewScroll,
            resolveHeadings: { [
                .init(id: "a", level: 2, text: "A", blockIndex: 0, line: 1),
                .init(id: "b", level: 2, text: "B", blockIndex: 1, line: 5),
            ] },
            previewPositions: { headings in
                headings.map { ($0.id, $0.id == "a" ? 0.0 : 500.0) }
            },
            editorPositions: { headings in
                headings.map { ($0.id, $0.id == "a" ? 0.0 : 500.0) }
            },
            onActive: onActive,
        )
    }

    @Test("Suppress window blocks the resolver until the deadline passes") @MainActor
    func suppressWindowBlocksTheResolverUntilTheDeadlinePasses() throws {
        @MainActor final class Recorder { var calls: [String?] = [] }
        let recorder = Recorder()
        let driver = try Self.makeDriver(suffix: "block") { id in
            recorder.calls.append(id)
        }
        // Park the spy for a known interval, then poke the internal
        // tick via the debug surface. The resolver MUST NOT run while
        // the suppression window is open.
        driver.suppress(for: .milliseconds(200))
        driver.debugTick(mode: .split)
        #expect(recorder.calls.isEmpty)
    }

    @Test("Tick resumes resolving once the suppress deadline has elapsed") @MainActor
    func tickResumesResolvingOnceTheSuppressDeadlineHasElapsed() throws {
        @MainActor final class Recorder { var calls: [String?] = [] }
        let recorder = Recorder()
        let driver = try Self.makeDriver(suffix: "release") { id in
            recorder.calls.append(id)
        }
        driver.suppress(for: .milliseconds(20))
        // Sleep just past the suppress window. 50 ms is well within
        // the test runner's tolerance and well past the 20 ms deadline.
        Thread.sleep(forTimeInterval: 0.06)
        driver.debugTick(mode: .split)
        // With editor/preview scrollTop=0 and the test positions, the
        // resolver picks "a" (its y=0 is at-or-below anchor 0+80).
        #expect(recorder.calls == ["a"])
    }

    @Test("Re-suppressing only extends the window forward, never shortens it") @MainActor
    func reSuppressingOnlyExtendsTheWindowForwardNeverShortensIt() throws {
        @MainActor final class Recorder { var calls: [String?] = [] }
        let recorder = Recorder()
        let driver = try Self.makeDriver(suffix: "extend") { id in
            recorder.calls.append(id)
        }
        // Open a long suppress, then try to shorten it — the longer
        // deadline wins. The tick following the shorter call still
        // gets blocked.
        driver.suppress(for: .milliseconds(500))
        driver.suppress(for: .milliseconds(10))
        Thread.sleep(forTimeInterval: 0.05) // past the 10 ms but well inside the 500 ms
        driver.debugTick(mode: .split)
        #expect(recorder.calls.isEmpty)
    }
}
#endif
