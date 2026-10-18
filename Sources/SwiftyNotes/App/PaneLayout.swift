import Foundation

/// Sizes of the panes beside the editor that the saved workspace depends on.
enum PaneLayout {
    static let minimumPreviewWidth = 360
    static let outlineWidthFraction = 0.18
    static let minimumOutlineWidth = 220
    static let maximumOutlineWidth = 320

    /// The Outline's width in a window `windowWidth` wide: the share of the
    /// window its split view gives it, within its bounds.
    static func outlineWidth(forWindowWidth windowWidth: Int) -> Int {
        min(max(Int(Double(windowWidth) * outlineWidthFraction), minimumOutlineWidth), maximumOutlineWidth)
    }
}
