import Adwaita
import Foundation

/// The divider between the editor and the preview in Split mode, for the
/// main window and an opened file's window alike: it attaches and detaches
/// the preview, slides it in and out, puts the divider where the preview
/// gets the width the window remembers, and remembers the width the user
/// drags it to.
///
/// GtkPaned shifts the divider by whatever width change it missed while the
/// preview was detached (a sidebar or the Outline toggled in Editor mode),
/// so after the preview comes back the divider is set again once the pane
/// has been laid out and its width holds still. Moves made meanwhile are
/// layout, not the user's, and are not remembered.
@MainActor
final class PreviewPaneDivider {
    /// What the divider needs from its window.
    struct Host {
        /// The room the editor and preview share: the pane's width once
        /// allocated, an estimate before.
        var roomWidth: () -> Int
        /// Whether the window shows Split mode.
        var isSplit: () -> Bool
        var preferredPreviewWidth: () -> Int
        var setPreferredPreviewWidth: (Int) -> Void
        /// The divider moved; the editor (its toolbar) is this wide now.
        var editorWidthChanged: (Int) -> Void
    }

    let pane: Paned
    private let previewContent: Widget
    private var host: Host

    private(set) var isPreviewAttached = false
    /// The divider is being placed or animated, not dragged.
    private(set) var isRestoring = false
    private var animationID: SourceID?
    private var settleTickID: UInt?
    private var settleGeneration = 0

    init(pane: Paned, previewContent: Widget, host: Host) {
        self.pane = pane
        self.previewContent = previewContent
        self.host = host
        pane.onPositionChanged { [weak self] in
            self?.handleMoved()
        }
        // Grabbing the handle while a settle is under way hands the
        // divider to the user at once.
        let drag = GestureDrag()
        drag.propagationPhase = .capture
        drag.onDragBegin { [weak self] x, _ in
            self?.pointerPressed(atX: x)
        }
        pane.addController(drag)
    }

    /// A press at `x` in the pane: on the handle while a settle is under
    /// way, the divider is the user's from now on.
    func pointerPressed(atX x: Double) {
        guard settleTickID != nil, abs(x - Double(pane.position)) <= 12 else { return }
        cancelSettle()
        isRestoring = false
    }

    // MARK: - Showing the preview

    /// Attaches the preview and places the divider; `animated` slides it in.
    func show(animated: Bool) {
        attach()
        if animated, canAnimate {
            let room = host.roomWidth()
            let target = position(forRoom: room)
            pane.position = room
            animate(to: target)
            return
        }
        restore()
    }

    /// Takes the preview away; `animated` slides it out first.
    func hide(animated: Bool) {
        guard isPreviewAttached else { return }
        guard animated, canAnimate else {
            detach()
            return
        }
        animate(to: host.roomWidth())
    }

    /// Puts the divider where the preview gets its remembered width, and
    /// again once the layout has settled.
    func restore() {
        guard host.isSplit() else { return }
        isRestoring = true
        let position = position(forRoom: host.roomWidth())
        pane.position = position
        host.editorWidthChanged(position)
        settle()
    }

    func attach() {
        guard !isPreviewAttached else { return }
        pane.endChild = previewContent
        isPreviewAttached = true
    }

    func detach() {
        guard isPreviewAttached else { return }
        stopAnimation()
        pane.endChild = nil
        isPreviewAttached = false
    }

    /// Stops a slide or a settle under way.
    func stopAnimation() {
        cancelSettle()
        if let animationID {
            MainContext.cancel(sourceId: animationID)
            self.animationID = nil
        }
    }

    // MARK: - Position

    /// Where the divider goes in `room` for the remembered preview width;
    /// the editor keeps its minimum.
    func position(forRoom room: Int) -> Int {
        let stored = host.preferredPreviewWidth()
        let previewWidth = MainWindow.resolvedPreviewWidth(storedWidth: stored, availableWidth: room)
        // The old default grows into the comfortable width once.
        if stored == WorkspaceState.legacyDefaultPreviewWidth, previewWidth > stored {
            host.setPreferredPreviewWidth(previewWidth)
        }
        return max(room - previewWidth, MainWindow.minimumEditorWidth)
    }

    /// The editor's width with the preview at its remembered width.
    func editorWidth(forRoom room: Int) -> Int {
        let previewWidth = MainWindow.resolvedPreviewWidth(storedWidth: host.preferredPreviewWidth(), availableWidth: room)
        return max(room - previewWidth, MainWindow.minimumEditorWidth)
    }

    private var canAnimate: Bool {
        pane.parent != nil && pane.width > 0 && pane.height > 0
    }

    private func place(at position: Int) {
        guard pane.position != position else { return }
        pane.position = position
        host.editorWidthChanged(position)
    }

    /// A move the user made: remember the preview's width.
    private func handleMoved() {
        guard host.isSplit(), isPreviewAttached, !isRestoring else { return }
        let room = host.roomWidth()
        guard room >= MainWindow.minimumPreviewWidth + MainWindow.minimumEditorWidth else { return }
        let previewWidth = room - pane.position
        guard previewWidth >= MainWindow.minimumPreviewWidth else { return }
        host.setPreferredPreviewWidth(previewWidth)
        host.editorWidthChanged(pane.position)
    }

    /// Sets the divider again each frame until the room holds still (a
    /// sidebar sliding in or out has stopped), or for about a second.
    private func settle() {
        cancelSettle()
        // A newer settle owns the restoring flag from here on.
        settleGeneration += 1
        let generation = settleGeneration
        var frames = 0
        var lastWidth = -1
        var steadyFrames = 0
        settleTickID = pane.addTickCallback { [weak self] in
            guard let self else { return false }
            frames += 1
            let width = pane.width
            steadyFrames = width == lastWidth ? steadyFrames + 1 : 0
            lastWidth = width
            guard frames >= 2 else { return true }
            place(at: position(forRoom: host.roomWidth()))
            guard steadyFrames < 3, frames < 60 else {
                settleTickID = nil
                // After the layout that follows the last placement.
                MainContext.idle { [weak self] in
                    guard let self, generation == settleGeneration else { return }
                    isRestoring = false
                }
                return false
            }
            return true
        }
    }

    private func cancelSettle() {
        if let settleTickID {
            pane.removeTickCallback(settleTickID)
            self.settleTickID = nil
        }
    }

    private func animate(to target: Int) {
        stopAnimation()
        let start = pane.position
        guard start != target else {
            isRestoring = false
            detachSoonUnlessSplit()
            return
        }
        isRestoring = true
        let startedAt = Date()
        let duration = Double(MainWindow.previewAnimationDuration) / 1000
        animationID = MainContext.timeout(every: .milliseconds(16)) { [weak self] in
            guard let self else { return false }
            let progress = min(max(Date().timeIntervalSince(startedAt) / duration, 0), 1)
            let eased = 1 - pow(1 - progress, 3)
            pane.position = Int((Double(start) + Double(target - start) * eased).rounded())
            guard progress >= 1 else { return true }
            animationID = nil
            isRestoring = false
            detachSoonUnlessSplit()
            return false
        }
    }

    /// After sliding out, the preview leaves once the mode is no longer
    /// Split.
    private func detachSoonUnlessSplit() {
        guard !host.isSplit() else { return }
        MainContext.delay(for: .milliseconds(1)) { [weak self] in
            guard let self, !host.isSplit() else { return }
            detach()
        }
    }
}
