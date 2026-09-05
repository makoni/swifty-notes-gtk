import Adwaita
import Foundation

/// The interface language the user picked in Settings.
///
/// ``system`` follows the session locale (`LC_ALL` / `LC_MESSAGES` / `LANG`),
/// which is what the app did before the picker existed. Every other case pins
/// the language regardless of the session, so a Russian interface on an
/// English desktop — and the reverse — is one combo row away.
///
/// Adding a language is one case here plus a `po/<code>.po`; a guard test
/// fails when a shipped catalogue has no case, so the picker cannot silently
/// omit a translation the build already installs.
public enum AppLanguage: String, Codable, CaseIterable, Equatable, Sendable {
    case system
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case dutch = "nl"
    case japanese = "ja"
    case brazilianPortuguese = "pt_BR"
    case russian = "ru"

    /// The gettext language code to pin, or `nil` to follow the session.
    public var catalogueCode: String? {
        self == .system ? nil : rawValue
    }

    /// Locales to try when the session runs under `C` / `POSIX`, where
    /// gettext ignores `LANGUAGE` entirely. Any generated locale lifts that
    /// block — it does not have to belong to the language being selected —
    /// so the language's own locale comes first and a widely generated one
    /// backs it up.
    var messagesLocaleCandidates: [String] {
        // The language's own locale first, then locales that are widely
        // generated. `C.UTF-8` is deliberately absent: it *is* the C locale as
        // far as gettext is concerned, so offering it as an escape from the C
        // locale can only ever fail.
        switch self {
        case .system:
            []
        case .english:
            ["en_US.UTF-8", "en_GB.UTF-8"]
        case .german:
            ["de_DE.UTF-8", "de_AT.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .french:
            ["fr_FR.UTF-8", "fr_CA.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .spanish:
            ["es_ES.UTF-8", "es_MX.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .italian:
            ["it_IT.UTF-8", "it_CH.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .dutch:
            ["nl_NL.UTF-8", "nl_BE.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .japanese:
            ["ja_JP.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .brazilianPortuguese:
            ["pt_BR.UTF-8", "pt_PT.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .russian:
            ["ru_RU.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        }
    }

    /// Name shown in the picker.
    ///
    /// Language names stay in their own language: someone hunting for their
    /// language should not first have to read the one currently on screen.
    /// Only the follow-the-session row is translated.
    public var displayName: String {
        switch self {
        case .system:
            "System language".localized
        case .english:
            "English"
        case .german:
            "Deutsch"
        case .french:
            "Français"
        case .spanish:
            "Español"
        case .italian:
            "Italiano"
        case .dutch:
            "Nederlands"
        case .japanese:
            "日本語"
        case .brazilianPortuguese:
            "Português (Brasil)"
        case .russian:
            "Русский"
        }
    }
}
