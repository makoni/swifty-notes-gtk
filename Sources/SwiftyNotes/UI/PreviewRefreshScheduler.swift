import Adwaita
import Foundation

/// Coalesces "preview needs to redraw" signals into a single render call.
///
/// The editor can fire a change every keystroke; running a fresh
/// markdown render against ``MarkdownPreview`` for each one is wasteful
/// and visibly janky. ``PreviewRefreshScheduler`` debounces those
/// signals through the GLib main loop and also defers rendering while
/// the preview surface is hidden / unrealized — when it becomes visible
/// again the scheduler retries until the surface is ready.
///
/// Both ``MainWindow`` and ``ExternalDocumentWindow`` consume this so
/// refresh / debounce logic lives in one place. Render work is invoked
/// through closures, which keeps the scheduler decoupled from the
/// concrete `MarkdownPreview` widget and makes it unit-testable.
@MainActor
final class PreviewRefreshScheduler {
    private var pendingBlocks: [RenderedBlock]?
    private var pendingBaseDirectory: URL?
    private var refreshID: SourceID?
    private var retryID: SourceID?

    private let render: ([RenderedBlock], URL) -> Void
    private let fallbackBaseDirectory: () -> URL
    private let shouldDeferRender: () -> Bool
    private let onRendered: () -> Void

    /// - Parameters:
    ///   - render: Performs the actual preview render once a flush is
    ///     ready to commit. Receives the freshest rendered blocks and
    ///     the base directory that relative image paths should resolve
    ///     against.
    ///   - fallbackBaseDirectory: Supplies a base directory if a flush
    ///     fires without a buffered one (for example when ``flush()``
    ///     is called manually for layout reasons rather than after
    ///     ``schedule(blocks:baseDirectory:)``).
    ///   - shouldDeferRender: Returns `true` when the preview surface
    ///     is not ready yet (hidden, unallocated, detached). The
    ///     scheduler will park the pending render and retry after
    ///     ``Self.retryIntervalMs`` until this returns `false`.
    ///   - onRendered: Hook invoked from the main loop after each
    ///     successful render — used to keep editor / preview scroll
    ///     positions in sync.
    init(
        render: @escaping ([RenderedBlock], URL) -> Void,
        fallbackBaseDirectory: @escaping () -> URL,
        shouldDeferRender: @escaping () -> Bool,
        onRendered: @escaping () -> Void = {},
    ) {
        self.render = render
        self.fallbackBaseDirectory = fallbackBaseDirectory
        self.shouldDeferRender = shouldDeferRender
        self.onRendered = onRendered
    }

    static let scheduleIntervalMs: UInt32 = 1
    static let retryIntervalMs: UInt32 = 16

    /// Buffers a new render request and schedules a debounced flush.
    /// Cancels any in-flight scheduled flush so only the latest set of
    /// blocks reaches ``render``.
    func schedule(blocks: [RenderedBlock], baseDirectory: URL) {
        cancelRefreshTimer()
        pendingBlocks = blocks
        pendingBaseDirectory = baseDirectory
        refreshID = MainContext.timeout(intervalMs: Self.scheduleIntervalMs) { [weak self] in
            guard let self else { return false }
            flush()
            return false
        }
    }

    /// Forces an immediate render of whatever is buffered. Honors
    /// ``shouldDeferRender`` and parks the work for retry if the
    /// preview surface is not ready.
    func flush() {
        guard refreshID != nil || pendingBlocks != nil || pendingBaseDirectory != nil else {
            return
        }
        cancelRefreshTimer()
        if shouldDeferRender() {
            scheduleRetryIfNeeded()
            return
        }
        cancelRetryTimer()
        let blocks = pendingBlocks ?? []
        let baseDirectory = pendingBaseDirectory ?? fallbackBaseDirectory()
        pendingBlocks = nil
        pendingBaseDirectory = nil
        render(blocks, baseDirectory)
        MainContext.idle { [weak self] in
            self?.onRendered()
        }
    }

    /// Drops any buffered render and stops scheduled / retry timers.
    /// Useful when tearing the window down so callbacks don't fire
    /// against destroyed widgets.
    func cancel() {
        cancelRefreshTimer()
        cancelRetryTimer()
        pendingBlocks = nil
        pendingBaseDirectory = nil
    }

    private func cancelRefreshTimer() {
        if let refreshID {
            MainContext.cancel(sourceId: refreshID)
            self.refreshID = nil
        }
    }

    private func cancelRetryTimer() {
        if let retryID {
            MainContext.cancel(sourceId: retryID)
            self.retryID = nil
        }
    }

    private func scheduleRetryIfNeeded() {
        guard retryID == nil else { return }
        retryID = MainContext.timeout(intervalMs: Self.retryIntervalMs) { [weak self] in
            guard let self else { return false }
            retryID = nil
            flush()
            return false
        }
    }
}
