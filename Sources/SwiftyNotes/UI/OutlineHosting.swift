import Adwaita
import Foundation

/// The surface the launcher's app-level accelerators (F9, Ctrl+G,
/// Ctrl+F, Ctrl+H and the formatting keys) route through — both window
/// types implement all four entry points, so
/// `AppController.activeShortcutHost` can dispatch without caring which
/// kind of window is focused.
@MainActor
protocol GlobalShortcutHost: AnyObject {
    func toggleOutlineVisibility()
    func openCommandPalette()
    func openFindBar(mode: FindReplaceBar.Mode)
    func performFormattingShortcut(_ action: MarkdownFormattingAction)
}

/// Window-agnostic outline behaviour shared by ``MainWindow`` and
/// ``ExternalDocumentWindow``. The conforming window supplies the
/// widgets; the default implementations supply the navigation logic
/// that must behave identically in both windows (scroll-to-heading
/// suppression timing, reorder rewriting, editor folding, the
/// scroll-spy driver's position plumbing).
///
/// Persistence, breadcrumb, and per-note hydration are deliberately
/// NOT here — they are ``MainWindow``-only layers on top.
@MainActor
protocol OutlineHosting: AnyObject {
    var editor: MarkdownEditor { get }
    var editorScroll: ScrolledWindow { get }
    var preview: MarkdownPreview { get }
    var outlineSidebar: OutlineSidebar { get }
    var currentHeadings: [Heading] { get set }
    var outlineScrollSpyDriver: OutlineScrollSpyDriver? { get }
}

@MainActor
extension OutlineHosting {
    /// Click / Ctrl+G handler. Scrolls both panes to the heading and
    /// records it as the scroll-spy anchor. The spy is parked for the
    /// smooth-scroll duration so intermediate scrollTop values can't
    /// overwrite the click's explicit active-id (the "click highlights
    /// but the previous heading stays selected" bug).
    func scrollToHeading(_ heading: Heading) {
        outlineScrollSpyDriver?.suppress(for: .milliseconds(OutlineNavigation.smoothScrollDurationMs + 120))
        OutlineNavigation.scrollEditor(
            view: editor.view,
            buffer: editor.buffer,
            scroll: editorScroll,
            toLine: heading.line,
        )
        OutlineNavigation.scrollPreview(
            heading: heading,
            preview: preview,
            editorScroll: editorScroll,
        )
        outlineSidebar.setActiveHeading(heading.id)
    }

    /// Builds the scroll-spy driver over this window's panes. The
    /// `onActive` hook receives the resolved active heading id;
    /// ``MainWindow`` layers breadcrumb refresh on top, the standalone
    /// window just highlights the sidebar row.
    func makeOutlineScrollSpyDriver(onActive: @escaping @MainActor (String?) -> Void) -> OutlineScrollSpyDriver {
        OutlineScrollSpyDriver(
            editorScroll: editorScroll,
            previewScroll: preview.rootScroll,
            resolveHeadings: { [weak self] in self?.currentHeadings ?? [] },
            previewPositions: { [weak self] headings in
                guard let self else { return [] }
                return OutlinePositions.previewPositions(for: headings, in: preview)
            },
            editorPositions: { [weak self] headings in
                guard let self else { return [] }
                return OutlinePositions.editorPositions(
                    for: headings,
                    view: editor.view,
                    buffer: editor.buffer,
                    scroll: editorScroll,
                )
            },
            onActive: onActive,
        )
    }

    /// Mirror the outline's collapsed-set into the editor as
    /// invisible-tag ranges so a folded section in the panel also
    /// disappears in the source view.
    func applyEditorFolding() {
        OutlineEditorFolding.apply(
            buffer: editor.buffer,
            collapsed: outlineSidebar.collapsedSections,
            headings: currentHeadings,
        )
    }

    /// Drag-to-reorder handler. Rewrites the source markdown and pushes
    /// it into the buffer; the typing-refresh path re-extracts the
    /// outline and the panel snaps to the new shape.
    func reorderOutlineSection(movingID: String, beforeTargetID: String) {
        let currentMarkdown = editor.buffer.text
        guard let rewritten = OutlineReorder.movedMarkdown(
            currentMarkdown,
            movingID: movingID,
            beforeTargetID: beforeTargetID,
            headings: currentHeadings,
        ) else {
            return
        }
        editor.buffer.text = rewritten
    }

    /// Inserts a starter `## Heading` at the cursor and focuses the
    /// editor. Wired to the outline panel's empty-state link.
    func insertStarterHeadingIntoEditor() {
        // Pad so the heading doesn't jam against surrounding text; the
        // trailing `\n\n` leaves the cursor where prose goes.
        let snippet: String
        let bufferText = editor.buffer.text
        if bufferText.isEmpty {
            snippet = "## Heading\n\n"
        } else {
            snippet = "\n\n## Heading\n\n"
        }
        editor.buffer.insertAtCursor(snippet)
        editor.focus()
    }
}
