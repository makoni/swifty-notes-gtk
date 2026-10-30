import Foundation

/// How long formula parsing may hold the main loop, everywhere it happens.
/// Formulas a budget leaves unparsed show their source until a later pass.
enum MathParseBudgets {
    /// A full render of the preview.
    static let render: Duration = .milliseconds(400)
    /// A zoom step, laying the preview's formulas out again at once.
    static let zoomStep: Duration = .milliseconds(100)
    /// Each frame of a pass after the render — postponed formulas, a font
    /// refresh; a postponed pass always finishes at least one formula.
    static let followUpFrame: Duration = .milliseconds(16)
    /// What the row binds of one frame of the virtualized preview share.
    static let rowBindsPerFrame: Duration = .milliseconds(50)
    /// Titles and headings outside the preview, shared per period
    /// (``ParseBudgetPeriod``).
    static let titles: Duration = .milliseconds(50)
    static let titlePeriod: Duration = .milliseconds(100)
}

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

    /// What one call may spend.
    struct Grant {
        let remaining: Duration
        /// Parse one formula even with nothing left.
        let forcesProgress: Bool
        /// This call opened a period in a new main-loop pass (the caller
        /// notes when the pass ends).
        let opensPass: Bool

        /// Whether the call can parse anything at all.
        var canParse: Bool {
            remaining > .zero || forcesProgress
        }
    }

    /// What a call at `now` may spend.
    mutating func begin(at now: ContinuousClock.Instant, fromCatchUpPass: Bool) -> Grant {
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
        return Grant(remaining: remaining, forcesProgress: fromCatchUpPass && !hasParsed, opensPass: opensPass)
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

/// Pacing for a frame-by-frame catch-up (the preview's), which has a
/// budget per frame rather than a shared period.
enum FrameCatchUp {
    /// When it may run again after a pass that began at `started` and took
    /// `spent`: at once if it kept to `budget`, otherwise after as long
    /// again, so the UI gets half the time however long one formula takes.
    static func next(
        after started: ContinuousClock.Instant,
        spent: Duration,
        budget: Duration
    ) -> ContinuousClock.Instant {
        spent > budget ? started + spent * 2 : started
    }
}
