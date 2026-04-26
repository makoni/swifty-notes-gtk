import Foundation
@testable import SwiftyNotes
import Testing

@MainActor
struct PreviewRefreshSchedulerTests {
    private final class RenderRecorder {
        var calls: [(blocks: [RenderedBlock], baseDirectory: URL)] = []

        func record(_ blocks: [RenderedBlock], _ baseDirectory: URL) {
            calls.append((blocks, baseDirectory))
        }
    }

    private static func sampleBlocks() -> [RenderedBlock] {
        [.paragraph(.plain("hello"))]
    }

    @Test
    func `flush after schedule renders the latest buffered blocks and base directory`() {
        let recorder = RenderRecorder()
        let baseDirectory = URL(fileURLWithPath: "/tmp/notes")
        let scheduler = PreviewRefreshScheduler(
            render: recorder.record,
            fallbackBaseDirectory: { URL(fileURLWithPath: "/tmp/fallback") },
            shouldDeferRender: { false },
        )

        scheduler.schedule(blocks: Self.sampleBlocks(), baseDirectory: baseDirectory)
        scheduler.flush()

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.baseDirectory == baseDirectory)
    }

    @Test
    func `schedule overwrites previous pending blocks`() {
        let recorder = RenderRecorder()
        let firstDir = URL(fileURLWithPath: "/tmp/first")
        let secondDir = URL(fileURLWithPath: "/tmp/second")
        let scheduler = PreviewRefreshScheduler(
            render: recorder.record,
            fallbackBaseDirectory: { URL(fileURLWithPath: "/tmp/fallback") },
            shouldDeferRender: { false },
        )

        scheduler.schedule(blocks: Self.sampleBlocks(), baseDirectory: firstDir)
        scheduler.schedule(blocks: [.paragraph(.plain("second"))], baseDirectory: secondDir)
        scheduler.flush()

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.baseDirectory == secondDir)
    }

    @Test
    func `cancel drops buffered work and prevents render on flush`() {
        let recorder = RenderRecorder()
        let scheduler = PreviewRefreshScheduler(
            render: recorder.record,
            fallbackBaseDirectory: { URL(fileURLWithPath: "/tmp/fallback") },
            shouldDeferRender: { false },
        )

        scheduler.schedule(blocks: Self.sampleBlocks(), baseDirectory: URL(fileURLWithPath: "/tmp/notes"))
        scheduler.cancel()
        scheduler.flush()

        #expect(recorder.calls.isEmpty)
    }

    @Test
    func `flush parks render when preview surface is not ready and replays after surface becomes ready`() {
        let recorder = RenderRecorder()
        var deferring = true
        let baseDirectory = URL(fileURLWithPath: "/tmp/notes")
        let scheduler = PreviewRefreshScheduler(
            render: recorder.record,
            fallbackBaseDirectory: { URL(fileURLWithPath: "/tmp/fallback") },
            shouldDeferRender: { deferring },
        )

        scheduler.schedule(blocks: Self.sampleBlocks(), baseDirectory: baseDirectory)
        scheduler.flush()
        #expect(recorder.calls.isEmpty)

        deferring = false
        scheduler.flush()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.baseDirectory == baseDirectory)
    }

    @Test
    func `flush without prior schedule is a no-op and never calls render`() {
        let recorder = RenderRecorder()
        let scheduler = PreviewRefreshScheduler(
            render: recorder.record,
            fallbackBaseDirectory: { URL(fileURLWithPath: "/tmp/fallback") },
            shouldDeferRender: { false },
        )

        scheduler.flush()

        #expect(recorder.calls.isEmpty)
    }
}
