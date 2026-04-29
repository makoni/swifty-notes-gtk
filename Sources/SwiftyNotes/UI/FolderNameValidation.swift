import Foundation

/// Front-end validation for the user-facing folder-name dialogs (New
/// Folder, Rename Folder). Mirrors the rules `NotesRepository`'s
/// `validateFolderName` enforces at the storage layer, so the GUI rejects
/// the same names the repository would refuse — but as soon as the user
/// types them, before they hit Submit.
@MainActor
enum FolderNameValidation {
    /// Returns `true` when `name` is acceptable as a **single-component**
    /// folder name. Used by the Rename dialog: a rename only renames one
    /// folder, it doesn't move the folder under a new parent, so slashes
    /// must stay forbidden there.
    ///
    /// - Parameters:
    ///   - rawName: the user-typed input, possibly with leading/trailing
    ///     whitespace.
    ///   - currentName: when validating a rename, pass the current
    ///     folder's name. The function rejects a rename that matches it
    ///     (after trimming) since renaming to the same name is a no-op.
    static func isAcceptableName(_ rawName: String, currentName: String? = nil) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAcceptableComponent(trimmed) else { return false }
        if let currentName, trimmed == currentName { return false }
        return true
    }

    /// Returns `true` when `rawPath` is acceptable as a **multi-component**
    /// folder path. Used by the New Folder dialog where typing
    /// `Tasks/Todos/Jobs` deliberately creates a three-level hierarchy in
    /// one step (a small power-user shortcut similar to Obsidian).
    ///
    /// Each `/`-delimited component is held to ``isAcceptableComponent``.
    /// Empty components from `Work//Drafts` are rejected so the path is
    /// unambiguous; leading and trailing slashes are tolerated and stripped.
    static func isAcceptablePath(_ rawPath: String) -> Bool {
        let stripped = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !stripped.isEmpty else { return false }
        // Empty intermediate components (e.g. "Work//Drafts") are an
        // unambiguous typo, not a deeper hierarchy. Reject explicitly so
        // the user can fix it instead of silently dropping the empty bit.
        guard !stripped.contains("//") else { return false }
        let components = stripped.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return false }
        for component in components {
            guard isAcceptableComponent(component) else { return false }
        }
        return true
    }

    /// Per-component rules shared by both validators. Mirrors
    /// `NotesRepository.validateFolderName` minus the pathconf NAME_MAX
    /// check (UI doesn't have a directory URL handy; the storage layer
    /// rejects on save with a clear error if the user really pushes a
    /// 256-byte name through).
    private static func isAcceptableComponent(_ component: String) -> Bool {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != ".", trimmed != ".." else { return false }
        guard !trimmed.contains("/") else { return false }
        guard !trimmed.contains("\0") else { return false }
        return true
    }
}
