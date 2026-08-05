import Adwaita
import Foundation
import CSpelling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Sets up gettext localization for the application.
///
/// Must be called once, before any `.localized` calls, in both the GUI
/// and CLI entry points. Activates the process locale from environment
/// (LC_ALL / LANG), sets the text domain, and binds the locale directory
/// so that `swift-adwaita`'s `localized(_:)` and `String.localized`
/// can find `.mo` translation files.
public func initializeLocalization() {
    // Activate the process locale from environment. `nil` only queries
    // the locale; `""` sets it from the environment variables.
    // Import Darwin or Glibc above so setlocale/LC_ALL resolve on both.
    _ = setlocale(LC_ALL, "")
    // Set the gettext text domain. Must match the app ID used in
    // .desktop files and Flatpak manifests.
    swifty_notes_textdomain("me.spaceinbox.swiftynotes")
    if let localeDir = localeDirectoryPath() {
        swifty_notes_bindtextdomain("me.spaceinbox.swiftynotes", localeDir)
    }
    _ = swifty_notes_bind_textdomain_codeset("me.spaceinbox.swiftynotes", "UTF-8")
}

/// Resolves the directory containing `.mo` translation files.
///
/// Priority:
/// 1. `SWIFTY_NOTES_LOCALE_DIR` env var (testing / debugging)
/// 2. Flatpak: `/app/share/locale`
/// 3. macOS bundle: `<App>.app/Contents/Resources/locale`
/// 4. SwiftPM dev build: `<project>/locale` (next to Resources/)
/// 5. System: `/usr/share/locale`
public func localeDirectoryPath() -> String? {
    // 1. Env var override
    if let envPath = ProcessInfo.processInfo.environment["SWIFTY_NOTES_LOCALE_DIR"],
       FileManager.default.fileExists(atPath: envPath),
       localeDirectoryContainsCatalog(envPath) {
        return envPath
    }

    // 2. Flatpak
    if FileManager.default.fileExists(atPath: "/app/share/locale"),
       localeDirectoryContainsCatalog("/app/share/locale") {
        return "/app/share/locale"
    }

    // 3. macOS bundle — locale files sit in <App>.app/Contents/Resources/locale
    #if os(macOS)
    let bundleLocale = Bundle.main.bundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("locale", isDirectory: true)
    if FileManager.default.fileExists(atPath: bundleLocale.path),
       localeDirectoryContainsCatalog(bundleLocale.path) {
        return bundleLocale.path
    }
    #endif

    // 4. SwiftPM dev build — `.copy("locale")` preserves the
    //    ru/LC_MESSAGES/<domain>.mo layout gettext needs.
    if let bundleResourceURL = Bundle.module.resourceURL {
        let localeDir = bundleResourceURL.appendingPathComponent("locale")
        if localeDirectoryContainsCatalog(localeDir.path) {
            return localeDir.path
        }
    }

    // 5. System
    let systemLocale = "/usr/share/locale"
    if localeDirectoryContainsCatalog(systemLocale) {
        return systemLocale
    }

    return nil
}

/// Returns `true` if `path` contains a gettext catalogue for this app,
/// i.e. `<path>/<lang>/LC_MESSAGES/me.spaceinbox.swiftynotes.mo` exists
/// for at least one `<lang>` subdirectory.
public func localeDirectoryContainsCatalog(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path),
          let subdirs = try? FileManager.default.contentsOfDirectory(
              at: URL(fileURLWithPath: path),
              includingPropertiesForKeys: nil
          ) else {
        return false
    }

    for subdir in subdirs {
        let lang = subdir.path
        let expected = URL(fileURLWithPath: lang)
            .appendingPathComponent("LC_MESSAGES", isDirectory: true)
            .appendingPathComponent("me.spaceinbox.swiftynotes.mo", isDirectory: false)
        if FileManager.default.fileExists(atPath: expected.path) {
            return true
        }
    }
    return false
}
