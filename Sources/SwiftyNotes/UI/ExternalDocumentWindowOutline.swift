import Adwaita
import Foundation

// Shared navigation (scroll-to-heading, scroll-spy plumbing, reorder,
// folding, starter heading) comes from ``OutlineHosting``; this file
// keeps only what is specific to the standalone document window —
// plain visibility state (no persistence) and the palette without
// per-note recents hydration.
extension ExternalDocumentWindow: OutlineHosting, GlobalShortcutHost {}

extension ExternalDocumentWindow {
    func toggleOutlineVisibility() {
        isOutlineVisible = !isOutlineVisible
        applyOutlineVisibility()
    }

    func applyOutlineVisibility() {
        outlineSplitView.showSidebar = isOutlineVisible
        if isOutlineVisible {
            outlineToggleButton.addCSSClass(.activeCSSClass)
        } else {
            outlineToggleButton.removeCSSClass(.activeCSSClass)
        }
        outlineToggleButton.tooltipText = isOutlineVisible
            ? "Hide outline (F9)".localized
            : "Show outline (F9)".localized
    }

    func openCommandPalette() {
        guard !currentHeadings.isEmpty else {
            toastOverlay.addToast(Toast(title: "No headings to jump to.".localized))
            return
        }
        // Rapid double Ctrl+G: drop the old wrapper — GTK closes its
        // dialog as soon as the new one presents (same pattern as
        // MainWindow).
        activeCommandPalette = nil
        let palette = CommandPaletteWindow(
            transientFor: window,
            headings: currentHeadings,
            currentID: outlineSidebar.activeHeadingID,
            recents: outlineRecentJumps.ids,
            onPick: { [weak self] id in
                guard let self else { return }
                outlineRecentJumps.record(id)
                if let heading = currentHeadings.first(where: { $0.id == id }) {
                    scrollToHeading(heading)
                }
            },
            onClosed: { [weak self] in
                self?.activeCommandPalette = nil
            },
        )
        activeCommandPalette = palette
        palette.present()
    }

    /// Re-extracts the outline and pushes it into the sidebar. Unlike
    /// ``MainWindow``, there is no per-note persistence to hydrate —
    /// a standalone document window lives and dies with its file.
    func refreshOutline(markdown: String, blocks: [RenderedBlock]) {
        let headings = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks)
        outlineSidebar.setHeadings(headings)
        currentHeadings = headings
        applyEditorFolding()
    }
}

private extension String {
    static let activeCSSClass = "active"
}
