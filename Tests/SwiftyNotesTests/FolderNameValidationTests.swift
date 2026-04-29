import Foundation
@testable import SwiftyNotes
import Testing

@MainActor
struct FolderNameValidationTests {
    // MARK: - isAcceptableName (single component, used by Rename dialog)

    @Test
    func `name accepts a normal single component name`() {
        #expect(FolderNameValidation.isAcceptableName("Work"))
        #expect(FolderNameValidation.isAcceptableName("Plans 2026"))
    }

    @Test
    func `name rejects empty and whitespace only names`() {
        #expect(!FolderNameValidation.isAcceptableName(""))
        #expect(!FolderNameValidation.isAcceptableName("   "))
        #expect(!FolderNameValidation.isAcceptableName("\t\n"))
    }

    @Test
    func `name rejects slashes anywhere because rename only takes a single component`() {
        #expect(!FolderNameValidation.isAcceptableName("Tasks/Todos"))
        #expect(!FolderNameValidation.isAcceptableName("/leading"))
        #expect(!FolderNameValidation.isAcceptableName("trailing/"))
        #expect(!FolderNameValidation.isAcceptableName("a/b/c"))
    }

    @Test
    func `name rejects dot and double dot which would resolve to the current or parent directory`() {
        #expect(!FolderNameValidation.isAcceptableName("."))
        #expect(!FolderNameValidation.isAcceptableName(".."))
    }

    @Test
    func `name rejects null bytes which would corrupt the on-disk path`() {
        #expect(!FolderNameValidation.isAcceptableName("Bad\0Name"))
    }

    @Test
    func `name rejects a rename that matches the current name because it is a no-op`() {
        #expect(!FolderNameValidation.isAcceptableName("Work", currentName: "Work"))
        #expect(!FolderNameValidation.isAcceptableName("  Work  ", currentName: "Work"))
    }

    @Test
    func `name accepts a rename that differs from the current name after trimming`() {
        #expect(FolderNameValidation.isAcceptableName("Outbox", currentName: "Drafts"))
        #expect(FolderNameValidation.isAcceptableName("  Outbox  ", currentName: "Drafts"))
    }

    // MARK: - isAcceptablePath (slash-nested, used by New Folder dialog)

    @Test
    func `path accepts a single component`() {
        #expect(FolderNameValidation.isAcceptablePath("Work"))
        #expect(FolderNameValidation.isAcceptablePath("  Work  "))
    }

    @Test
    func `path accepts nested components separated by slash so users can create a hierarchy in one step`() {
        #expect(FolderNameValidation.isAcceptablePath("Work/Drafts"))
        #expect(FolderNameValidation.isAcceptablePath("Tasks/Todos/Jobs"))
    }

    @Test
    func `path tolerates leading and trailing slashes`() {
        #expect(FolderNameValidation.isAcceptablePath("/Work"))
        #expect(FolderNameValidation.isAcceptablePath("Work/"))
        #expect(FolderNameValidation.isAcceptablePath("/Work/Drafts/"))
    }

    @Test
    func `path rejects empty input even after stripping whitespace and slashes`() {
        #expect(!FolderNameValidation.isAcceptablePath(""))
        #expect(!FolderNameValidation.isAcceptablePath("   "))
        #expect(!FolderNameValidation.isAcceptablePath("/"))
        #expect(!FolderNameValidation.isAcceptablePath("///"))
    }

    @Test
    func `path rejects empty intermediate components from double slashes`() {
        #expect(!FolderNameValidation.isAcceptablePath("Work//Drafts"))
        #expect(!FolderNameValidation.isAcceptablePath("a///b"))
    }

    @Test
    func `path rejects any component that is dot or double dot`() {
        #expect(!FolderNameValidation.isAcceptablePath("Work/."))
        #expect(!FolderNameValidation.isAcceptablePath("Work/.."))
        #expect(!FolderNameValidation.isAcceptablePath("../Work"))
    }

    @Test
    func `path rejects null bytes anywhere`() {
        #expect(!FolderNameValidation.isAcceptablePath("Work/Bad\0Name"))
    }

    // MARK: - Hidden folders (leading dot) — walker uses skipsHiddenFiles

    @Test
    func `name rejects leading dot because the walker treats hidden folders as invisible`() {
        #expect(!FolderNameValidation.isAcceptableName(".config"))
        #expect(!FolderNameValidation.isAcceptableName(".git"))
        #expect(!FolderNameValidation.isAcceptableName(".hidden"))
    }

    @Test
    func `path rejects any component with a leading dot`() {
        #expect(!FolderNameValidation.isAcceptablePath("Work/.git"))
        #expect(!FolderNameValidation.isAcceptablePath(".hidden/Work"))
        #expect(!FolderNameValidation.isAcceptablePath("Work/.config/Drafts"))
    }

    // MARK: - Windows / cross-platform compatibility

    @Test
    func `name rejects Windows reserved device names regardless of case or extension`() {
        for reserved in ["CON", "con", "Con", "PRN", "AUX", "NUL"] {
            #expect(!FolderNameValidation.isAcceptableName(reserved), "\(reserved) should be rejected")
        }
        #expect(!FolderNameValidation.isAcceptableName("CON.txt"))
        #expect(!FolderNameValidation.isAcceptableName("nul.notes"))
    }

    @Test
    func `name rejects Windows COM and LPT device names with digit 1 through 9`() {
        for index in 1 ... 9 {
            #expect(!FolderNameValidation.isAcceptableName("COM\(index)"))
            #expect(!FolderNameValidation.isAcceptableName("LPT\(index)"))
        }
        // COM10/LPT10 are NOT reserved on Windows — only single-digit suffixes.
        #expect(FolderNameValidation.isAcceptableName("COM10"))
        #expect(FolderNameValidation.isAcceptableName("LPT0"))
    }

    @Test
    func `name rejects characters that NTFS forbids so cross-platform sync stays safe`() {
        for forbidden in ["Work<bad", "Work>bad", "Work:bad", "Work\"bad", "Work|bad", "Work?bad", "Work*bad", "Work\\bad"] {
            #expect(!FolderNameValidation.isAcceptableName(forbidden), "\(forbidden) should be rejected")
        }
    }

    @Test
    func `name rejects trailing dot or whitespace which Windows silently strips on round trip`() {
        #expect(!FolderNameValidation.isAcceptableName("Work."))
        #expect(!FolderNameValidation.isAcceptableName("Plans..."))
    }

    @Test
    func `path rejects nested components matching Windows reserved or forbidden patterns`() {
        #expect(!FolderNameValidation.isAcceptablePath("Work/CON"))
        #expect(!FolderNameValidation.isAcceptablePath("Drafts/COM1"))
        #expect(!FolderNameValidation.isAcceptablePath("Work/Bad?Name"))
        #expect(!FolderNameValidation.isAcceptablePath("Work/Trailing."))
    }

    // MARK: - Normalization (collapses whitespace around / and strips slashes)

    @Test
    func `normalize trims surrounding whitespace and slashes`() {
        #expect(FolderNameValidation.normalizePath("  Work  ") == "Work")
        #expect(FolderNameValidation.normalizePath("/Work/") == "Work")
        #expect(FolderNameValidation.normalizePath("/Work/Drafts/") == "Work/Drafts")
    }

    @Test
    func `normalize trims whitespace inside each slash separated component`() {
        #expect(FolderNameValidation.normalizePath("Work / Drafts") == "Work/Drafts")
        #expect(FolderNameValidation.normalizePath(" Tasks  /  Todos / Jobs ") == "Tasks/Todos/Jobs")
    }
}
