import Foundation

enum BuildInfo {
    private static let defaultVersion = "1.1.7"

    /// Source of truth resolution order:
    /// 1. `SWIFTY_NOTES_VERSION` env var — Linux release flow exports
    ///    this via `packaging/release/install-user.sh`, and developers
    ///    can override locally for testing the update checker.
    /// 2. `CFBundleShortVersionString` from the surrounding .app's
    ///    Info.plist — CI passes `MARKETING_VERSION` to xcodebuild for
    ///    the macOS release pipeline, so the bundle is the authoritative
    ///    version source there. Without this step the in-app About /
    ///    update-checker would read `defaultVersion` even when the .app
    ///    itself was correctly stamped, leading to inconsistent UI
    ///    versus the Finder Get Info value.
    /// 3. `defaultVersion` for unbundled `swift run` developer builds
    ///    where neither of the above is set.
    static var version: String {
        if let env = ProcessInfo.processInfo.environment["SWIFTY_NOTES_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return env
        }
        // Only consult `Bundle.main` when it actually IS the Swifty
        // Notes bundle — i.e. running inside the macOS `.app`. xctest
        // harnesses and `swift test` runners also give us a
        // `Bundle.main`, but its `CFBundleShortVersionString` is the
        // test runner's version (or empty), not ours; without the
        // identifier guard those processes would silently return a
        // bogus version and break the About-dialog snapshot tests.
        if Bundle.main.bundleIdentifier == AppIdentity.identifier,
           let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        {
            let trimmed = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return defaultVersion
    }
}
