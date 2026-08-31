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
public func initializeLocalization(language: AppLanguage = .system) {
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
    AppLocalizationState.captureSessionLanguage()
    _ = applyLanguage(language)
}

/// The session's own `LANGUAGE`, captured before the app ever overrides it.
///
/// Selecting ``AppLanguage.system`` has to put back what the session asked
/// for, which is unrecoverable once the picker has assigned its own value.
enum AppLocalizationState {
    nonisolated(unsafe) private static var sessionLanguage: String?
    nonisolated(unsafe) private static var didCaptureSessionLanguage = false

    static func captureSessionLanguage() {
        guard !didCaptureSessionLanguage else { return }
        didCaptureSessionLanguage = true
        sessionLanguage = ProcessInfo.processInfo.environment["LANGUAGE"]
    }

    static var capturedSessionLanguage: String? {
        sessionLanguage
    }

    #if DEBUG
        /// Lets a test start from a known session, since the capture is
        /// deliberately one-shot in the app.
        static func resetForTesting(sessionLanguage: String?) {
            didCaptureSessionLanguage = true
            self.sessionLanguage = sessionLanguage
        }
    #endif
}

/// Whether this build can change the interface language without a restart.
///
/// False only where libintl does not export the catalogue-cache counter; the
/// preference is still recorded and takes effect at the next launch.
public func canSwitchLanguageAtRuntime() -> Bool {
    swifty_notes_can_switch_language_at_runtime() != 0
}

/// Points gettext at `language` and drops its cached catalogue.
///
/// `LANGUAGE` is the only lever that selects a catalogue independently of the
/// locale, and gettext reads it once per catalogue load — hence the cache
/// invalidation. The catch is that gettext ignores `LANGUAGE` completely while
/// `LC_MESSAGES` is `C`, `POSIX` or `C.UTF-8`, so a session started without a
/// locale needs one installed first; any generated locale will do, which is
/// why the candidates are not limited to the requested language's own.
///
/// - Returns: `true` when subsequent lookups will use `language`. `false`
///   means the session locale is `C` and no candidate locale is generated on
///   this machine — in which case nothing is translated at all, with or
///   without a picker.
@discardableResult
public func applyLanguage(_ language: AppLanguage) -> Bool {
    guard let code = language.catalogueCode else {
        // Follow the session again: restore the LANGUAGE it was started with.
        if let sessionLanguage = AppLocalizationState.capturedSessionLanguage {
            setEnvironmentVariable("LANGUAGE", sessionLanguage)
        } else {
            unsetEnvironmentVariable("LANGUAGE")
        }
        swifty_notes_invalidate_translation_cache()
        return true
    }

    let escapedCLocale = ensureMessagesLocaleIsNotC(candidates: language.messagesLocaleCandidates)
    setEnvironmentVariable("LANGUAGE", code)
    swifty_notes_invalidate_translation_cache()
    return escapedCLocale
}

/// Language codes with a catalogue installed next to the running build.
///
/// English is absent by design: it is the msgid language and ships no `.mo`.
public func installedCatalogueLanguages() -> Set<String> {
    guard let localeDir = localeDirectoryPath(),
          let entries = try? FileManager.default.contentsOfDirectory(
              at: URL(fileURLWithPath: localeDir, isDirectory: true),
              includingPropertiesForKeys: nil,
          )
    else {
        return []
    }

    return Set(
        entries.filter { entry in
            FileManager.default.fileExists(
                atPath: entry
                    .appendingPathComponent("LC_MESSAGES", isDirectory: true)
                    .appendingPathComponent("me.spaceinbox.swiftynotes.mo", isDirectory: false)
                    .path,
            )
        }.map(\.lastPathComponent),
    )
}

/// Installs a locale that gettext will honour `LANGUAGE` under.
///
/// Returns `true` when `LC_MESSAGES` already names a real locale, or when one
/// of `candidates` could be installed.
private func ensureMessagesLocaleIsNotC(candidates: [String]) -> Bool {
    if let current = swifty_notes_current_messages_locale(),
       !isCLocale(String(cString: current)) {
        return true
    }

    for candidate in candidates {
        if let applied = candidate.withCString({ swifty_notes_set_messages_locale($0) }),
           !isCLocale(String(cString: applied)) {
            return true
        }
    }
    return false
}

/// `C.UTF-8` counts as the C locale for gettext's purposes: it suppresses
/// `LANGUAGE` exactly as bare `C` does.
private func isCLocale(_ locale: String) -> Bool {
    let name = locale.split(separator: ".").first.map(String.init) ?? locale
    return name == "C" || name == "POSIX"
}

private func setEnvironmentVariable(_ name: String, _ value: String) {
    name.withCString { nameC in
        value.withCString { valueC in
            _ = setenv(nameC, valueC, 1)
        }
    }
}

private func unsetEnvironmentVariable(_ name: String) {
    name.withCString { nameC in
        _ = unsetenv(nameC)
    }
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
