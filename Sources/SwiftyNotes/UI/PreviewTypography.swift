import Adwaita
import Foundation

/// Live typography for the rendered markdown preview: one zoom multiplier
/// over the whole preview and one line-spacing multiplier for prose.
///
/// Both are global app preferences. They are applied with a
/// static-stylesheet-plus-CSS-class design: ``stylesheet()`` defines one
/// rule per allowed step (every zoom step, every line-spacing step) and is
/// installed on a single process-wide ``CSSProvider`` exactly once, like
/// the static preview CSS. Each preview selects its active step with a
/// `preview-zoom-*` / `preview-spacing-*` CSS class on its root (see
/// ``cssClasses(zoomPercent:lineSpacingPercent:)``); swapping the classes
/// invalidates the preview's whole CSS subtree, so GTK re-resolves every
/// already-rendered label, code view and table on the next frame — the
/// standard restyle mechanism, with no provider reload and no markdown
/// re-render.
///
/// The pure ``css(zoomPercent:lineSpacingPercent:)``,
/// ``cssClasses(zoomPercent:lineSpacingPercent:)``, ``stylesheet()`` and
/// ``zoomAfterScroll(current:deltaY:modifiers:)`` are unit-testable
/// without any GTK objects.
@MainActor
public enum PreviewTypography {
    /// CSS class placed on each preview's root scrolled window so the
    /// generated rules target exactly the rendered previews and nothing
    /// else in the window.
    nonisolated public static let rootCSSClass = "markdown-preview"

    nonisolated public static let minZoomPercent = 50
    nonisolated public static let maxZoomPercent = 200
    nonisolated public static let zoomStepPercent = 10
    nonisolated public static let minLineSpacingPercent = 80
    nonisolated public static let maxLineSpacingPercent = 200
    nonisolated public static let lineSpacingStepPercent = 10

    /// Base line heights in hundredths — the values the preview shipped with
    /// before line spacing became a preference. 100 % must reproduce them
    /// exactly, which is what keeps the default look unchanged.
    nonisolated private static let paragraphLineHeightHundredths = 124
    nonisolated private static let compactListLineHeightHundredths = 114

    /// The flat-list label (an ordinary non-task list rendered as one label)
    /// had no line-height rule before, i.e. the natural height; a Pango
    /// line-height factor of 1.00 is the same, so 100 % keeps the default
    /// look.
    nonisolated private static let flatListLineHeightHundredths = 100

    /// The table body label (a table rendered as one monospaced label) had
    /// no line-height rule before, i.e. the natural height; a Pango
    /// line-height factor of 1.00 is the same, so 100 % keeps the default
    /// look.
    nonisolated private static let tableLineHeightHundredths = 100

    /// The single process-wide provider carrying the complete static
    /// typography stylesheet. Created on first access and kept on the
    /// default display at the APPLICATION priority the static preview CSS
    /// uses, so every window in this process — main window and
    /// external-document windows — sees the same steps.
    private static let globalStylesheet = CSSProvider.loadGlobal(stylesheet())

    /// Installs the static typography stylesheet. Idempotent and safe to
    /// call from every preview; the provider is created once per process
    /// and its CSS is loaded before it is added to the display.
    public static func installGlobalStylesheet() {
        _ = globalStylesheet
    }

    /// The complete static typography stylesheet: one rule block per
    /// allowed zoom step and one per allowed line-spacing step, each
    /// selected by its own CSS class on the preview root. This is what
    /// ``installGlobalStylesheet()`` installs, and it never changes at
    /// runtime — changing the preference only swaps the root's classes.
    ///
    /// `nonisolated`: pure string building, unit-tested without a GTK
    /// context; only ``installGlobalStylesheet()`` touches the display.
    nonisolated public static func stylesheet() -> String {
        var lines: [String] = []
        for zoomPercent in zoomSteps {
            lines += fontRules(
                rootSelector: ".\(rootCSSClass).\(zoomClass(for: zoomPercent))",
                zoomPercent: zoomPercent,
            )
        }
        for lineSpacingPercent in lineSpacingSteps {
            lines += lineSpacingRules(
                rootSelector: ".\(rootCSSClass).\(lineSpacingClass(for: lineSpacingPercent))",
                lineSpacingPercent: lineSpacingPercent,
            )
        }
        return lines.joined(separator: "\n")
    }

