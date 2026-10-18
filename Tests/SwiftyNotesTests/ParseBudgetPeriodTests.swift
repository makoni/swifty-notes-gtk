import Foundation
@testable import SwiftyNotes
import Testing

struct ParseBudgetPeriodTests {
    private let t0 = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        t0 + .milliseconds(milliseconds)
    }

    @Test("A period gives its budget, then nothing until it is over")
    func aPeriodGivesItsBudgetThenNothing() {
        var period = ParseBudgetPeriod(budget: .milliseconds(50), period: .milliseconds(100))
        let first = period.begin(at: at(0), fromCatchUpPass: false)
        #expect(first.remaining == .milliseconds(50))
        #expect(first.opensPass)
        period.end(at: at(30), parsed: true)
        #expect(period.begin(at: at(30), fromCatchUpPass: false).remaining == .milliseconds(20))
        #expect(period.begin(at: at(70), fromCatchUpPass: false).remaining == .zero)
    }

    @Test("A period renews only once the pass that opened it has ended, or for the catch-up")
    func aPeriodRenewsOnlyInALaterPass() {
        var period = ParseBudgetPeriod(budget: .milliseconds(50), period: .milliseconds(100))
        _ = period.begin(at: at(0), fromCatchUpPass: false)
        // Still the same pass, long after: nothing new.
        #expect(period.begin(at: at(150), fromCatchUpPass: false).remaining == .zero)
        // The catch-up pass runs in its own pass.
        #expect(period.begin(at: at(150), fromCatchUpPass: true).remaining == .milliseconds(50))
        period.passEnded()
        let later = period.begin(at: at(260), fromCatchUpPass: false)
        #expect(later.remaining == .milliseconds(50))
        #expect(later.opensPass)
    }

    @Test("The catch-up forces one parse a period, not more")
    func theCatchUpForcesOneParseAPeriod() {
        var period = ParseBudgetPeriod(budget: .zero, period: .milliseconds(100))
        #expect(period.begin(at: at(0), fromCatchUpPass: true).forcesProgress)
        period.end(at: at(5), parsed: true)
        #expect(!period.begin(at: at(20), fromCatchUpPass: true).forcesProgress)
        #expect(period.begin(at: at(110), fromCatchUpPass: true).forcesProgress)
        // Never outside the catch-up.
        var fresh = ParseBudgetPeriod(budget: .zero, period: .milliseconds(100))
        #expect(!fresh.begin(at: at(0), fromCatchUpPass: false).forcesProgress)
    }

    @Test("A parse that overruns the budget leaves the UI its share before the next period")
    func aParseThatOverrunsLeavesTheUIItsShare() {
        var period = ParseBudgetPeriod(budget: .milliseconds(50), period: .milliseconds(100))
        _ = period.begin(at: at(0), fromCatchUpPass: true)
        // One parse took 120 ms.
        period.end(at: at(120), parsed: true)
        // The period now counts from 70 ms: nothing until 170 ms.
        #expect(period.begin(at: at(130), fromCatchUpPass: true).remaining == .zero)
        #expect(!period.begin(at: at(160), fromCatchUpPass: true).forcesProgress)
        #expect(period.begin(at: at(171), fromCatchUpPass: true).forcesProgress)
    }

    @Test("Calls that parse nothing do not hold the period back")
    func callsThatParseNothingDoNotHoldThePeriodBack() {
        var period = ParseBudgetPeriod(budget: .milliseconds(50), period: .milliseconds(100))
        _ = period.begin(at: at(0), fromCatchUpPass: true)
        period.end(at: at(10), parsed: true)
        for tick in stride(from: 16, through: 96, by: 16) {
            _ = period.begin(at: at(tick), fromCatchUpPass: true)
            period.end(at: at(tick), parsed: false)
        }
        #expect(period.begin(at: at(112), fromCatchUpPass: true).remaining == .milliseconds(50))
    }

    @Test("The preview's catch-up waits as long again after a pass that overran")
    func thePreviewsCatchUpWaitsAfterAnOverrun() {
        let budget = Duration.milliseconds(16)
        #expect(nextFrameCatchUp(after: at(0), spent: .milliseconds(10), budget: budget) == at(0))
        #expect(nextFrameCatchUp(after: at(0), spent: .milliseconds(100), budget: budget) == at(200))
    }
}
