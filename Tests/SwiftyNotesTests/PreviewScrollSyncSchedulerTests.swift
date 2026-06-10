import Foundation
@testable import SwiftyNotes
import Testing

@MainActor
struct PreviewScrollSyncSchedulerTests {
    @Test("Request sync coalesces multiple pending requests into one callback")
    func requestSyncCoalescesMultiplePendingRequestsIntoOneCallback() {
        let scheduler = TestMainActorScheduler()
        var syncCount = 0
        let subject = PreviewScrollSyncScheduler(
            schedule: scheduler.schedule,
            sync: { syncCount += 1 },
        )

        subject.requestSync()
        subject.requestSync()
        subject.requestSync()

        #expect(syncCount == 0)

        scheduler.runPendingActions()

        #expect(syncCount == 1)
    }

    @Test("Request sync schedules again after previous callback drains")
    func requestSyncSchedulesAgainAfterPreviousCallbackDrains() {
        let scheduler = TestMainActorScheduler()
        var syncCount = 0
        let subject = PreviewScrollSyncScheduler(
            schedule: scheduler.schedule,
            sync: { syncCount += 1 },
        )

        subject.requestSync()
        scheduler.runPendingActions()
        subject.requestSync()
        scheduler.runPendingActions()

        #expect(syncCount == 2)
    }

    @Test("Cancel drops pending callback but allows future requests")
    func cancelDropsPendingCallbackButAllowsFutureRequests() {
        let scheduler = TestMainActorScheduler()
        var syncCount = 0
        let subject = PreviewScrollSyncScheduler(
            schedule: scheduler.schedule,
            sync: { syncCount += 1 },
        )

        subject.requestSync()
        subject.cancel()
        scheduler.runPendingActions()

        #expect(syncCount == 0)

        subject.requestSync()
        scheduler.runPendingActions()

        #expect(syncCount == 1)
    }
}
