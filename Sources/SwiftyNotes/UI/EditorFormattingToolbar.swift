import Adwaita
import Foundation

/// Inline + block formatting toolbar shared by ``MainWindow`` and
/// ``ExternalDocumentWindow``.
///
/// Owns the widget tree (scroll wrapper, two-row stack, two linked
/// button groups), the buttons themselves, and the compact/two-row
/// layout state machine. Hosts get notified of clicks through
/// ``onAction`` and call ``updateLayout(forWidth:fallbackThreshold:)``
/// when their available width changes.
///
/// Earlier each window built and laid out its own copy of this toolbar
/// via near-identical extension methods. A bundled-icon fix landed in
/// the main window first and was missing from the external window
/// (the Insert Table button rendered as a "missing icon" placeholder
/// there), which is exactly the kind of drift this type prevents.
@MainActor
final class EditorFormattingToolbar {
    let scrolled = ScrolledWindow()
    private let bar = Box(orientation: .vertical, spacing: 6)
    private let primaryRow = Box(orientation: .horizontal, spacing: 8)
    private let secondaryRow = Box(orientation: .horizontal, spacing: 8)
    private let inlineGroup = Box(orientation: .horizontal, spacing: 0)
    private let blockGroup = Box(orientation: .horizontal, spacing: 0)
    private let groupSeparator = Separator(orientation: .vertical)

    private(set) var buttons: [MarkdownFormattingAction: Button] = [:]
    private var configurations: [MarkdownFormattingAction: ToolbarButtonContentConfiguration] = [:]
    private(set) var isCompact = false
    private(set) var isUsingTwoRows = false
    private var nonCompactNaturalWidth: Int = 0

    /// Invoked when a formatting button is clicked. Hosts decide what to
    /// do — apply formatting, present the table picker, etc.
    var onAction: ((MarkdownFormattingAction) -> Void)?

    private static let inlineActions: [MarkdownFormattingAction] = [.heading, .bold, .italic, .code, .link]
    private static let blockActions: [MarkdownFormattingAction] = [.quote, .bulletList, .numberedList, .taskList, .table]

    init() {
        configure()
    }

    /// Reflows the toolbar based on the host's available editor width.
    ///
    /// ``fallbackThreshold`` is used during the very first allocation,
    /// before the bar has been measured — once a non-compact natural
    /// width is known, the toolbar caches it and uses that as the
    /// switching threshold (with a small padding allowance).
    func updateLayout(forWidth width: Int, fallbackThreshold: Int) {
        guard width > 0 else { return }

        let effectiveCompactThreshold = resolvedCompactThreshold(fallback: fallbackThreshold)
        let shouldUseCompactMode = width < effectiveCompactThreshold
        if isCompact != shouldUseCompactMode {
            isCompact = shouldUseCompactMode
            refreshButtons()
        }

        let shouldUseTwoRows: Bool
        if shouldUseCompactMode {
            layoutRows(useTwoRows: false)
            shouldUseTwoRows = bar.measure(orientation: .horizontal).natural > width
        } else {
            shouldUseTwoRows = false
        }

        if isUsingTwoRows != shouldUseTwoRows {
            isUsingTwoRows = shouldUseTwoRows
        }
        layoutRows(useTwoRows: shouldUseTwoRows)
        scrolled.horizontalAdjustment.value = 0
    }

    /// Resolves the same compact-threshold value the toolbar would use
    /// itself on the next layout pass. Exposed for debug snapshots so
    /// tests don't have to duplicate the measurement logic.
    func compactThreshold(fallback: Int) -> Int {
        resolvedCompactThreshold(fallback: fallback)
    }

    /// Returns each action's currently displayed label text. Used by
    /// the debug snapshot helpers in tests.
    func currentLabels() -> [MarkdownFormattingAction: String?] {
        var labels: [MarkdownFormattingAction: String?] = [:]
        for action in MarkdownFormattingAction.allCases {
            labels[action] = configurations[action]?.displayedText(isCompact: isCompact)
        }
        return labels
    }

