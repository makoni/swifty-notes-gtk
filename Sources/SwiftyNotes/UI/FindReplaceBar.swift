import Adwaita
import Foundation

/// In-document find / replace bar, mounted inside the editor and the
/// preview panes. One bar serves both modes — Ctrl+F opens it in
/// find-only mode (replace row hidden); Ctrl+H reveals the replace
/// row on the same bar. Matches the GNOME Text Editor / Builder
/// idiom rather than a floating dialog.
///
/// This file is a pure UI shell: it builds the widget tree and
/// exposes callbacks. The actual searching is driven by per-pane
/// controllers (EditorSearchController, PreviewSearchController)
/// added in later phases of the find/replace work tracked in #26.
@MainActor
final class FindReplaceBar {
    enum Mode {
        case find
        case replace
    }

    /// AdwSearchBar wrapper. Mount this in a vertical Box at the top
    /// of the host pane — `searchModeEnabled` reveals it with the
    /// standard GTK slide-down animation.
    let root: SearchBar

    /// Visible text widgets — exposed so tests can drive input and
    /// per-pane controllers can wire their own focus / selection
    /// rules on top.
    let findEntry: SearchEntry
    let replaceEntry: Entry

    /// Match-case / whole-word / regex toggles. Order in the row
    /// matches the order users see in VS Code so the muscle memory
    /// transfers; labels use the same compact glyphs ("Aa", "ab",
    /// ".*"). Tooltips spell out the full meaning.
    let caseSensitiveToggle: ToggleButton
    let wholeWordToggle: ToggleButton
    let regexToggle: ToggleButton

    /// "3 of 17" status. Hidden when the query is empty so the bar
    /// doesn't read as "0 of 0" before the user types anything.
    let countLabel: Label

    /// Step navigation.
    let prevButton: Button
    let nextButton: Button

    /// Replace controls. Disabled when ``isReadOnly`` is true (e.g.
    /// when the bar is mounted on the preview pane).
    let replaceButton: Button
    let replaceAllButton: Button

    /// Wraps the replace row so Ctrl+F can hide it and Ctrl+H can
    /// slide it back in without rebuilding any widgets.
    private let replaceRow: Revealer
    private let replaceRowContent: Box

    /// Current revealed mode. `setVisible(_:mode:)` is the public way
    /// to mutate this — direct property writes don't ripple through
    /// to the Revealer.
    private(set) var mode: Mode = .find

    /// True while AdwSearchBar's search-mode-enabled is on. Reads
    /// through to the underlying widget so external callers don't
    /// have to know about the wrapper.
    var isVisible: Bool {
        get { root.searchModeEnabled }
    }

    /// When true, the replace half is disabled outright — clicks on
    /// the replace buttons do nothing and the row is forced closed
    /// even in `.replace` mode. The preview pane mounts the bar with
    /// this set, since "replace" doesn't make sense against a
    /// rendered view.
    var isReadOnly: Bool = false {
        didSet { applyReadOnlyState() }
    }

    /// Find-entry text. Setting it programmatically does NOT fire
    /// `onQueryChanged` — that's reserved for user input. Callers
    /// that want a programmatic load to re-run the search should
    /// call `notifyQueryChanged()` after assignment.
    var query: String {
        get { findEntry.text }
        set { findEntry.text = newValue }
    }

    var replacement: String {
        get { replaceEntry.text }
        set { replaceEntry.text = newValue }
    }

    /// Snapshot of the three toggle states. Writes mirror back into
    /// the toggle buttons; reads compose the struct on demand.
    var options: SearchOptions {
        get {
            SearchOptions(
                caseSensitive: caseSensitiveToggle.active,
                wholeWord: wholeWordToggle.active,
                regex: regexToggle.active,
            )
        }
        set {
            caseSensitiveToggle.active = newValue.caseSensitive
            wholeWordToggle.active = newValue.wholeWord
            regexToggle.active = newValue.regex
        }
    }

    // MARK: - Callbacks

    /// Fired when the find text changes (debounced via SearchEntry's
    /// own delay) or any of the option toggles flips. Receives the
    /// current query + options so the controller doesn't have to
    /// re-read state on every callback.
    var onQueryChanged: ((String, SearchOptions) -> Void)?

