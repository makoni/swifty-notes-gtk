import Adwaita
import Foundation

/// Bundled CSS that styles the Outline panel + Ctrl+G palette.
///
/// Loaded once globally on first MainWindow construction so the rules
/// apply across every window (the main note window, external document
/// windows, palette transients). Class names mirror the design's
/// `.sn-out`, `.sn-out-h*`, and `.sn-pal-*` selectors so the
/// implementation reads alongside the design file.
@MainActor
enum OutlineCSS {
    /// Visual hierarchy in the outline list. H1 is largest and boldest
    /// (it's the document anchor); H2 is the "section anchor", H3 is
    /// the section's content; H4–H6 progressively dim and shrink so
    /// deep nesting stays legible without overwhelming the panel.
    ///
    /// Pill colours in the palette follow the design's green-for-H2 /
    /// blue-for-H3 baseline; H1 gets a neutral chip so it reads as
    /// "document-level" rather than competing with H2; H4–H6 reuse the
    /// H3 hue with progressively lower alpha so the depth maps onto
    /// the visual stack.
    static let stylesheet = """
    /* Outline row */
    row.sn-out-h1 label {
        font-weight: 700;
        font-size: 13.5pt;
    }
    row.sn-out-h2 label {
        font-weight: 600;
        font-size: 12pt;
    }
    row.sn-out-h3 label {
        font-weight: 400;
        font-size: 11pt;
    }
    row.sn-out-h4 label {
        font-weight: 400;
        font-size: 10.5pt;
        opacity: 0.85;
    }
    row.sn-out-h5 label {
        font-weight: 400;
        font-size: 10pt;
        opacity: 0.75;
    }
    row.sn-out-h6 label {
        font-weight: 400;
        font-size: 9.5pt;
        opacity: 0.65;
    }

    /* Active row marker */
    row.sn-out.is-active {
        background-color: alpha(@accent_bg_color, 0.18);
    }

    /* Palette pills */
    label.sn-pal-pill {
        padding: 1px 6px;
        border-radius: 5px;
        font-family: monospace;
        font-size: 9.5pt;
        font-weight: 600;
        letter-spacing: 0.02em;
    }
    label.sn-pal-pill-h1 {
        background-color: alpha(@theme_fg_color, 0.10);
        color: @theme_fg_color;
    }
    label.sn-pal-pill-h2 {
        background-color: rgba(46, 194, 126, 0.18);
        color: #88e0a8;
    }
    label.sn-pal-pill-h3 {
        background-color: rgba(53, 132, 228, 0.18);
        color: #9dbff5;
    }
    label.sn-pal-pill-h4,
    label.sn-pal-pill-h5,
    label.sn-pal-pill-h6 {
        background-color: rgba(53, 132, 228, 0.10);
        color: alpha(#9dbff5, 0.85);
    }

    /* Palette current-row hint chip */
    label.sn-pal-hint {
        font-size: 9pt;
        padding: 1px 6px;
        border-radius: 4px;
        background-color: alpha(@theme_fg_color, 0.06);
    }

    /* Outline count badge */
    label.outline-count {
        font-size: 9.5pt;
        padding: 1px 6px;
        border-radius: 9px;
        background-color: alpha(@theme_fg_color, 0.06);
    }
    """

    private static var loaded = false
    private static let provider = CSSProvider()

    /// Lazy global install. Idempotent — safe to call from every
    /// MainWindow / ExternalDocumentWindow construction.
    static func installGlobalIfNeeded() {
        guard !loaded else { return }
        loaded = true
        provider.loadFromString(stylesheet)
        provider.addToDefaultDisplay()
    }
}
