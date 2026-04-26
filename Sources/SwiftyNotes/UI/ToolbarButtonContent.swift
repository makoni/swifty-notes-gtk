import Adwaita
import Foundation

/// Layout configuration for a toolbar button's icon-and-label combo.
///
/// The same configuration drives the formatting toolbar buttons and the
/// view-mode switcher in both ``MainWindow`` and ``ExternalDocumentWindow``.
struct ToolbarButtonContentConfiguration {
    let primaryText: String
    let iconName: String?
    let prefersCompactLabel: Bool
    let hidesLabelWhenCompact: Bool

    func displayedText(isCompact: Bool) -> String? {
        if isCompact, hidesLabelWhenCompact {
            return nil
        }
        return primaryText
    }
}

/// Builds the inner widget tree for a toolbar button (icon, label,
/// optional spacing) from a ``ToolbarButtonContentConfiguration``.
///
/// Resolves bundled icons (those shipped under our resource bundle but
/// not in the active GTK icon theme) through ``MainWindow.bundledIconFilePath``
/// before falling back to a theme lookup. Used by both windows so a fix
/// here applies everywhere.
@MainActor
enum ToolbarButtonContent {
    static func make(
        configuration: ToolbarButtonContentConfiguration,
        isCompact: Bool,
    ) -> Widget {
        let labelText = configuration.displayedText(isCompact: isCompact)
        let showsLabel = labelText != nil
        let box = Box(orientation: .horizontal, spacing: showsLabel && configuration.iconName != nil ? 6 : 0)
        let horizontalMargin = showsLabel ? (configuration.prefersCompactLabel ? 2 : 4) : 6
        box.marginStart = horizontalMargin
        box.marginEnd = horizontalMargin

        if let iconName = configuration.iconName {
            let image: Image
            if let bundledPath = MainWindow.bundledIconFilePath(for: iconName) {
                image = Image(filename: bundledPath)
            } else {
                image = Image(iconName: iconName)
            }
            image.pixelSize = 16
            box.append(image)
        }

        if let labelText {
            let label = Label(labelText)
            label.xalign = 0
            if configuration.prefersCompactLabel {
                label.addCSSClass(.caption)
            }
            box.append(label)
        }
        return box
    }
}
