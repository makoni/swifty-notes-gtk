import Foundation
@testable import SwiftyNotes
import Testing

@MainActor
struct FolderNameValidationTests {
    @Test
    func `accepts a normal name`() {
        #expect(FolderNameValidation.isAcceptable("Work"))
        #expect(FolderNameValidation.isAcceptable("Plans 2026"))
    }

    @Test
    func `rejects empty and whitespace only names`() {
        #expect(!FolderNameValidation.isAcceptable(""))
        #expect(!FolderNameValidation.isAcceptable("   "))
        #expect(!FolderNameValidation.isAcceptable("\t\n"))
    }

    @Test
    func `rejects names containing slashes anywhere so they don't auto-create folder hierarchies`() {
        #expect(!FolderNameValidation.isAcceptable("Tasks/Todos"))
        #expect(!FolderNameValidation.isAcceptable("/leading"))
        #expect(!FolderNameValidation.isAcceptable("trailing/"))
        #expect(!FolderNameValidation.isAcceptable("a/b/c"))
    }

    @Test
    func `rejects dot and double dot which would resolve to the current or parent directory`() {
        #expect(!FolderNameValidation.isAcceptable("."))
        #expect(!FolderNameValidation.isAcceptable(".."))
    }

    @Test
    func `rejects null bytes which would corrupt the on-disk path`() {
        #expect(!FolderNameValidation.isAcceptable("Bad\0Name"))
    }

    @Test
    func `rejects a rename that matches the current name because it is a no-op`() {
        #expect(!FolderNameValidation.isAcceptable("Work", currentName: "Work"))
        #expect(!FolderNameValidation.isAcceptable("  Work  ", currentName: "Work"))
    }

    @Test
    func `accepts a rename that differs from the current name after trimming`() {
        #expect(FolderNameValidation.isAcceptable("Outbox", currentName: "Drafts"))
        #expect(FolderNameValidation.isAcceptable("  Outbox  ", currentName: "Drafts"))
    }
}