    /// Step to the next / previous match. Default Enter binding on
    /// the find entry maps to `onStepNext`; Shift+Enter to
    /// `onStepPrev`.
    var onStepNext: (() -> Void)?
    var onStepPrev: (() -> Void)?

    /// Replace the currently active match with ``replacement``.
    var onReplaceOne: (() -> Void)?
    /// Replace every match with ``replacement``.
    var onReplaceAll: (() -> Void)?

    /// Fired when AdwSearchBar's search mode transitions to false —
    /// either via the close button GTK draws when
    /// `showCloseButton = true`, or via Escape, or via a programmatic
    /// `setVisible(false, …)`. Controllers use this to drop any
    /// active match highlights.
    var onClose: (() -> Void)?

    init() {
        root = SearchBar()
        root.showCloseButton = true

        findEntry = SearchEntry()
        findEntry.placeholderText = "Find…"
        findEntry.hexpand = true
        findEntry.searchDelay = 0

        caseSensitiveToggle = ToggleButton(label: "Aa")
        caseSensitiveToggle.tooltipText = "Case Sensitive"
        caseSensitiveToggle.addCSSClass(.flat)

        wholeWordToggle = ToggleButton(label: "ab")
        wholeWordToggle.tooltipText = "Whole Word Match"
        wholeWordToggle.addCSSClass(.flat)

        regexToggle = ToggleButton(label: ".*")
        regexToggle.tooltipText = "Regular Expression"
        regexToggle.addCSSClass(.flat)

        countLabel = Label("")
        countLabel.addCSSClass(.dimLabel)
        countLabel.addCSSClass("caption")
        countLabel.marginStart = 4
        countLabel.marginEnd = 4

        prevButton = Button(icon: .custom("go-up-symbolic"))
        prevButton.tooltipText = "Previous Match"
        prevButton.addCSSClass(.flat)

        nextButton = Button(icon: .custom("go-down-symbolic"))
        nextButton.tooltipText = "Next Match"
        nextButton.addCSSClass(.flat)

        replaceEntry = Entry()
        replaceEntry.placeholderText = "Replace…"
        replaceEntry.hexpand = true

        replaceButton = Button(label: "Replace")
        replaceButton.tooltipText = "Replace the current match"

        replaceAllButton = Button(label: "Replace All")
        replaceAllButton.tooltipText = "Replace every match"
        // GNOME convention: Replace All is mutating-without-confirm,
        // so it's not a `suggested-action` (which is reserved for
        // primary positive actions). GNOME Text Editor and Builder
        // both render it as a plain button.

        let findRow = Box(orientation: .horizontal, spacing: 6)
        findRow.append(findEntry)
        findRow.append(caseSensitiveToggle)
        findRow.append(wholeWordToggle)
        findRow.append(regexToggle)
        findRow.append(countLabel)
        findRow.append(prevButton)
        findRow.append(nextButton)

        replaceRowContent = Box(orientation: .horizontal, spacing: 6)
        replaceRowContent.marginTop = 6
        replaceRowContent.append(replaceEntry)
        replaceRowContent.append(replaceButton)
        replaceRowContent.append(replaceAllButton)

        replaceRow = Revealer()
        replaceRow.child = replaceRowContent
        replaceRow.transitionType = GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN
        replaceRow.transitionDuration = 120
        replaceRow.revealChild = false

        let stack = Box(orientation: .vertical, spacing: 0)
        stack.append(findRow)
        stack.append(replaceRow)

        root.child = stack
        root.connectEntry(findEntry)

        wireSignals()
    }

    /// Open the bar in the requested mode (defaults to find-only),
    /// or close it. When opening, the find entry takes focus — same
    /// affordance every GNOME search bar has.
    func setVisible(_ visible: Bool, mode newMode: Mode = .find) {
        if visible {
            mode = newMode
            applyMode()
            root.searchModeEnabled = true
            _ = findEntry.grabFocus()
        } else {
            root.searchModeEnabled = false
            // The Revealer state is owned by `mode` and will be
            // reapplied on the next setVisible call. We leave it
            // alone on close so the slide-down doesn't replay
            // backwards as the whole bar collapses.
        }
    }

