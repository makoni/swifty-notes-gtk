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
}
