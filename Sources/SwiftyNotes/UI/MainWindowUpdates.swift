import Adwaita
import Foundation

extension MainWindow {
    /// Default fetcher used at runtime — hits the GitHub releases API
    /// for `makoni/swifty-notes-gtk`. Tests inject their own closure via
    /// the `fetcher` parameter on ``checkForUpdates(manual:fetcher:)``.
    static let defaultUpdateFetcher: @Sendable () async throws -> GitHubLatestRelease =
        UpdateChecker.gitHubReleasesFetcher(
            owner: "makoni",
            repo: "swifty-notes-gtk",
        )

    /// Kicks off an async update check and updates the banner / toast on
    /// completion. `manual` controls how feedback is surfaced for
    /// non-update outcomes: silent on launch checks, but a toast for the
    /// "Check for Updates…" menu action so the user gets confirmation
    /// that the click did something.
    func checkForUpdates(
        manual: Bool,
        fetcher: @escaping @Sendable () async throws -> GitHubLatestRelease = MainWindow.defaultUpdateFetcher,
    ) {
        let checker = UpdateChecker(
            currentVersion: BuildInfo.version,
            forceUpdateAvailable: forceUpdateAvailable,
            fetchLatestRelease: fetcher,
        )
        // Detached so the body runs on the global cooperative pool
        // instead of inheriting MainActor. GTK blocks the main thread
        // inside `g_main_loop_run`, which means a MainActor-isolated
        // Task never gets scheduled — the launch-time check would sit
        // queued forever. Hop back onto the GLib loop via
        // `MainContext.idle` to touch widgets safely.
        //
        // The handler is built here on the MainActor and captures
        // `[weak self]` from MainActor context. Because it's a
        // `@MainActor`-isolated closure value, Swift 6 strict
        // concurrency lets us send it into the detached Task without
        // crossing isolation on `self` itself.
        let handle: @MainActor @Sendable (UpdateCheckResult) -> Void = { [weak self] result in
            self?.handleUpdateCheckResult(result, manual: manual)
        }
        Task.detached {
            let result = await checker.check()
            MainContext.idle {
                handle(result)
            }
        }
    }

    func handleUpdateCheckResult(_ result: UpdateCheckResult, manual: Bool) {
        switch result {
        case let .updateAvailable(version, releaseURL):
            pendingUpdateReleaseURL = releaseURL
            updateBanner.show(version: version)
        case .upToDate:
            if manual {
                toastOverlay.addToast(Toast(title: "Swifty Notes is up to date.".localized))
            }
        case let .error(message):
            if manual {
                toastOverlay.addToast(Toast(title: String(format: "Could not check for updates: %@".localized, message)))
            }
        case .networkUnavailable:
            if manual {
                // A transient outage on a network-capable install: keep the
                // raw NSURLError soup out of the toast, keep the menu entry
                // so the user can retry once they're back online.
                toastOverlay.addToast(Toast(title: "Could not check for updates: no internet connection.".localized))
            } else if isSandboxedInstall {
                // The silent launch probe couldn't reach the network AND we
                // are provably inside a Flatpak/Snap sandbox — the combination
                // that means a manual check could only ever reproduce the
                // same error (our store builds ship without network
                // permission). Drop the menu entry; the store surfaces
                // updates itself. The sandbox gate keeps a merely-offline
                // .deb/.rpm/macOS launch (plane mode) from losing the entry
                // for the whole session.
                hideCheckForUpdatesMenuItem()
            }
        }
    }

    func hideCheckForUpdatesMenuItem() {
        guard !updateCheckMenuItemHidden else { return }
        updateCheckMenuItemHidden = true
        // Disable the underlying GAction too, so any future surface that
        // binds `win.check-for-updates` without knowing about this flag
        // shows it greyed-out instead of raising the unreachable error.
        checkForUpdatesAction.enabled = false
        rebuildOverflowMenu()
    }

    func openPendingUpdateReleasePage() {
        guard let url = pendingUpdateReleaseURL else { return }
        do {
            try directoryOpener(url)
        } catch {
            toastOverlay.addToast(Toast(title: String(format: "Could not open release page: %@".localized, error.localizedDescription)))
        }
    }
}