    /// Update the "N of M" label. Pass `total = 0` to clear it. The
    /// active index is 1-based for display purposes ("3 of 17") so
    /// callers should pass `currentMatch + 1`.
    func setMatchCount(total: Int, activeDisplayIndex: Int?) {
        guard total > 0 else {
            countLabel.text = ""
            countLabel.visible = false
            return
        }
        if let activeDisplayIndex {
            countLabel.text = "\(activeDisplayIndex) of \(total)"
        } else {
            countLabel.text = "\(total) match\(total == 1 ? "" : "es")"
        }
        countLabel.visible = true
    }

    /// Push externally-known query + options through the callback
    /// path — used when the controller wants to re-run the search
    /// after a buffer mutation but doesn't have any new user input
    /// to react to.
    func notifyQueryChanged() {
        onQueryChanged?(query, options)
    }

    private func applyMode() {
        let shouldShowReplace = (mode == .replace) && !isReadOnly
        replaceRow.revealChild = shouldShowReplace
    }

    private func applyReadOnlyState() {
        replaceButton.sensitive = !isReadOnly
        replaceAllButton.sensitive = !isReadOnly
        replaceEntry.sensitive = !isReadOnly
        if isReadOnly {
            replaceRow.revealChild = false
        } else {
            applyMode()
        }
    }

    private func wireSignals() {
        findEntry.onSearchChanged { [weak self] in
            guard let self else { return }
            onQueryChanged?(query, options)
        }
        findEntry.onActivate { [weak self] in
            self?.onStepNext?()
        }
        // Shift+Enter walks backwards through matches — standard
        // GNOME find-bar behaviour. F3 / Shift+F3 mirror the same
        // step actions because that's what GtkSourceView / GNOME
        // Builder users expect when their hands are off the
        // letter keys.
        findEntry.addKeyboardShortcut("<Shift>Return") { [weak self] in
            self?.onStepPrev?()
            return true
        }
        findEntry.addKeyboardShortcut("<Shift>KP_Enter") { [weak self] in
            self?.onStepPrev?()
            return true
        }
        findEntry.addKeyboardShortcut("F3") { [weak self] in
            self?.onStepNext?()
            return true
        }
        findEntry.addKeyboardShortcut("<Shift>F3") { [weak self] in
            self?.onStepPrev?()
            return true
        }
        caseSensitiveToggle.onToggled { [weak self] in
            self?.notifyQueryChanged()
        }
        wholeWordToggle.onToggled { [weak self] in
            self?.notifyQueryChanged()
        }
        regexToggle.onToggled { [weak self] in
            self?.notifyQueryChanged()
        }
        prevButton.onClicked { [weak self] in
            self?.onStepPrev?()
        }
        nextButton.onClicked { [weak self] in
            self?.onStepNext?()
        }
        replaceButton.onClicked { [weak self] in
            guard let self, !isReadOnly else { return }
            onReplaceOne?()
        }
        replaceAllButton.onClicked { [weak self] in
            guard let self, !isReadOnly else { return }
            onReplaceAll?()
        }
        // AdwSearchBar emits notify::search-mode-enabled whenever its
        // close button is clicked, when Escape closes the bar, or
        // when we toggle it programmatically. The intent of the
        // `onClose` callback is "we're going away" so only fire it
        // on the false-edge.
        root.onSearchModeChanged { [weak self] in
            guard let self, !root.searchModeEnabled else { return }
            onClose?()
        }
    }
}

#if DEBUG
extension FindReplaceBar {
    /// Simulates a user typing into the find entry — fires the
    /// search-changed signal path that drives `onQueryChanged`.
    func debugTypeQuery(_ text: String) {
        findEntry.text = text
        findEntry.emitSearchChanged()
    }

    func debugClickNext()    { onStepNext?() }
    func debugClickPrev()    { onStepPrev?() }
    func debugClickReplace() { replaceButton.emitClicked() }
    func debugClickReplaceAll() { replaceAllButton.emitClicked() }
    func debugToggleCaseSensitive() {
        // gtk_toggle_button_set_active fires the `toggled` signal
        // itself whenever the state actually changes, so we don't
        // need a separate emit call.
        caseSensitiveToggle.active.toggle()
    }
}
#endif
