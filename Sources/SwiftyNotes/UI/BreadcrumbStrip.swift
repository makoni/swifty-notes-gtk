import Adwaita
import Foundation

/// "You are here" strip above the editor in variant A — mirrors the
/// design's `.sn-breadcrumb` block. Three segments separated by
/// chevron glyphs: document title, the most recent H2 section, and
/// the deepest heading the user has scrolled past.
///
/// Single-Label implementation: every segment + chevron is rendered
/// through one Pango-markup string. The earlier Box-of-5-Labels
/// shape added 7 widgets to every render-tree walk on every frame —
/// after the scroll-perf audit (sysprof showed render walk dominating
/// scroll CPU) collapsing this to one widget visibly reduces the
/// per-frame cost without losing any visual fidelity.
///
/// The strip stays a fixed 48 px tall so the editor toolbar and the
/// breadcrumb start their content at the same vertical position on
/// both sides of the split (matching the design's `height: 48 px`
/// rule).
@MainActor
final class BreadcrumbStrip {
    let root: Box

    /// Single Pango-markup Label that renders the whole breadcrumb.
    /// Exposed so widget tests can assert on the rendered text / markup
    /// (tests previously inspected the per-segment labels directly).
    let label: Label

    // Memoization keys so the scroll-spy hot path doesn't re-write the
    // markup on every tick when the (docTitle, section, leaf) tuple is
    // unchanged — each markup assignment invalidates Pango layout.
    private var lastDocTitle: String?
    private var lastSection: String?
    private var lastLeaf: String?

    init() {
        label = Label("")
        label.xalign = 0
        label.useMarkup = true
        label.ellipsize = .end

        root = Box(orientation: .horizontal, spacing: 0)
        root.addCSSClass("sn-breadcrumb")
        root.marginStart = 36
        root.marginEnd = 36
        // 48 px height matches the editor toolbar's natural height
        // so the doc title lines up with the toolbar's first button
        // on the other side of the split.
        root.setSizeRequest(height: 48)
        root.append(label)

        update(docTitle: "", section: nil, leaf: nil)
    }

    /// Refresh the three segments. `nil` segments are hidden (their
    /// preceding chevron disappears too) so a heading-less note shows
    /// only the doc title and an H1-only note shows "Doc › H1".
    func update(docTitle: String, section: String?, leaf: String?) {
        if lastDocTitle == docTitle, lastSection == section, lastLeaf == leaf { return }
        lastDocTitle = docTitle
        lastSection = section
        lastLeaf = leaf

        label.markup = Self.buildMarkup(docTitle: docTitle, section: section, leaf: leaf)
        // Visibility: hide the whole strip if there's nothing to show.
        label.visible = !docTitle.isEmpty || section?.isEmpty == false || leaf?.isEmpty == false
    }

    /// Convenience: derive the section + leaf from the currently active
    /// heading and the headings list. H1 becomes the section
    /// (Doc › H1 alone, no leaf); H2 alone is the section; an H3+ row
    /// uses the most recent H2 above it as the section and itself as
    /// the leaf.
    func update(docTitle: String, headings: [Heading], activeID: String?) {
        guard let activeID, let active = headings.first(where: { $0.id == activeID }) else {
            update(docTitle: docTitle, section: nil, leaf: nil)
            return
        }
        switch active.level {
        case 1, 2:
            update(docTitle: docTitle, section: active.text, leaf: nil)
        default:
            // For H3+ find the most recent H2 above.
            var parent: Heading?
            for heading in headings {
                if heading.id == active.id { break }
                if heading.level == 2 { parent = heading }
            }
            update(docTitle: docTitle, section: parent?.text ?? "", leaf: active.text)
        }
    }

    /// Build the single Pango-markup string. Dim color for doc + section
    /// + chevrons; full-weight foreground for the leaf when present;
    /// otherwise dim foreground on the section so an H1/H2-only state
    /// reads as a "passive you-are-here" cue. The colors use Adwaita's
    /// CSS-resolved foreground / muted tokens by way of opacity spans —
    /// avoids hard-coding hex values that wouldn't track theme changes.
    static func buildMarkup(docTitle: String, section: String?, leaf: String?) -> String {
        var pieces: [String] = []
        if !docTitle.isEmpty {
            pieces.append("<span alpha=\"60%\">\(PangoMarkup.escape(docTitle))</span>")
        }
        if let section, !section.isEmpty {
            let renderedSection: String
            if let leaf, !leaf.isEmpty {
                renderedSection = "<span alpha=\"60%\">\(PangoMarkup.escape(section))</span>"
            } else {
                // No leaf — the section is the current focus, render full-weight.
                renderedSection = "<span weight=\"500\">\(PangoMarkup.escape(section))</span>"
            }
            if !pieces.isEmpty {
                pieces.append(separator)
            }
            pieces.append(renderedSection)
        }
        if let leaf, !leaf.isEmpty {
            if !pieces.isEmpty {
                pieces.append(separator)
            }
            pieces.append("<span weight=\"500\">\(PangoMarkup.escape(leaf))</span>")
        }
        return pieces.joined(separator: " ")
    }

    /// Pango-escaped chevron `›` with a dim alpha matching the design's
    /// `.sn-breadcrumb svg { opacity: 0.5 }` rule.
    private static let separator = "<span alpha=\"45%\">›</span>"

}
