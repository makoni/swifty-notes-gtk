import Adwaita
import Foundation

/// Formulas in a note's title or a heading shown outside the preview — the
/// sidebar, outline, breadcrumb and command palette. They are drawn by the
/// preview's label machinery (``PreviewMath``), sized like the label's
/// text, read as plain text by screen readers, and parsed at the pace
/// ``TitleMathScheduler`` allows.
@MainActor
enum TitleMath {
    /// Shows `text` in `label`, drawing its formulas, with the first match
    /// of `query` highlighted.
    static func show(_ text: String, in label: Label, highlighting query: String = "") {
        PreviewMath.show(text, in: label, highlighting: query)
    }

    /// Shows `markup`, whose formula markers stand for `spans`, in `label`;
    /// `accessibleText`, if given, is what screen readers hear instead of
    /// the label's text read out.
    static func show(markup: String, spans: [MathSpan], in label: Label, accessibleText: String? = nil) {
        PreviewMath.show(markup: markup, spans: spans, in: label, accessibleText: accessibleText)
    }
}
