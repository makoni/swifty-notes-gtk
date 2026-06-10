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

    @Test("Flush after schedule renders the latest buffered blocks and base directory")
    func flushAfterScheduleRendersTheLatestBufferedBlocksAndBaseDirectory() {
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

    @Test("Schedule overwrites previous pending blocks")
    func scheduleOverwritesPreviousPendingBlocks() {
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

    @Test("Cancel drops buffered work and prevents render on flush")
    func cancelDropsBufferedWorkAndPreventsRenderOnFlush() {
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

    @Test("Flush parks render when preview surface is not ready and replays after surface becomes ready")
    func flushParksRenderWhenPreviewSurfaceIsNotReadyAndReplaysAfter() {
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

    @Test("Flush without prior schedule is a no-op and never calls render")
    func flushWithoutPriorScheduleIsANoOpAndNeverCallsRender() {
        let recorder = RenderRecorder()
        let scheduler = PreviewRefreshScheduler(
            render: recorder.record,
            fallbackBaseDirectory: { URL(fileURLWithPath: "/tmp/fallback") },
            shouldDeferRender: { false },
        )

        scheduler.flush()

        #expect(recorder.calls.isEmpty)
    }

    @Test("Deferred schedule only resolves markdown once when latest typing burst is flushed")
    func deferredScheduleOnlyResolvesMarkdownOnceWhenLatestTypingBurstIsFlushed() {
        let recorder = RenderRecorder()
        let baseDirectory = URL(fileURLWithPath: "/tmp/notes")
        var resolveCount = 0
        let scheduler = PreviewRefreshScheduler(
            render: recorder.record,
            fallbackBaseDirectory: { URL(fileURLWithPath: "/tmp/fallback") },
            shouldDeferRender: { false },
        )

        scheduler.scheduleDeferred(baseDirectory: baseDirectory) {
            resolveCount += 1
            return [.paragraph(.plain("latest"))]
        }

        #expect(resolveCount == 0)

        scheduler.flush()

        #expect(resolveCount == 1)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.blocks == [.paragraph(.plain("latest"))])
    }

    @Test("Latest deferred schedule overwrites earlier typing work before any markdown is resolved")
    func latestDeferredScheduleOverwritesEarlierTypingWorkBeforeAnyMarkdownIsResolved() {
        let recorder = RenderRecorder()
        let scheduler = PreviewRefreshScheduler(
            render: recorder.record,
            fallbackBaseDirectory: { URL(fileURLWithPath: "/tmp/fallback") },
            shouldDeferRender: { false },
        )
        var firstResolveCount = 0
        var secondResolveCount = 0

        scheduler.scheduleDeferred(baseDirectory: URL(fileURLWithPath: "/tmp/first")) {
            firstResolveCount += 1
            return [.paragraph(.plain("first"))]
        }
        scheduler.scheduleDeferred(baseDirectory: URL(fileURLWithPath: "/tmp/second")) {
            secondResolveCount += 1
            return [.paragraph(.plain("second"))]
        }

        scheduler.flush()

        #expect(firstResolveCount == 0)
        #expect(secondResolveCount == 1)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.baseDirectory == URL(fileURLWithPath: "/tmp/second"))
        #expect(recorder.calls.first?.blocks == [.paragraph(.plain("second"))])
    }
}
