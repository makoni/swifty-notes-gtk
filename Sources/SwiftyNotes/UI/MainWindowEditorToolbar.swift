import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func configureViewModeToggleContent() {
        setToggleContent(
            editorModeToggle,
            label: "Editor",
            iconName: "document-edit-symbolic",
        )
        setToggleContent(
            splitModeToggle,
            label: "Split",
            iconName: "view-dual-symbolic",
        )
        setToggleContent(
            previewModeToggle,
            label: "Preview",
            iconName: "text-x-generic-symbolic",
        )
    }

    func configureEditorFormattingToolbar() {
        guard editorFormattingButtons.isEmpty else { return }

        editorFormattingBar.addCSSClass(.toolbar)
        editorFormattingBar.marginStart = 8
        editorFormattingBar.marginEnd = 8
        editorFormattingBar.marginTop = 8
        editorFormattingBar.marginBottom = 8
        editorFormattingBar.hexpand = false
        editorFormattingBar.halign = .start

        editorFormattingPrimaryRow.halign = .start
        editorFormattingSecondaryRow.halign = .start
        editorFormattingSecondaryRow.visible = false

        editorFormattingBar.append(editorFormattingPrimaryRow)
        editorFormattingBar.append(editorFormattingSecondaryRow)

        editorFormattingBarScroll.child = editorFormattingBar
        editorFormattingBarScroll.setPolicy(horizontal: .automatic, vertical: .never)
        editorFormattingBarScroll.hexpand = true
        editorFormattingBarScroll.minContentWidth = 0

        editorInlineFormattingGroup.addCSSClass("linked")
        editorBlockFormattingGroup.addCSSClass("linked")

        let inlineActions: [MarkdownFormattingAction] = [.heading, .bold, .italic, .code, .link]
        let blockActions: [MarkdownFormattingAction] = [.quote, .bulletList, .numberedList, .taskList, .table]

        for action in inlineActions {
            let button = makeEditorFormattingButton(for: action)
            editorInlineFormattingGroup.append(button)
            editorFormattingButtons[action] = button
        }

        for action in blockActions {
            let button = makeEditorFormattingButton(for: action)
            editorBlockFormattingGroup.append(button)
            editorFormattingButtons[action] = button
        }

        layoutEditorFormattingRows(useTwoRows: false)
    }

    func applyEditorFormatting(_ action: MarkdownFormattingAction) {
        guard state.selectedNote != nil else { return }
        if action == .table {
            presentTableSizePicker()
            return
        }
        editor.applyFormatting(action)
    }

    func presentTableSizePicker() {
        guard let button = editorFormattingButtons[.table] else { return }
        let picker = ensureTableSizePicker()
        picker.popover.present(from: button)
    }

    private func ensureTableSizePicker() -> TableSizePicker {
        if let picker = tableSizePicker { return picker }
        let picker = TableSizePicker()
        picker.onSelect = { [weak self] rows, cols in
            self?.editor.insertTable(rows: rows, cols: cols)
        }
        tableSizePicker = picker
        return picker
    }

    func updateEditorFormattingToolbarLayout(forWidth width: Int) {
        guard width > 0 else { return }

        let effectiveCompactThreshold = resolvedCompactThreshold()
        let shouldUseCompactMode = width < effectiveCompactThreshold
        if isEditorFormattingToolbarCompact != shouldUseCompactMode {
            isEditorFormattingToolbarCompact = shouldUseCompactMode
            refreshEditorFormattingToolbarButtons()
        }

        let shouldUseTwoRows: Bool
        if shouldUseCompactMode {
            layoutEditorFormattingRows(useTwoRows: false)
            shouldUseTwoRows = measuredNaturalWidth(of: editorFormattingBar) > width
        } else {
            shouldUseTwoRows = false
        }

        if isEditorFormattingToolbarUsingTwoRows != shouldUseTwoRows {
            isEditorFormattingToolbarUsingTwoRows = shouldUseTwoRows
        }
        layoutEditorFormattingRows(useTwoRows: shouldUseTwoRows)
        editorFormattingBarScroll.horizontalAdjustment.value = 0
    }

    /// Returns the minimum editor-pane width at which the formatting
    /// toolbar can still show full labels in a single row. Uses the
    /// measured natural width of the non-compact toolbar (plus a small
    /// padding allowance) when available; falls back to the static
    /// ``editorFormattingCompactWidthThreshold`` during early setup
    /// before the widget tree has been through its first allocation.
    private func resolvedCompactThreshold() -> Int {
        ensureEditorFormattingNonCompactNaturalWidthCached()
        let measured = editorFormattingNonCompactNaturalWidth
        if measured > 0 {
            // 24 px safety margin covers the outer horizontal margins
            // that aren't part of editorFormattingBar's own measurement.
            return measured + 24
        }
        return Self.editorFormattingCompactWidthThreshold
    }

    private func ensureEditorFormattingNonCompactNaturalWidthCached() {
        guard editorFormattingNonCompactNaturalWidth == 0 else { return }

        let savedCompact = isEditorFormattingToolbarCompact
        let savedTwoRows = isEditorFormattingToolbarUsingTwoRows

        if savedCompact {
            isEditorFormattingToolbarCompact = false
            refreshEditorFormattingToolbarButtons()
        }
        if savedTwoRows {
            layoutEditorFormattingRows(useTwoRows: false)
        }

        let measured = measuredNaturalWidth(of: editorFormattingBar)
        if measured > 0 {
            editorFormattingNonCompactNaturalWidth = measured
        }

        if isEditorFormattingToolbarCompact != savedCompact {
            isEditorFormattingToolbarCompact = savedCompact
            refreshEditorFormattingToolbarButtons()
        }
        if isEditorFormattingToolbarUsingTwoRows != savedTwoRows {
            layoutEditorFormattingRows(useTwoRows: savedTwoRows)
        }
    }

    func refreshEditorFormattingToolbarLayout() {
        updateEditorFormattingToolbarLayout(forWidth: resolvedEditorFormattingToolbarWidth())
    }

    func editorFormattingToolbarLabels() -> [MarkdownFormattingAction: String?] {
        var labels: [MarkdownFormattingAction: String?] = [:]
        for action in MarkdownFormattingAction.allCases {
            labels[action] = editorFormattingButtonConfigurations[action]?.displayedText(
                isCompact: isEditorFormattingToolbarCompact,
            )
        }
        return labels
    }

    private func makeEditorFormattingButton(for action: MarkdownFormattingAction) -> Button {
        let button = Button()
        button.tooltipText = action.tooltip
        button.setAccessibleLabel(action.accessibilityLabel)
        let configuration = ToolbarButtonContentConfiguration(
            primaryText: action.shortLabel ?? action.accessibilityLabel,
            iconName: action.iconName,
            prefersCompactLabel: action.iconName != nil && action.shortLabel == nil,
            hidesLabelWhenCompact: action.iconName != nil,
        )
        editorFormattingButtonConfigurations[action] = configuration
        button.child = makeToolbarButtonContent(
            configuration: configuration,
            isCompact: isEditorFormattingToolbarCompact,
        )
        return button
    }

    private func setToggleContent(_ toggle: ToggleButton, label: String, iconName: String) {
        toggle.child = makeToolbarButtonContent(
            configuration: ToolbarButtonContentConfiguration(
                primaryText: label,
                iconName: iconName,
                prefersCompactLabel: false,
                hidesLabelWhenCompact: false,
            ),
            isCompact: false,
        )
    }

    private func resolvedEditorFormattingToolbarWidth() -> Int {
        if state.viewMode == .split {
            let totalWidth = currentPreviewContainerWidth
            let previewWidth = Self.resolvedPreviewWidth(
                storedWidth: state.preferredPreviewWidth,
                availableWidth: totalWidth,
            )
            return max(totalWidth - previewWidth, Self.minimumEditorWidth)
        }

        let allocatedWidth = max(editorFormattingBarScroll.width, editorContent.width, editorPreviewPane.width)
        if allocatedWidth > 0 {
            return allocatedWidth
        }
        return currentPreviewContainerWidth
    }

    private func layoutEditorFormattingRows(useTwoRows: Bool) {
        detachEditorFormattingWidgetIfNeeded(editorInlineFormattingGroup)
        detachEditorFormattingWidgetIfNeeded(editorFormattingGroupSeparator)
        detachEditorFormattingWidgetIfNeeded(editorBlockFormattingGroup)

        editorFormattingPrimaryRow.append(editorInlineFormattingGroup)
        if useTwoRows {
            editorFormattingSecondaryRow.append(editorBlockFormattingGroup)
            editorFormattingSecondaryRow.visible = true
        } else {
            editorFormattingPrimaryRow.append(editorFormattingGroupSeparator)
            editorFormattingPrimaryRow.append(editorBlockFormattingGroup)
            editorFormattingSecondaryRow.visible = false
        }
    }

    private func refreshEditorFormattingToolbarButtons() {
        for (action, button) in editorFormattingButtons {
            guard let configuration = editorFormattingButtonConfigurations[action] else { continue }
            button.child = makeToolbarButtonContent(
                configuration: configuration,
                isCompact: isEditorFormattingToolbarCompact,
            )
        }
    }

    private func detachEditorFormattingWidgetIfNeeded(_ widget: Widget) {
        if widget.parent?.isSame(as: editorFormattingPrimaryRow) == true {
            editorFormattingPrimaryRow.remove(widget)
        } else if widget.parent?.isSame(as: editorFormattingSecondaryRow) == true {
            editorFormattingSecondaryRow.remove(widget)
        }
    }

    private func measuredNaturalWidth(of widget: Widget) -> Int {
        widget.measure(orientation: .horizontal).natural
    }

    private func makeToolbarButtonContent(
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
            let image = Image(iconName: iconName)
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
