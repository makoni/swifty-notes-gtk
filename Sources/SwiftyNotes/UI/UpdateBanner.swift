import Adwaita
import Foundation

/// In-app banner shown above the editor when a newer GitHub release is
/// available. AdwBanner only supports a single action button, so this
/// rolls a thin horizontal layout instead — Label + "Update" button +
/// flat close button — wrapped in a Revealer for the slide-down reveal
/// animation that matches AdwBanner's behaviour.
@MainActor
final class UpdateBanner {
    let revealer = Revealer()
    private let container = Box(orientation: .horizontal, spacing: 8)
    private let label = Label("")
        private let updateButton = Button(label: "Update".localized)
    private let closeButton = Button(icon: .windowClose)

    private var onUpdateHandler: (() -> Void)?
    private var onDismissHandler: (() -> Void)?

    init() {
        revealer.transitionType = GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN
        revealer.transitionDuration = 200
        revealer.revealChild = false

        container.addCSSClass(.accent)
        container.addCSSClass(.toolbar)
        container.marginTop = 0
        container.marginBottom = 0

        label.hexpand = true
        label.halign = .start
        label.wrap = true
        label.marginStart = 12
        label.marginEnd = 12
        label.marginTop = 8
        label.marginBottom = 8

        updateButton.addCSSClass(.suggestedAction)
        updateButton.marginTop = 6
        updateButton.marginBottom = 6
        MacOSClickWorkaround.onClick(updateButton) { [weak self] in
            self?.onUpdateHandler?()
        }

        closeButton.addCSSClass(.flat)
        closeButton.addCSSClass(.circular)
        closeButton.tooltipText = "Dismiss".localized
        closeButton.setAccessibleLabel("Dismiss update notification".localized)
        closeButton.marginTop = 6
        closeButton.marginBottom = 6
        closeButton.marginEnd = 6
        MacOSClickWorkaround.onClick(closeButton) { [weak self] in
            self?.dismiss()
        }

        container.append(label)
        container.append(updateButton)
        container.append(closeButton)

        revealer.child = container
    }

    /// Add the banner to a vertical container above the editor area.
    func attach(to parent: Box) {
        parent.append(revealer)
    }

    func show(version: String) {
        label.text = String(format: "Version %@ is available.".localized, version)
        revealer.revealChild = true
    }

    func dismiss() {
        revealer.revealChild = false
        onDismissHandler?()
    }

    var isVisible: Bool { revealer.revealChild }

    func onUpdate(_ handler: @escaping () -> Void) {
        onUpdateHandler = handler
    }

    func onDismiss(_ handler: @escaping () -> Void) {
        onDismissHandler = handler
    }

}
