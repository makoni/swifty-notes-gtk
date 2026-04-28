import Foundation

/// Front-end validation for the user-facing folder-name dialogs (New
/// Folder, Rename Folder). Mirrors the rules `NotesRepository`'s
/// `validateFolderName` enforces at the storage layer, so the GUI rejects
/// the same names the repository would refuse — but as soon as the user
/// types them, before they hit Submit.
///
/// Surfacing the rules in the UI keeps the experience predictable: the
/// Create / Rename button stays disabled instead of producing a
/// post-hoc error toast or, worse, silently accepting `Tasks/Todos` and
/// implicitly creating two nested folders (the bug @leeford filed
/// in #20).
@MainActor
enum FolderNameValidation {
    /// Returns `true` when `name` is acceptable as a folder name.
    ///
    /// - Parameters:
    ///   - rawName: the user-typed input, possibly with leading/trailing
    ///     whitespace.
    ///   - currentName: when validating a rename, pass the current
    ///     folder's name. The function rejects a rename that matches it
    ///     (after trimming) since renaming to the same name is a no-op.
    static func isAcceptable(_ rawName: String, currentName: String? = nil) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != ".", trimmed != ".." else { return false }
        guard !trimmed.contains("/") else { return false }
        guard !trimmed.contains("\0") else { return false }
        if let currentName, trimmed == currentName { return false }
        return true
    }
}
