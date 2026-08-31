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
        switch self {
        case .system:
            []
        case .english:
            ["en_US.UTF-8", "en_GB.UTF-8", "C.UTF-8"]
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
        case .russian:
            "Русский"
        }
    }
}