    /// The complete generated stylesheet for the given preferences.
    ///
    /// The zoom is a percentage font-size on the preview root, so every
    /// child label, heading, code view and table inherits it (and Pango's
    /// relative `size="large"` spans keep their ratios). Off 100 % the
    /// stylesheet additionally pins `.title-1`/`2`/`3` to the theme's own
    /// point sizes scaled by the zoom, because libadwaita 1.5 defines those
    /// classes in absolute points and would otherwise leave the headings
    /// standing still while the body scales. The line spacing scales the
    /// prose line-heights from their base values. All numbers are
    /// integer-formatted with a hardcoded `.`, so the output is identical
    /// in every locale and parseable by the C CSS parser.
    ///
    /// `nonisolated`: pure string building, unit-tested without a GTK
    /// context; only ``installGlobalStylesheet()`` touches the display.
    nonisolated public static func css(zoomPercent: Int, lineSpacingPercent: Int) -> String {
        let rootSelector = ".\(rootCSSClass)"
        return (
            fontRules(rootSelector: rootSelector, zoomPercent: zoomPercent)
                + lineSpacingRules(rootSelector: rootSelector, lineSpacingPercent: lineSpacingPercent)
        ).joined(separator: "\n")
    }

    /// The CSS class pair a preview root carries for the given
    /// preferences, selecting the matching step of the static stylesheet.
    ///
    /// Both values are clamped to their range and snapped to the nearest
    /// step, so ANY persisted value maps to a class ``stylesheet()``
    /// defines — a stale or hand-edited setting can never select a
    /// missing step.
    nonisolated public static func cssClasses(
        zoomPercent: Int,
        lineSpacingPercent: Int,
    ) -> (zoom: String, spacing: String) {
        (
            zoom: zoomClass(for: snappedZoomPercent(zoomPercent)),
            spacing: lineSpacingClass(for: snappedLineSpacingPercent(lineSpacingPercent)),
        )
    }

    nonisolated static func snappedZoomPercent(_ percent: Int) -> Int {
        snap(percent, in: minZoomPercent...maxZoomPercent, step: zoomStepPercent)
    }

    nonisolated static func snappedLineSpacingPercent(_ percent: Int) -> Int {
        snap(percent, in: minLineSpacingPercent...maxLineSpacingPercent, step: lineSpacingStepPercent)
    }

    /// Clamps `percent` into `range`, then rounds it to the nearest step
    /// (a halfway value rounds up), so the result always names a step the
    /// static stylesheet carries.
    nonisolated static func snap(_ percent: Int, in range: ClosedRange<Int>, step: Int) -> Int {
        let clamped = min(max(percent, range.lowerBound), range.upperBound)
        let steps = (clamped - range.lowerBound + step / 2) / step
        return range.lowerBound + steps * step
    }

    nonisolated static func zoomClass(for zoomPercent: Int) -> String {
        "preview-zoom-\(zoomPercent)"
    }

    nonisolated static func lineSpacingClass(for lineSpacingPercent: Int) -> String {
        "preview-spacing-\(lineSpacingPercent)"
    }

    nonisolated private static var zoomSteps: [Int] {
        stride(from: minZoomPercent, through: maxZoomPercent, by: zoomStepPercent).map { $0 }
    }

    nonisolated private static var lineSpacingSteps: [Int] {
        stride(from: minLineSpacingPercent, through: maxLineSpacingPercent, by: lineSpacingStepPercent).map { $0 }
    }

    /// The zoom rules for one step: the root `font-size`, plus the pinned
    /// `.title-1`/`-2`/`-3` point sizes off 100 %, plus the re-opened
    /// `.monospace` font size off 100 %.
    ///
    /// Standalone headings carry libadwaita's `.title-1`/`2`/`3` classes,
    /// which libadwaita 1.5 defines in absolute points (20/15/15) and 1.9
    /// in relative sizes — so the 1.5 headings would not move with the
    /// body. These application-priority rules (above the theme) re-assert
    /// the theme's own 100 % point sizes, scaled by the zoom, so the
    /// headings scale with the body at any zoom.
    ///
    /// Code blocks (and the monospace badge labels) carry libadwaita's
    /// `.monospace` class — `gtk_text_view_set_monospace` puts it on the
    /// SourceView — and recent themes pin an absolute
    /// `.monospace { font-size: … }` that would hold the code at the theme
    /// size while the body zooms. Off 100 % the step therefore re-opens
    /// the node to `inherit`, i.e. the parent's already-scaled size, so
    /// the code views zoom with the body; on themes without the pin the
    /// rule is a no-op. At exactly 100 % nothing is emitted and the
    /// default look is whatever the theme defines in every environment.
    nonisolated private static func fontRules(rootSelector: String, zoomPercent: Int) -> [String] {
        var lines: [String] = [
            "\(rootSelector) {",
            "    font-size: \(zoomPercent)%;",
            "}",
        ]
        if zoomPercent != 100 {
            lines += [
                "",
                "\(rootSelector) .monospace {",
                "    font-size: inherit;",
                "}",
                "",
                "\(rootSelector) .title-1 {",
                "    font-size: \(scaledTitleSize(basePoints: 20, zoomPercent: zoomPercent));",
                "}",
                "",
                "\(rootSelector) .title-2 {",
                "    font-size: \(scaledTitleSize(basePoints: 15, zoomPercent: zoomPercent));",
                "}",
                "",
                "\(rootSelector) .title-3 {",
                "    font-size: \(scaledTitleSize(basePoints: 15, zoomPercent: zoomPercent));",
                "}",
            ]
        }
        return lines
    }

