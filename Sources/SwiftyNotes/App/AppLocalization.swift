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
@discardableResult
public func initializeLocalization(language: AppLanguage = .system) -> Bool {
    // swift-adwaita owns the gettext plumbing: activating the locale from the
    // environment, binding the domain to the catalogue directory, pinning the
    // codeset, and capturing the session's own LANGUAGE so "follow the
    // system" stays recoverable.
    //
    // Resolve the directory once. `localeDirectoryPath()` only returns a
    // directory that already holds a catalogue, so its answer *is* the
    // reachability answer — asking `configureLocalization` for it again would
    // sweep the same tree (or all of /usr/share/locale) a second time on the
    // main thread before the window appears.
    let localeDirectory = localeDirectoryPath()
    configureLocalization(
        domain: AppIdentity.identifier,
        localeDirectory: localeDirectory,
    )
    applyLanguage(language)
    return localeDirectory != nil
}

/// The line to print when no catalogue could be found, or `nil` when one was.
///
/// Split out as a pure function because the condition is unreachable in a
/// SwiftPM build — the Russian `.mo` is tracked and declared as a resource, so
/// a catalogue is always present — which would otherwise leave the message,
/// the stream and the condition all unverified.
///
/// It names the domain and the directory searched on purpose. Without those
/// the warning cannot do the job it exists for: a packager whose resource rule
/// flattened `<lang>/LC_MESSAGES/` away needs to know *which* of the five
/// candidate paths was used to find the flattened copy.
func missingCatalogueDiagnostic(
    localeDirectory: String?,
    domain: String = AppIdentity.identifier,
) -> String? {
    guard localeDirectory == nil else { return nil }
    return """
    swiftynotes: no \(domain) catalogue found under \(systemLocaleDirectory) \
    or any bundled location; running untranslated. gettext resolves only \
    <dir>/<lang>/LC_MESSAGES/\(domain).mo — check that packaging kept that layout.
    """
}

/// The line to print when the machine has no locale to translate under, or
/// `nil` when it has one.
///
/// gettext ignores `LANGUAGE` entirely while `LC_MESSAGES` names the `C`
/// locale — `C.UTF-8` counts — so on a machine where nothing else is
/// generated, nothing is translated with or without a language picked. A
/// minimal container image is exactly that, and the symptom gives no hint:
/// the interface comes up in English while its dates, which Foundation
/// formats from the same preference, come up translated.
func untranslatableLocaleDiagnostic() -> String? {
    guard !messagesLocaleSupportsTranslation else { return nil }
    return """
    swiftynotes: no locale beyond C is generated on this machine, so gettext \
    ignores the interface language and nothing will be translated. Generate one \
    (for example `locale-gen en_US.UTF-8`) to use a language other than English.
    """
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
/// Four sources, because none of them alone is right:
///
/// 1. **The pinned language.** Foundation ignores `LANGUAGE`, so without this
///    a Russian interface printed English dates.
/// 2. **The session's `LANGUAGE`.** Skipping it leaves the same bug on the
///    app's main distribution channel: the Flatpak sandbox runs with
///    `LANG=C.UTF-8`, so a host session that asks for Russian through
///    `LANGUAGE=ru` gets Russian labels — gettext honours it once the C-locale
///    block lifts — beside dates from step 4.
/// 3. **The session's locale**, per POSIX (`LC_ALL`, then `LC_TIME`, then
///    `LANG`). `.time` rather than `.messages` because dates are what this
///    formats, and `LANG=de_DE` with `LC_TIME=en_GB` is a real configuration.
/// 4. **`Locale.current`** last on Linux, where it answers `en_001` whatever
///    the environment says — measured on Swift 6.3.2 — and so cannot stand in
///    for the session's locale.
///
/// On Darwin the order is different on purpose: `Locale.current` is the user's
/// region from System Settings and outranks a `LANG` that a terminal happened
/// to export, so it comes straight after the pinned language.
public func interfaceLocale() -> Locale {
    if let code = currentLanguage {
        return Locale(identifier: code)
    }
    #if canImport(Darwin)
    return .current
    #else
    if let language = sessionLanguage?.split(separator: ":").first, !language.isEmpty {
        return Locale(identifier: String(language))
    }
    if let session = sessionLocaleIdentifier(for: .time) {
        return Locale(identifier: session)
    }
    return .current
    #endif
}

/// Language codes with a catalogue installed next to the running build.
///
/// English is absent by design: it is the msgid language and ships no `.mo`.
public func installedCatalogueLanguages() -> Set<String> {
    guard let localeDir = localeDirectoryPath() else { return [] }
    return catalogueLanguages(in: localeDir, domain: AppIdentity.identifier)
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
    if localeDirectoryContainsCatalog(systemLocaleDirectory) {
        return systemLocaleDirectory
    }

    return nil
}

/// Returns `true` if `path` contains a gettext catalogue for this app,
/// i.e. `<path>/<lang>/LC_MESSAGES/<app id>.mo` exists
/// for at least one `<lang>` subdirectory.
public func localeDirectoryContainsCatalog(_ path: String) -> Bool {
    // The same rule as `installedCatalogueLanguages()`, so it comes from the
    // same place: gettext resolves <path>/<lang>/LC_MESSAGES/<domain>.mo and
    // nothing else, and that rule must not have two implementations here.
    !catalogueLanguages(in: path, domain: AppIdentity.identifier).isEmpty
}
