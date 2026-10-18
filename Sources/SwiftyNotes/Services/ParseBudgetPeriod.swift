import Foundation

/// The time formula parsing may take, out of each period, for labels that
/// share one budget (titles and headings outside the preview): the rest of
/// the period is the UI's.
///
/// - A period renews only once it is over and the main-loop pass that
///   opened it has ended — or for the catch-up pass — so one long rebuild
///   does not refill it as it goes.
/// - The catch-up pass parses one formula a period even with nothing left,
///   so postponed formulas always come.
/// - A parse that runs past the budget is charged to the period: the next
///   one starts no sooner than the UI's share after it, whatever the
///   formula cost.
///
/// Pure arithmetic over the instants it is given.
struct ParseBudgetPeriod {
    var budget: Duration
    let period: Duration
    private(set) var start: ContinuousClock.Instant?
    private(set) var hasParsed = false
    /// Whether the main-loop pass that opened the period has ended.
    private(set) var isPassOver = true

    init(budget: Duration, period: Duration) {
        self.budget = budget
        self.period = period
    }

    /// What a call at `now` may spend; `opensPass` is true when this opened
    /// a period in a new main-loop pass (the caller notes when it ends).
    mutating func begin(at now: ContinuousClock.Instant, fromCatchUpPass: Bool) -> (remaining: Duration, forcesProgress: Bool, opensPass: Bool) {
        let elapsed = start.map { now - $0 } ?? period
        var opensPass = false
        if elapsed >= period, isPassOver || fromCatchUpPass {
            start = now
            hasParsed = false
            if isPassOver {
                isPassOver = false
                opensPass = true
            }
        }
        let remaining = max((start ?? now) + budget - now, .zero)
        return (remaining, fromCatchUpPass && !hasParsed, opensPass)
    }

    /// A call that began earlier ended at `now`, having parsed or not.
    mutating func end(at now: ContinuousClock.Instant, parsed: Bool) {
        guard parsed else { return }
        hasParsed = true
        if let start {
            self.start = max(start, now - budget)
        }
    }

    /// The main-loop pass that opened the period has ended.
    mutating func passEnded() {
        isPassOver = true
    }
}

/// When a frame-by-frame catch-up (the preview's) may run again after a
/// pass that began at `started` and took `spent`: at once if it kept to
/// `budget`, otherwise after as long again, so the UI gets half the time
/// however long one formula takes.
func nextFrameCatchUp(after started: ContinuousClock.Instant, spent: Duration, budget: Duration) -> ContinuousClock.Instant {
    spent > budget ? started + spent * 2 : started
}