    /// The line-spacing rules for one step, scaling the prose line-heights
    /// from their base values (paragraph/blockquote, the compact and task
    /// list labels/markers that read as prose, the flat-list label that
    /// carries an ordinary non-task list, and the table body label). Code
    /// blocks stay excluded: no rule here targets the source views, so
    /// code keeps its own spacing at every step.
    nonisolated private static func lineSpacingRules(rootSelector: String, lineSpacingPercent: Int) -> [String] {
        let paragraph = scaledLineHeight(
            baseHundredths: paragraphLineHeightHundredths,
            percent: lineSpacingPercent,
        )
        let compactList = scaledLineHeight(
            baseHundredths: compactListLineHeightHundredths,
            percent: lineSpacingPercent,
        )
        let flatList = scaledLineHeight(
            baseHundredths: flatListLineHeightHundredths,
            percent: lineSpacingPercent,
        )
        let table = scaledLineHeight(
            baseHundredths: tableLineHeightHundredths,
            percent: lineSpacingPercent,
        )
        return [
            "",
            "\(rootSelector) .preview-paragraph-label,",
            "\(rootSelector) .preview-blockquote-label {",
            "    line-height: \(paragraph);",
            "}",
            "",
            "\(rootSelector) .preview-compact-list-label,",
            "\(rootSelector) .preview-compact-list-marker {",
            "    line-height: \(compactList);",
            "}",
            "",
            "\(rootSelector) .preview-task-list-label,",
            "\(rootSelector) .preview-task-list-marker {",
            "    line-height: \(compactList);",
            "}",
            "",
            "\(rootSelector) .preview-flat-list-label {",
            "    line-height: \(flatList);",
            "}",
            "",
            "\(rootSelector) .preview-table-body {",
            "    line-height: \(table);",
            "}",
        ]
    }

    /// Formats `basePoints` scaled by `zoomPercent` as a CSS point size,
    /// using integer tenths so the decimal point never follows the process
    /// locale: 20 pt at 150 % is `30.0pt`, 15 pt at 150 % is `22.5pt`.
    nonisolated static func scaledTitleSize(basePoints: Int, zoomPercent: Int) -> String {
        let tenths = basePoints * 10 * zoomPercent / 100
        return "\(tenths / 10).\(tenths % 10)pt"
    }

    /// Decides whether a scroll event over the preview is a zoom gesture
    /// and, if so, what the new zoom is.
    ///
    /// The gesture is Ctrl (plus Meta on macOS, where the app treats Meta
    /// as the primary modifier) as the *only* non-lock modifier held:
    /// Caps Lock and the X11 NumLock slot are state, not intent, and are
    /// masked like ``MarkdownEditor.handleReturnKey`` does. Any other
    /// modifier (Shift, Alt, a mouse button) means the user is not zooming,
    /// so nil is returned and the event scrolls as usual. A zero delta is
    /// never a gesture. At the 50/200 limits the clamped value is still
    /// returned so the notch is consumed instead of scrolling the view a
    /// step for no change.
    ///
    /// - Parameters:
    ///   - current: the zoom percent in effect before this notch.
    ///   - deltaY: the scroll delta; negative is scroll up (zoom in).
    ///   - modifiers: the raw GdkModifierType state of the event.
    /// - Returns: the new zoom percent, or nil to let the event scroll.
    /// - Note: `nonisolated` — pure arithmetic, unit-tested without a
    ///   GTK context.
    nonisolated public static func zoomAfterScroll(current: Int, deltaY: Double, modifiers: UInt32) -> Int? {
        guard deltaY != 0 else { return nil }
        // Caps Lock (1 << 1) and the X11 NumLock slot (1 << 4) — the same
        // lock mask MarkdownEditor.handleReturnKey applies.
        let lockMask: UInt32 = (1 << 1) | (1 << 4)
        #if os(macOS)
        let primaryModifier: UInt32 = (1 << 2) | (1 << 28)
        #else
        let primaryModifier: UInt32 = 1 << 2
        #endif
        let masked = modifiers & ~lockMask
        guard masked != 0, masked & ~primaryModifier == 0 else { return nil }
        let step = deltaY < 0 ? zoomStepPercent : -zoomStepPercent
        return min(max(current + step, minZoomPercent), maxZoomPercent)
    }

    /// Scales `baseHundredths` (124 means 1.24) by `percent` with half-up
    /// rounding in integer math, formatted with a literal dot: no
    /// `String(format:)`, no floating point, no locale.
    nonisolated static func scaledLineHeight(baseHundredths: Int, percent: Int) -> String {
        let hundredths = (baseHundredths * percent + 50) / 100
        let whole = hundredths / 100
        let fraction = hundredths % 100
        return fraction < 10 ? "\(whole).0\(fraction)" : "\(whole).\(fraction)"
    }
}
