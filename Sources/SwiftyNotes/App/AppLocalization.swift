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
    // swift-adwaita owns the gettext plumbing: activating the locale from the
    // environment, binding the domain to the catalogue directory, pinning the
    // codeset, and capturing the session's own LANGUAGE so "follow the
    // system" stays recoverable.
    configureLocalization(
        domain: AppIdentity.identifier,
        localeDirectory: localeDirectoryPath(),
    )
    applyLanguage(language)
}

/// Whether this build can change the interface language without a restart.
///
/// False only where libintl does not export the catalogue-cache counter; the
/// preference is still recorded and takes effect at the next launch.
public func canSwitchLanguageAtRuntime() -> Bool {
    canChangeLanguageAtRuntime
}

/// Points the interface at `language`: translations *and* layout.
///
/// The two halves are separate calls in swift-adwaita because they answer to
/// different mechanisms — `setLanguage` moves gettext, `applyTextDirection`
/// moves GTK — and an app that changed only the first would show Arabic text
/// in a left-to-right window.
///
/// - Returns: `true` when subsequent lookups will use `language`. `false`
///   means the session locale is `C` and no candidate locale is generated on
///   this machine — in which case nothing is translated at all, with or
///   without a picker.
@discardableResult
public func applyLanguage(_ language: AppLanguage) -> Bool {
    let applied = setLanguage(
        language.catalogueCode,
        localeCandidates: language.messagesLocaleCandidates.isEmpty
            ? nil
            : language.messagesLocaleCandidates,
    )
    applyInterfaceDirection(for: language)
    return applied
}

/// Points GTK's layout at the reading direction `language` is written in.
///
/// Called twice on the way up, deliberately. `initializeLocalization` runs
/// before `Application.run()`, and `gtk_init` sets the default direction from
/// GTK's *own* catalogue, discarding whatever was there — so the pre-init call
/// only covers the case where GTK never gets that far, and the launcher
/// re-applies this once the application is activated. Measured rather than
/// assumed: a direction set before `gtk_init` reads back as GTK's choice
/// afterwards.
public func applyInterfaceDirection(for language: AppLanguage) {
    applyTextDirection(forLanguage: language.catalogueCode)
}

/// Whether the interface should read right-to-left for `language`, without
/// touching GTK.
///
/// Split from ``applyInterfaceDirection(for:)`` so the decision — the part
/// this app owns — is testable in a process that holds windows. Assigning
/// GTK's default direction walks every live toplevel: safe in the app, but not
/// in a shared test process where earlier suites left windows behind whose
/// application has since been released. That the assignment actually mirrors a
/// realized window is swift-adwaita's test to make.
///
/// Returns `Bool` rather than `GtkTextDirection` deliberately: CSpelling and
/// CAdwaita both pull in `gtk/gtk.h`, so the app sees two distinct Swift types
/// of that name and cannot name either one usefully.
public func interfaceIsRightToLeft(for language: AppLanguage) -> Bool {
    isRightToLeft(language: language.catalogueCode)
}

/// Foundation locale matching the interface language, for anything Foundation
/// formats rather than gettext: dates, times, numbers.
///
/// `Locale.current` follows `LC_ALL` / `LANG`, not `LANGUAGE`, so a pinned
/// interface language would otherwise print Russian labels beside an English
/// date — which is exactly what the Russian build did before the picker had
/// this.
public func interfaceLocale() -> Locale {
    guard let code = currentLanguage else { return .current }
    return Locale(identifier: code)
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
                    .appendingPathComponent("\(AppIdentity.identifier).mo", isDirectory: false)
                    .path,
            )
        }.map(\.lastPathComponent),
    )
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
/// i.e. `<path>/<lang>/LC_MESSAGES/<app id>.mo` exists
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
            .appendingPathComponent("\(AppIdentity.identifier).mo", isDirectory: false)
        if FileManager.default.fileExists(atPath: expected.path) {
            return true
        }
    }
    return false
}
