import Foundation
@testable import SwiftyNotes
import Testing

struct RecentJumpsTests {
    @Test("Starts empty")
    func startsEmpty() {
        let jumps = RecentJumps()
        #expect(jumps.ids == [])
    }

    @Test("Record prepends new ids in newest-first order")
    func recordPrependsNewIdsInNewestFirstOrder() {
        var jumps = RecentJumps()
        jumps.record("a")
        jumps.record("b")
        jumps.record("c")
        #expect(jumps.ids == ["c", "b", "a"])
    }

    @Test("Recording an existing id moves it to the front without duplicating")
    func recordingAnExistingIdMovesItToTheFrontWithoutDuplicating() {
        var jumps = RecentJumps()
        jumps.record("a")
        jumps.record("b")
        jumps.record("c")
        jumps.record("a") // re-record
        #expect(jumps.ids == ["a", "c", "b"])
    }

    @Test("Recently-jumped list is capped at five entries")
    func recentlyJumpedListIsCappedAtFiveEntries() {
        var jumps = RecentJumps()
        for id in ["a", "b", "c", "d", "e", "f", "g"] {
            jumps.record(id)
        }
        // Newest five, oldest two dropped.
        #expect(jumps.ids == ["g", "f", "e", "d", "c"])
    }

    @Test("Cap honors moves so the cap doesn't push the moved entry off")
    func capHonorsMovesSoTheCapDoesntPushTheMovedEntryOff() {
        var jumps = RecentJumps(ids: ["a", "b", "c", "d", "e"])
        // Re-record "e" — should stay at the front, list unchanged length.
        jumps.record("e")
        #expect(jumps.ids == ["e", "a", "b", "c", "d"])
    }

    @Test("Seed initializer truncates to the cap")
    func seedInitializerTruncatesToTheCap() {
        let jumps = RecentJumps(ids: ["a", "b", "c", "d", "e", "f", "g"])
        #expect(jumps.ids == ["a", "b", "c", "d", "e"])
    }

    @Test("Seed initializer dedupes preserving first occurrence")
    func seedInitializerDedupesPreservingFirstOccurrence() {
        let jumps = RecentJumps(ids: ["a", "b", "a", "c", "b"])
        #expect(jumps.ids == ["a", "b", "c"])
    }
}
