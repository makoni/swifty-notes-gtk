import Adwaita
import Foundation

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
    init(budget: Duration = .milliseconds(50), period: Duration = .milliseconds(100), layOut: @escaping (Label, MathLabelState) -> Void) {
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
        let grant = period.begin(at: .now, fromCatchUpPass: fromCatchUpPass)
        if grant.opensPass {
            MainContext.idle { [weak self] in
                self?.period.passEnded()
            }
        }
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
            withBudget(fromCatchUpPass: true) {
                self.postponed.removeAll { entry in
                    // A label that is gone took its state with it.
                    guard let state = entry.state else { return true }
                    guard let label = Widget(borrowing: entry.widget).tryCast(Label.self) else {
                        state.isQueuedOutside = false
                        return true
                    }
                    if state.hasPostponedFormulas {
                        self.layOut(label, state)
                    }
                    state.isQueuedOutside = state.hasPostponedFormulas
                    return !state.hasPostponedFormulas
                }
            }
            guard postponed.isEmpty else { return true }
            catchUpPass = nil
            return false
        }
    }
}

private struct PostponedLabel {
    /// Held by the label (its GObject data) alone, so it is gone once the
    /// label is; `widget` is valid while it lives.
    weak var state: MathLabelState?
    let widget: UnsafeMutableRawPointer
}
