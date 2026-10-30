import Foundation

/// Sizes of the panes beside the editor that the saved workspace depends on.
enum PaneLayout {
    static let minimumPreviewWidth = 360
    static let minimumEditorWidth = 320
    static let outlineWidthFraction = 0.18
    static let minimumOutlineWidth = 220
    static let maximumOutlineWidth = 320

    /// The Outline's width in a window `windowWidth` wide: the share of the
    /// window its split view gives it, within its bounds.
    static func outlineWidth(forWindowWidth windowWidth: Int) -> Int {
        min(max(Int(Double(windowWidth) * outlineWidthFraction), minimumOutlineWidth), maximumOutlineWidth)
    }

    /// The Outline's width in a window: none while hidden, else as
    /// allocated, else — before the first allocation — as its split view
    /// will size it in a window `windowWidth` wide.
    static func outlineWidth(isShown: Bool, allocatedWidth: Int, windowWidth: Int) -> Int {
        guard isShown else { return 0 }
        return allocatedWidth > 0 ? allocatedWidth : outlineWidth(forWindowWidth: windowWidth)
    }

    /// The preview's width for the remembered `storedWidth` in the room
    /// `availableWidth` the editor and preview share: within both minimums,
    /// and the old default grown to a comfortable share of a wide room.
    static func resolvedPreviewWidth(storedWidth: Int, availableWidth: Int) -> Int {
        let boundedAvailableWidth = max(availableWidth, minimumPreviewWidth + minimumEditorWidth)
        let maximumPreviewWidth = max(boundedAvailableWidth - minimumEditorWidth, minimumPreviewWidth)
        let comfortablePreviewWidth = min(
            max(Int(Double(boundedAvailableWidth) * 0.34), WorkspaceState.defaultPreviewWidth),
            maximumPreviewWidth,
        )
        let requestedWidth: Int = if storedWidth == WorkspaceState.legacyDefaultPreviewWidth {
            max(storedWidth, comfortablePreviewWidth)
        } else {
            storedWidth
        }
        return min(max(requestedWidth, minimumPreviewWidth), maximumPreviewWidth)
    }
}
