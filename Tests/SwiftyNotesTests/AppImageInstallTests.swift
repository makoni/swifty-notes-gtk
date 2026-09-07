#if !os(macOS)
import Foundation
@testable import SwiftyNotes
import Testing

/// The half of the AppImage update path that can be decided without running
/// anything: whether this process is an AppImage, and whether an updater is
/// installed to hand it to.
@Suite("AppImage install detection")
struct AppImageInstallTests {
    @Test("A running AppImage is recognised from APPIMAGE")
    func runningAppImageIsRecognisedFromAppImageVariable() {
        let path = AppImageInstall.detectBundlePath(
            environment: ["APPIMAGE": "/home/user/Apps/swifty-notes-gtk-1.5.0-x86_64.AppImage"],
            isReadableFile: { $0 == "/home/user/Apps/swifty-notes-gtk-1.5.0-x86_64.AppImage" },
        )
        #expect(path == "/home/user/Apps/swifty-notes-gtk-1.5.0-x86_64.AppImage")
    }

    /// `APPIMAGE` is an ordinary environment variable. A process launched *by*
    /// an AppImage inherits it, so a system install started from an AppImage's
    /// terminal would otherwise offer to update a file it is not running from.
    @Test("A stale or missing APPIMAGE path is not an AppImage install")
    func staleOrMissingAppImagePathIsNotAnAppImageInstall() {
        #expect(AppImageInstall.detectBundlePath(environment: [:], isReadableFile: { _ in true }) == nil)
        #expect(AppImageInstall.detectBundlePath(
            environment: ["APPIMAGE": "/gone/swifty.AppImage"],
            isReadableFile: { _ in false },
        ) == nil)
        // Relative paths cannot be what the runtime exported, and resolving one
        // would depend on a working directory this process does not control.
        #expect(AppImageInstall.detectBundlePath(
            environment: ["APPIMAGE": "swifty.AppImage"],
            isReadableFile: { _ in true },
        ) == nil)
        #expect(AppImageInstall.detectBundlePath(
            environment: ["APPIMAGE": ""],
            isReadableFile: { _ in true },
        ) == nil)
    }

    @Test("The updater is searched along PATH, in preference order")
    func updaterIsSearchedAlongPathInPreferenceOrder() {
        let both = AppImageInstall.updaterExecutable(
            environment: ["PATH": "/usr/local/bin:/usr/bin"],
            isExecutableFile: { $0 == "/usr/bin/appimageupdatetool" || $0 == "/usr/bin/AppImageUpdate" },
        )
        #expect(both == "/usr/bin/appimageupdatetool")

        // The GUI alone is enough: it takes the same bundle argument.
        let guiOnly = AppImageInstall.updaterExecutable(
            environment: ["PATH": "/usr/bin"],
            isExecutableFile: { $0 == "/usr/bin/AppImageUpdate" },
        )
        #expect(guiOnly == "/usr/bin/AppImageUpdate")

        // Earlier PATH entries win, which is what a shell would do.
        let earlier = AppImageInstall.updaterExecutable(
            environment: ["PATH": "/opt/bin:/usr/bin"],
            isExecutableFile: { $0.hasSuffix("/appimageupdatetool") },
        )
        #expect(earlier == "/opt/bin/appimageupdatetool")
    }

    /// No updater is the common case — AppImageUpdate ships by default
    /// nowhere — and it has to be reported as absent rather than guessed at,
    /// because the caller falls back to the release page on `nil`.
    @Test("No updater on PATH reports none")
    func noUpdaterOnPathReportsNone() {
        #expect(AppImageInstall.updaterExecutable(
            environment: ["PATH": "/usr/bin:/bin"],
            isExecutableFile: { _ in false },
        ) == nil)
        // Relative PATH entries are skipped rather than joined blindly.
        #expect(AppImageInstall.updaterExecutable(
            environment: ["PATH": "bin:."],
            isExecutableFile: { _ in true },
        ) == nil)
    }

    @Test("The update removes the superseded bundle")
    func updateRemovesTheSupersededBundle() {
        let arguments = AppImageInstall.updateArguments(bundlePath: "/apps/swifty.AppImage")
        #expect(arguments == ["--remove-old", "/apps/swifty.AppImage"])
    }
}
#endif
