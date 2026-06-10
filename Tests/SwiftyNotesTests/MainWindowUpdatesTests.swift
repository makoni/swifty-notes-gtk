#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct MainWindowUpdatesTests {
    @MainActor
    private static func makeWindow(
        appID: String,
        forceUpdateAvailable: Bool = false,
        isSandboxedInstall: Bool = false,
        directoryOpener: @escaping (URL) throws -> Void = { _ in },
    ) throws -> MainWindow {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = Application(id: appID)
        try app.register()
        return MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            forceUpdateAvailable: forceUpdateAvailable,
            isSandboxedInstall: isSandboxedInstall,
            directoryOpener: directoryOpener,
        )
    }

    @Test("updateAvailable result shows the banner and records the release URL") @MainActor
    func updateAvailableResultShowsTheBannerAndRecordsTheReleaseURL() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.update.available")
        let releaseURL = URL(string: "https://github.com/makoni/swifty-notes-gtk/releases/tag/v1.2.4")!

        window.handleUpdateCheckResult(.updateAvailable(version: "1.2.4", releaseURL: releaseURL), manual: false)

        #expect(window.updateBanner.isVisible)
        #expect(window.pendingUpdateReleaseURL == releaseURL)
    }

    @Test("upToDate result leaves the banner hidden") @MainActor
    func upToDateResultLeavesTheBannerHidden() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.update.uptodate")

        window.handleUpdateCheckResult(.upToDate, manual: false)

        #expect(!window.updateBanner.isVisible)
        #expect(window.pendingUpdateReleaseURL == nil)
    }

    @Test("Error result leaves the banner hidden") @MainActor
    func errorResultLeavesTheBannerHidden() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.update.error")

        window.handleUpdateCheckResult(.error(message: "network unreachable"), manual: true)

        #expect(!window.updateBanner.isVisible)
        #expect(window.pendingUpdateReleaseURL == nil)
    }

    @Test("Sandboxed launch-check network failure hides Check for Updates from the hamburger menu") @MainActor
    func sandboxedLaunchNetworkFailureHidesMenuItem() throws {
        // Sandboxed installs (Flatpak/Snap default-deny network) fail the
        // launch-time check with "could not resolve host"; the manual menu
        // entry would only ever reproduce that error, so it disappears.
        // Store installs surface updates through the store itself.
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.update.hidemenu",
            isSandboxedInstall: true,
        )
        #expect(window.overflowMenuItemsBySection["Help"]?.contains("Check for Updates…") == true)

        window.handleUpdateCheckResult(.networkUnavailable(message: "Could not resolve host"), manual: false)

        #expect(window.overflowMenuItemsBySection["Help"]?.contains("Check for Updates…") == false)
        // The rest of the menu survives the rebuild.
        #expect(window.overflowMenuItemsBySection["Help"]?.contains("About Swifty Notes") == true)
        #expect(window.overflowMenuItemsBySection["Library"]?.isEmpty == false)
        // The underlying GAction is disabled so future surfaces grey out.
        #expect(window.checkForUpdatesAction.enabled == false)
        // No banner, no toast for a silent launch check.
        #expect(!window.updateBanner.isVisible)
    }

    @Test("Launch-check network failure on a host install keeps the menu item") @MainActor
    func hostInstallLaunchNetworkFailureKeepsMenuItem() throws {
        // A .deb/.rpm/macOS user who happens to be offline at launch (plane
        // mode) is NOT a sandbox — the entry must survive, because for
        // those installs this menu is the only update channel and the
        // network may come back any minute.
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.update.hostoffline",
            isSandboxedInstall: false,
        )

        window.handleUpdateCheckResult(.networkUnavailable(message: "offline at launch"), manual: false)

        #expect(window.overflowMenuItemsBySection["Help"]?.contains("Check for Updates…") == true)
        #expect(window.checkForUpdatesAction.enabled == true)
        #expect(!window.updateBanner.isVisible)
    }

    @Test("Manual network failure keeps the menu item so a transient outage is retryable") @MainActor
    func manualNetworkFailureKeepsMenuItem() throws {
        // Even in a sandbox, a manual click that fails offline only shows
        // a toast — hiding is reserved for the silent launch probe.
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.update.manualnet",
            isSandboxedInstall: true,
        )

        window.handleUpdateCheckResult(.networkUnavailable(message: "offline"), manual: true)

        #expect(window.overflowMenuItemsBySection["Help"]?.contains("Check for Updates…") == true)
        #expect(!window.updateBanner.isVisible)
    }

    @Test("Non-network launch error keeps the menu item even in a sandbox") @MainActor
    func nonNetworkLaunchErrorKeepsMenuItem() throws {
        // GitHub being down (HTTP 5xx) means the network IS reachable —
        // even inside a sandbox with network permission granted, the
        // manual entry stays useful.
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.update.httperror",
            isSandboxedInstall: true,
        )

        window.handleUpdateCheckResult(.error(message: "GitHub returned HTTP 500"), manual: false)

        #expect(window.overflowMenuItemsBySection["Help"]?.contains("Check for Updates…") == true)
    }

    @Test("Update button opens the release URL through the injected opener") @MainActor
    func updateButtonOpensTheReleaseURLThroughTheInjectedOpener() throws {
        let openedURL = URLRecorder()
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.update.openrelease",
            directoryOpener: { url in
                openedURL.set(url)
            },
        )
        let releaseURL = URL(string: "https://github.com/makoni/swifty-notes-gtk/releases/tag/v9.9.9")!
        window.handleUpdateCheckResult(.updateAvailable(version: "9.9.9", releaseURL: releaseURL), manual: false)

        window.openPendingUpdateReleasePage()

        #expect(openedURL.snapshot() == releaseURL)
    }

    @Test("Update button is a no-op before any successful check has stored a URL") @MainActor
    func updateButtonIsANoOpBeforeAnySuccessfulCheckHasStored() throws {
        let openedURL = URLRecorder()
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.update.openrelease.nil",
            directoryOpener: { url in
                openedURL.set(url)
            },
        )

        window.openPendingUpdateReleasePage()

        #expect(openedURL.snapshot() == nil)
    }

    @Test("Force-update-available flag promotes equal remote version into updateAvailable via handleUpdateCheckResult") @MainActor
    func forceUpdateAvailableFlagPromotesEqualRemoteVersionIntoUpdateAvailableViaHandleUpdateCheckResult() throws {
        // The force-flag end-to-end path is already covered by
        // UpdateCheckerTests; here we just confirm the MainWindow
        // surface mirrors that outcome — given an `updateAvailable`
        // result (which is what UpdateChecker hands back under the
        // force flag), the banner reveals and the URL is recorded.
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.update.forceflag",
            forceUpdateAvailable: true,
        )
        let releaseURL = URL(string: "https://github.com/makoni/swifty-notes-gtk/releases/tag/v0.0.1")!

        window.handleUpdateCheckResult(.updateAvailable(version: "0.0.1", releaseURL: releaseURL), manual: false)

        #expect(window.updateBanner.isVisible)
        #expect(window.pendingUpdateReleaseURL == releaseURL)
    }
}
#endif
