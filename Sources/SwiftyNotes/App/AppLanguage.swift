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
///
/// The case order *is* the order of the rows in the picker, so ``system``
/// comes first and the rest are sorted by the name they show — Latin,
/// Cyrillic, Hebrew, Arabic, then CJK, which is where a plain string sort puts
/// them. A guard test keeps it that way, so a new language goes in its sorted
/// place rather than at the end.
public enum AppLanguage: String, Codable, CaseIterable, Equatable, Sendable {
    case system
    case german = "de"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case dutch = "nl"
    case brazilianPortuguese = "pt_BR"
    case russian = "ru"
    case hebrew = "he"
    case arabic = "ar"
    case japanese = "ja"
    case simplifiedChinese = "zh_CN"
    case traditionalChinese = "zh_TW"
    case korean = "ko"

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
        case .german:
            ["de_DE.UTF-8", "de_AT.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .english:
            ["en_US.UTF-8", "en_GB.UTF-8"]
        case .spanish:
            ["es_ES.UTF-8", "es_MX.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .french:
            ["fr_FR.UTF-8", "fr_CA.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .italian:
            ["it_IT.UTF-8", "it_CH.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .dutch:
            ["nl_NL.UTF-8", "nl_BE.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .brazilianPortuguese:
            ["pt_BR.UTF-8", "pt_PT.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .russian:
            ["ru_RU.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .hebrew:
            ["he_IL.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .arabic:
            ["ar_EG.UTF-8", "ar_SA.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .japanese:
            ["ja_JP.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .simplifiedChinese:
            ["zh_CN.UTF-8", "zh_SG.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .traditionalChinese:
            ["zh_TW.UTF-8", "zh_HK.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
        case .korean:
            ["ko_KR.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"]
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
        case .german:
            "Deutsch"
        case .english:
            "English"
        case .spanish:
            "Español"
        case .french:
            "Français"
        case .italian:
            "Italiano"
        case .dutch:
            "Nederlands"
        case .brazilianPortuguese:
            "Português (Brasil)"
        case .russian:
            "Русский"
        case .hebrew:
            "עברית"
        case .arabic:
            "العربية"
        case .japanese:
            "日本語"
        case .simplifiedChinese:
            "简体中文"
        case .traditionalChinese:
            "繁體中文"
        case .korean:
            "한국어"
        }
    }
}
