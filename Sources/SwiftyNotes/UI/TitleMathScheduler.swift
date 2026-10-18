import Adwaita
import Foundation
import MathEngine

/// Paces formula parsing for labels outside the preview — note titles and
/// headings in the sidebar, outline, breadcrumb and command palette. Titles
/// are untrusted like any note text and a sidebar or outline shows many at
/// once, so they share one ``ParseBudgetPeriod``; formulas past it show
/// their source until the catch-up pass, one budget a period, lays them out.
@MainActor
final class TitleMathScheduler {
    private var period: ParseBudgetPeriod
    private let layOut: (Label, MathLabelState) -> Void
    /// Labels with formulas the budget postponed, in the order they came.
    private var postponed: [PostponedLabel] = []
    private var catchUpPass: SourceID?

    /// - Parameter layOut: lays a label's postponed formulas out (within
    ///   the budget the scheduler has opened).
    init(
        budget: Duration = .milliseconds(50),
        period: Duration = .milliseconds(100),
        layOut: @escaping (Label, MathLabelState) -> Void
    ) {
        self.period = ParseBudgetPeriod(budget: budget, period: period)
        self.layOut = layOut
    }

    /// What the labels may spend parsing per period (tests lower it).
    var budget: Duration {
        get { period.budget }
        set { period.budget = newValue }
    }

    /// Runs `body` within what is left of the shared budget.
    func withBudget(fromCatchUpPass: Bool = false, _ body: () -> Void) {
        run(grant: begin(fromCatchUpPass: fromCatchUpPass), body)
    }

    private func begin(fromCatchUpPass: Bool) -> ParseBudgetPeriod.Grant {
        let grant = period.begin(at: .now, fromCatchUpPass: fromCatchUpPass)
        if grant.opensPass {
            MainContext.idle { [weak self] in
                self?.period.passEnded()
            }
        }
        return grant
    }

    private func run(grant: ParseBudgetPeriod.Grant, _ body: () -> Void) {
        let parsed = MathRenderer.parsingWithinBudget(grant.remaining, guaranteeingProgress: grant.forcesProgress, body)
        period.end(at: .now, parsed: parsed)
    }

    /// Lays the formulas `label` postponed out over the next passes.
    func layOutPostponedSoon(_ label: Label, state: MathLabelState) {
        guard state.hasPostponedFormulas else { return }
        if !state.isQueuedOutside {
            state.isQueuedOutside = true
            postponed.append(PostponedLabel(state: state, widget: UnsafeMutableRawPointer(label.widgetPointer)))
        }
        guard catchUpPass == nil else { return }
        catchUpPass = MainContext.timeout(every: .milliseconds(16)) { [weak self] in
            guard let self else { return false }
            catchUp()
            guard postponed.isEmpty else { return true }
            catchUpPass = nil
            return false
        }
    }

    /// One catch-up pass: lays labels out in the order they came until the
    /// budget runs out. With nothing to spend it leaves the queue alone,
    /// so a long queue costs nothing between periods.
    private func catchUp() {
        let grant = begin(fromCatchUpPass: true)
        guard grant.canParse else { return }
        run(grant: grant) {
            var kept: [PostponedLabel] = []
            var isOutOfBudget = false
            for entry in postponed {
                guard !isOutOfBudget else {
                    kept.append(entry)
                    continue
                }
                // A label that is gone took its state with it.
                guard let state = entry.state else { continue }
                guard let label = Widget(borrowing: entry.widget).tryCast(Label.self) else {
                    state.isQueuedOutside = false
                    continue
                }
                if state.hasPostponedFormulas {
                    layOut(label, state)
                }
                if state.hasPostponedFormulas {
                    // Still waiting: the budget ran out, the rest wait too.
                    kept.append(entry)
                    isOutOfBudget = true
                } else {
                    state.isQueuedOutside = false
                }
            }
            postponed = kept
        }
    }
}

private struct PostponedLabel {
    /// Held by the label (its GObject data) alone, so it is gone once the
    /// label is; `widget` is valid while it lives.
    weak var state: MathLabelState?
    let widget: UnsafeMutableRawPointer
}
