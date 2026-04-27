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
}