    private func configure() {
        bar.addCSSClass(.toolbar)
        bar.marginStart = 8
        bar.marginEnd = 8
        bar.marginTop = 8
        bar.marginBottom = 8
        bar.hexpand = false
        bar.halign = .start

        primaryRow.halign = .start
        secondaryRow.halign = .start
        secondaryRow.visible = false

        bar.append(primaryRow)
        bar.append(secondaryRow)

        scrolled.child = bar
        scrolled.setPolicy(horizontal: .automatic, vertical: .never)
        scrolled.hexpand = true
        scrolled.minContentWidth = 0

        inlineGroup.addCSSClass("linked")
        blockGroup.addCSSClass("linked")

        for action in Self.inlineActions {
            let button = makeButton(for: action)
            inlineGroup.append(button)
            buttons[action] = button
        }
        for action in Self.blockActions {
            let button = makeButton(for: action)
            blockGroup.append(button)
            buttons[action] = button
        }

        layoutRows(useTwoRows: false)
    }

    private func resolvedCompactThreshold(fallback: Int) -> Int {
        ensureNonCompactNaturalWidthCached()
        if nonCompactNaturalWidth > 0 {
            // 24 px safety margin covers the outer horizontal margins
            // that aren't part of the bar's own measurement.
            return nonCompactNaturalWidth + 24
        }
        return fallback
    }

    private func ensureNonCompactNaturalWidthCached() {
        guard nonCompactNaturalWidth == 0 else { return }

        let savedCompact = isCompact
        let savedTwoRows = isUsingTwoRows

        if savedCompact {
            isCompact = false
            refreshButtons()
        }
        if savedTwoRows {
            layoutRows(useTwoRows: false)
        }

        let measured = bar.measure(orientation: .horizontal).natural
        if measured > 0 {
            nonCompactNaturalWidth = measured
        }

        if isCompact != savedCompact {
            isCompact = savedCompact
            refreshButtons()
        }
        if isUsingTwoRows != savedTwoRows {
            layoutRows(useTwoRows: savedTwoRows)
        }
    }

    private func makeButton(for action: MarkdownFormattingAction) -> Button {
        let button = Button()
        button.tooltipText = action.tooltip
        button.setAccessibleLabel(action.accessibilityLabel)
        let configuration = ToolbarButtonContentConfiguration(
            primaryText: action.shortLabel ?? action.accessibilityLabel,
            iconName: action.iconName,
            prefersCompactLabel: action.iconName != nil && action.shortLabel == nil,
            hidesLabelWhenCompact: action.iconName != nil,
        )
        configurations[action] = configuration
        button.child = ToolbarButtonContent.make(configuration: configuration, isCompact: isCompact)
        button.onClicked { [weak self] in
            self?.onAction?(action)
        }
        return button
    }

    private func layoutRows(useTwoRows: Bool) {
        detachIfNeeded(inlineGroup)
        detachIfNeeded(groupSeparator)
        detachIfNeeded(blockGroup)
        primaryRow.append(inlineGroup)
        if useTwoRows {
            secondaryRow.append(blockGroup)
            secondaryRow.visible = true
        } else {
            primaryRow.append(groupSeparator)
            primaryRow.append(blockGroup)
            secondaryRow.visible = false
        }
    }

    private func detachIfNeeded(_ widget: Widget) {
        if widget.parent?.isSame(as: primaryRow) == true {
            primaryRow.remove(widget)
        } else if widget.parent?.isSame(as: secondaryRow) == true {
            secondaryRow.remove(widget)
        }
    }

    private func refreshButtons() {
        for (action, button) in buttons {
            guard let configuration = configurations[action] else { continue }
            button.child = ToolbarButtonContent.make(configuration: configuration, isCompact: isCompact)
        }
    }
}
