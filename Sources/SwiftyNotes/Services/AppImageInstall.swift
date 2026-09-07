import Foundation

/// Whether this process is a running AppImage, and how it can update itself.
///
/// Deliberately not part of ``AppSandbox``: that answers "is this process
/// confined", and an AppImage is not — it is an unconfined self-mounting
/// archive. What it *is* is relocatable and self-contained, which is what
/// makes an in-place update possible at all.
///
/// The release build publishes a `.zsync` delta file beside each AppImage and
/// embeds `gh-releases-zsync|…` update information in the bundle. Together
/// those let an AppImage updater fetch only the changed blocks of the next
/// release and swap the file in place, which is a better answer for an
/// AppImage user than "here is the download page". This type is the detection
/// half; the updater itself is somebody else's binary, deliberately, because
/// rewriting a running executable is a job for the tool built to do it.
enum AppImageInstall {
    /// Candidate updater executables, in the order they are preferred.
    ///
    /// `appimageupdatetool` is the CLI from the AppImageUpdate project and the
    /// one that takes a bundle path as its argument. `AppImageUpdate` is the
    /// same project's GUI, which accepts the same argument and is what a
    /// desktop user is more likely to have installed.
    static let updaterExecutableNames = ["appimageupdatetool", "AppImageUpdate"]

    /// Absolute path of the running AppImage, or `nil` when this is not one.
    static let bundlePath: String? = detectBundlePath(
        environment: ProcessInfo.processInfo.environment,
        isReadableFile: { FileManager.default.isReadableFile(atPath: $0) },
    )

    /// Pure decision core, injectable for tests.
    ///
    /// The type-2 runtime exports `APPIMAGE` with the absolute path of the
    /// bundle before it execs `AppRun`. The path is checked rather than
    /// trusted: `APPIMAGE` is an ordinary environment variable that anything
    /// could set, and a stale one — inherited from a parent that *was* an
    /// AppImage — would otherwise make a system install look updatable.
    static func detectBundlePath(
        environment: [String: String],
        isReadableFile: (String) -> Bool,
    ) -> String? {
        guard let path = environment["APPIMAGE"], path.hasPrefix("/"), isReadableFile(path) else {
            return nil
        }
        return path
    }

    /// The updater to run, searched along `PATH` the way a shell would.
    ///
    /// Returns `nil` when no updater is installed, which is the common case:
    /// AppImageUpdate is not shipped by default anywhere. The caller falls
    /// back to opening the release page, which is what every other install
    /// kind does.
    static func updaterExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    ) -> String? {
        let searchPath = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            guard directory.hasPrefix("/") else { continue }
            for name in updaterExecutableNames {
                let candidate = "\(directory)/\(name)"
                if isExecutableFile(candidate) { return candidate }
            }
        }
        return nil
    }

    /// How to invoke `updater` against `bundle`.
    ///
    /// `--remove-old` is deliberate: without it the updater leaves the
    /// previous release behind as `<name>.zs-old`, and a user who updates a
    /// few times ends up with a directory of stale AppImages they did not ask
    /// for. The updater still writes the new file before removing the old one,
    /// so an interrupted update leaves the working copy in place.
    static func updateArguments(bundlePath: String) -> [String] {
        ["--remove-old", bundlePath]
    }
}
