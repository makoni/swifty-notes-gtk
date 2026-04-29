import Foundation

/// Front-end validation for the user-facing folder-name dialogs (New
/// Folder, Rename Folder). Mirrors the rules `NotesRepository`'s
/// `validateFolderName` enforces at the storage layer, plus a few extra
/// guards that are easier to surface in the UI than after submission:
///
/// - Hidden folders (leading dot) — rejected because the storage walker
///   uses `skipsHiddenFiles`, so creating one would silently make it
///   invisible the moment the sidebar refreshes.
/// - Trailing dot or whitespace — Windows silently strips both when a
///   path round-trips through NTFS-backed sync, which corrupts notes for
///   anyone who syncs the vault to a Windows machine.
/// - Windows reserved device names (CON, PRN, AUX, NUL, COM1–9, LPT1–9)
///   and the Windows-forbidden character set (`< > : " | ? * \`) — same
///   cross-platform-sync motivation.
@MainActor
enum FolderNameValidation {
    /// Returns `true` when `name` is acceptable as a **single-component**
    /// folder name. Used by the Rename dialog: a rename only renames one
    /// folder, so slashes must stay forbidden there.
    static func isAcceptableName(_ rawName: String, currentName: String? = nil) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAcceptableComponent(trimmed) else { return false }
        if let currentName, trimmed == currentName { return false }
        return true
    }

    /// Returns `true` when `rawPath` is acceptable as a **multi-component**
    /// folder path. Each `/`-delimited component is held to
    /// ``isAcceptableComponent``. Empty components from `Work//Drafts` are
    /// rejected so the path is unambiguous; surrounding whitespace and
    /// leading/trailing slashes are tolerated and stripped.
    static func isAcceptablePath(_ rawPath: String) -> Bool {
        let stripped = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !stripped.isEmpty else { return false }
        guard !stripped.contains("//") else { return false }
        let components = stripped.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return false }
        for component in components {
            guard isAcceptableComponent(component.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        }
        return true
    }

    /// Canonical form of a user-typed path: outer whitespace and slashes
    /// stripped, internal whitespace around each `/` trimmed away. The
    /// result is what ``presentNewFolderDialog`` hands to
    /// `NotesRepository.createFolder` so the on-disk layout matches what
    /// the user intended (`Work / Drafts` → `Work/Drafts`).
    static func normalizePath(_ rawPath: String) -> String {
        let stripped = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = stripped.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return components.joined(separator: "/")
    }

    // MARK: - Per-component rules

    private static let windowsReservedDeviceNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for index in 1 ... 9 {
            names.insert("COM\(index)")
            names.insert("LPT\(index)")
        }
        return names
    }()

    private static let windowsForbiddenCharacters: Set<Character> = [
        "<", ">", ":", "\"", "|", "?", "*", "\\",
    ]

    /// Per-component rules shared by both validators.
    private static func isAcceptableComponent(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        guard component != ".", component != ".." else { return false }
        guard !component.hasPrefix(".") else { return false }
        guard !component.contains("/") else { return false }
        guard !component.contains("\0") else { return false }

        // Windows / cross-platform sync: trailing dot or whitespace,
        // forbidden characters, reserved device names.
        if let last = component.last, last == "." || last.isWhitespace {
            return false
        }
        if component.contains(where: { windowsForbiddenCharacters.contains($0) }) {
            return false
        }
        let upper = component.uppercased()
        let stem = upper.split(separator: ".", omittingEmptySubsequences: false)
            .first.map(String.init) ?? upper
        if windowsReservedDeviceNames.contains(stem) {
            return false
        }

        return true
    }
}
