import Adwaita
import Foundation

/// Shared helper for keeping the preview pane scrolled in step with
/// the editor pane in split view. Both ``MainWindow`` and
/// ``ExternalDocumentWindow`` decide *when* to sync (each has its own
/// view-mode state and pane-attachment flags) and then delegate the
/// actual progress-mapping math here.
@MainActor
enum PreviewScrollSync {
    /// Maps the editor's vertical scroll progress onto the preview's
    /// vertical adjustment so a scroll in the editor moves the preview
    /// proportionally.
    ///
    /// Bails early if the preview surface is not realized or measured
    /// yet — calling this against an unallocated widget tree is a
    /// no-op rather than a crash.
    static func sync(editor editorScroll: ScrolledWindow, preview previewScroll: ScrolledWindow) {
        guard previewScroll.parent != nil, previewScroll.width > 0, previewScroll.height > 0 else { return }
        let source = editorScroll.verticalAdjustment
        let destination = previewScroll.verticalAdjustment
        let sourceMax = max(source.upper - source.pageSize - source.lower, 0)
        let destinationMax = max(destination.upper - destination.pageSize - destination.lower, 0)
        let progress = sourceMax > 0 ? (source.value - source.lower) / sourceMax : 0
        destination.value = destination.lower + (destinationMax * progress)
    }
}
