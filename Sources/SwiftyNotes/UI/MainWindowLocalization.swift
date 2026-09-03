import Adwaita
import Foundation

// Re-reading the interface after the language changes, rather than rebuilding
// the window around a fresh set of strings.
//
// A rebuild is the shorter route and the one several GTK apps take, but it
// costs the whole editing session: buffer contents, cursor and selection,
// scroll offsets in both panes, undo history, outline collapse state, an open
// find bar mid-query. None of that survives constructing a replacement window,
// and none of it has anything to do with language. So the window keeps its
// widgets and re-reads every string instead.
//
// Only chrome written once at construction needs this. Dialogs, toasts,
// popovers and context menus are built at the moment they are shown, so they
// already come out in the current language.
@MainActor
extension MainWindow {
    /// Re-applies every user-visible string in the window.
    ///
    /// Kept as one method that walks the whole surface, deliberately: a
    /// language change is exactly the case where a half-updated window is
    /// worse than a slow one, and `LocalizationCatalogTests` asserts the
    /// visible chrome all moves together.
    func retranslate() {
        headerTitle.title = "Swifty Notes"
        updateHeaderSubtitle()

        configureToolbarAccessibility()
        configureToolbarTooltips()
        updateSidebarToggleAccessibility()
        updateSidebarToggleTooltip()
        configureViewModeToggleContent()
        editorFormattingToolbar.retranslate()
        rebuildOverflowMenu()
        applyOutlineVisibility()

        trashedNoteBanner.buttonLabel = "Restore".localized
        if let previewedTrashedNoteID,
           let trashedNote = state.trashedNotes.first(where: { $0.id == previewedTrashedNoteID }) {
            trashedNoteBanner.title = String(
                format: "“%@” is in the Trash".localized,
                trashedNote.title,
            )
        }
        updateBanner.retranslate()

        // Set once inside the editor's and preview's own builders, so nothing
        // else here reaches them — a screen-reader user would otherwise hear
        // "Markdown Editor" in English beside a fully translated interface.
        editor.view.setAccessibleLabel("Markdown Editor".localized)
        preview.retranslateAccessibility()

        sidebar.retranslate()
        outlineSidebar.retranslate()
        findReplace.retranslate()

        // The size picker caches its popover on first use and bakes the
        // column-alignment wording into it, so drop it rather than teach it to
        // retranslate a popover the user is not looking at.
        tableSizePicker = nil

        // Count-bearing and content-derived labels come back through the
        // normal render path: the sidebar's "Notes (N)" title, and — via
        // ``refreshPreview()``, which re-runs the outline too — the outline
        // footer and both empty states.
        refreshSidebar()
        refreshPreview()
        updateActionAvailability()
    }
}
