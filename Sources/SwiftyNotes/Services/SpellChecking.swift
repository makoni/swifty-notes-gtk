import Adwaita
import CSpelling
import Foundation

/// Wires `libspelling-1` (the GNOME shared spell-check stack used by
/// gnome-text-editor and gnome-builder) into a ``SourceView`` editor.
///
/// Inline misspellings get a wavy underline tag, the source view's
/// context menu grows a "Spelling" submenu with corrections / Add to
/// Dictionary / Ignore actions, and the adapter follows the system
/// locale unless an explicit language code is set.
///
/// Spell-checking happens against the system Enchant providers (hunspell
/// dictionaries on Ubuntu by default) — install additional dictionaries
/// system-wide to get more language support.
@MainActor
final class SpellChecking {
    private let view: SourceView
    private let adapterPointer: UnsafeMutableRawPointer

    /// Creates and attaches a spell-check adapter to the given source
    /// view. The adapter starts enabled and uses the default checker
    /// (system locale / first available dictionary). Returns `nil` if
    /// no spell-check provider is available on the system.
    init?(view: SourceView, buffer: SourceBuffer) {
        guard let adapter = swifty_notes_spelling_attach(
            UnsafeMutableRawPointer(buffer.opaquePointer),
            UnsafeMutableRawPointer(view.opaquePointer),
        ) else {
            return nil
        }
        self.view = view
        adapterPointer = adapter
    }

    /// Toggles spell-checking. The adapter keeps tracking the buffer
    /// either way; flipping back on re-runs on the current text.
    var isEnabled: Bool {
        get { swifty_notes_spelling_get_enabled(adapterPointer) != 0 }
        set { swifty_notes_spelling_set_enabled(adapterPointer, newValue ? 1 : 0) }
    }

    /// Re-scans the entire buffer. Call after the buffer text has been
    /// replaced wholesale (for example when the user switches to a
    /// different note); incremental tracking is for keystrokes, not
    /// for full-buffer swaps.
    func invalidateAll() {
        swifty_notes_spelling_invalidate_all(adapterPointer)
    }

    /// IETF-style language tag (`en_US`, `de_DE`, ...). `nil` keeps the
    /// adapter on the default language picked by the checker, which
    /// follows the system locale.
    var language: String? {
        get {
            guard let cString = swifty_notes_spelling_get_language(adapterPointer) else { return nil }
            return String(cString: cString)
        }
        set {
            swifty_notes_spelling_set_language(adapterPointer, newValue)
        }
    }

    /// One language entry exposed by the system's spell-check provider.
    struct LanguageOption: Hashable {
        /// IETF code such as `en_US`, suitable for `language` setter.
        let code: String
        /// Localized display name like "English (United States)".
        let displayName: String
    }

    /// Lists every language the system's spell-check provider can offer.
    /// Empty when no provider / no dictionaries are installed.
    static func availableLanguages() -> [LanguageOption] {
        var collected: [LanguageOption] = []
        withUnsafeMutablePointer(to: &collected) { pointer in
            swifty_notes_spelling_for_each_language({ codePointer, namePointer, userData in
                guard let codePointer, let namePointer, let userData else { return }
                let listPointer = userData.assumingMemoryBound(to: [LanguageOption].self)
                listPointer.pointee.append(
                    LanguageOption(
                        code: String(cString: codePointer),
                        displayName: String(cString: namePointer),
                    ),
                )
            }, UnsafeMutableRawPointer(pointer))
        }
        return collected.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }
}
