import Foundation
@testable import SwiftyNotes
import Testing

@MainActor
struct FolderNameValidationTests {
    // MARK: - isAcceptableName (single component, used by Rename dialog)

    @Test("Name accepts a normal single component name")
    func nameAcceptsANormalSingleComponentName() {
        #expect(FolderNameValidation.isAcceptableName("Work"))
        #expect(FolderNameValidation.isAcceptableName("Plans 2026"))
    }

    @Test("Name rejects empty and whitespace only names")
    func nameRejectsEmptyAndWhitespaceOnlyNames() {
        #expect(!FolderNameValidation.isAcceptableName(""))
        #expect(!FolderNameValidation.isAcceptableName("   "))
        #expect(!FolderNameValidation.isAcceptableName("\t\n"))
    }

    @Test("Name rejects slashes anywhere because rename only takes a single component")
    func nameRejectsSlashesAnywhereBecauseRenameOnlyTakesASingleComponent() {
        #expect(!FolderNameValidation.isAcceptableName("Tasks/Todos"))
        #expect(!FolderNameValidation.isAcceptableName("/leading"))
        #expect(!FolderNameValidation.isAcceptableName("trailing/"))
        #expect(!FolderNameValidation.isAcceptableName("a/b/c"))
    }

    @Test("Name rejects dot and double dot which would resolve to the current or parent directory")
    func nameRejectsDotAndDoubleDotWhichWouldResolveToTheCurrent() {
        #expect(!FolderNameValidation.isAcceptableName("."))
        #expect(!FolderNameValidation.isAcceptableName(".."))
    }

    @Test("Name rejects null bytes which would corrupt the on-disk path")
    func nameRejectsNullBytesWhichWouldCorruptTheOnDiskPath() {
        #expect(!FolderNameValidation.isAcceptableName("Bad\0Name"))
    }

    @Test("Name rejects a rename that matches the current name because it is a no-op")
    func nameRejectsARenameThatMatchesTheCurrentNameBecauseItIs() {
        #expect(!FolderNameValidation.isAcceptableName("Work", currentName: "Work"))
        #expect(!FolderNameValidation.isAcceptableName("  Work  ", currentName: "Work"))
    }

    @Test("Name accepts a rename that differs from the current name after trimming")
    func nameAcceptsARenameThatDiffersFromTheCurrentNameAfterTrimming() {
        #expect(FolderNameValidation.isAcceptableName("Outbox", currentName: "Drafts"))
        #expect(FolderNameValidation.isAcceptableName("  Outbox  ", currentName: "Drafts"))
    }

    // MARK: - isAcceptablePath (slash-nested, used by New Folder dialog)

    @Test("Path accepts a single component")
    func pathAcceptsASingleComponent() {
        #expect(FolderNameValidation.isAcceptablePath("Work"))
        #expect(FolderNameValidation.isAcceptablePath("  Work  "))
    }

    @Test("Path accepts nested components separated by slash so users can create a hierarchy in one step")
    func pathAcceptsNestedComponentsSeparatedBySlashSoUsersCanCreateA() {
        #expect(FolderNameValidation.isAcceptablePath("Work/Drafts"))
        #expect(FolderNameValidation.isAcceptablePath("Tasks/Todos/Jobs"))
    }

    @Test("Path tolerates leading and trailing slashes")
    func pathToleratesLeadingAndTrailingSlashes() {
        #expect(FolderNameValidation.isAcceptablePath("/Work"))
        #expect(FolderNameValidation.isAcceptablePath("Work/"))
        #expect(FolderNameValidation.isAcceptablePath("/Work/Drafts/"))
    }

    @Test("Path rejects empty input even after stripping whitespace and slashes")
    func pathRejectsEmptyInputEvenAfterStrippingWhitespaceAndSlashes() {
        #expect(!FolderNameValidation.isAcceptablePath(""))
        #expect(!FolderNameValidation.isAcceptablePath("   "))
        #expect(!FolderNameValidation.isAcceptablePath("/"))
        #expect(!FolderNameValidation.isAcceptablePath("///"))
    }

    @Test("Path rejects empty intermediate components from double slashes")
    func pathRejectsEmptyIntermediateComponentsFromDoubleSlashes() {
        #expect(!FolderNameValidation.isAcceptablePath("Work//Drafts"))
        #expect(!FolderNameValidation.isAcceptablePath("a///b"))
    }

    @Test("Path rejects any component that is dot or double dot")
    func pathRejectsAnyComponentThatIsDotOrDoubleDot() {
        #expect(!FolderNameValidation.isAcceptablePath("Work/."))
        #expect(!FolderNameValidation.isAcceptablePath("Work/.."))
        #expect(!FolderNameValidation.isAcceptablePath("../Work"))
    }

    @Test("Path rejects null bytes anywhere")
    func pathRejectsNullBytesAnywhere() {
        #expect(!FolderNameValidation.isAcceptablePath("Work/Bad\0Name"))
    }

    // MARK: - Hidden folders (leading dot) — walker uses skipsHiddenFiles

    @Test("Name rejects leading dot because the walker treats hidden folders as invisible")
    func nameRejectsLeadingDotBecauseTheWalkerTreatsHiddenFoldersAsInvisible() {
        #expect(!FolderNameValidation.isAcceptableName(".config"))
        #expect(!FolderNameValidation.isAcceptableName(".git"))
        #expect(!FolderNameValidation.isAcceptableName(".hidden"))
    }

    @Test("Path rejects any component with a leading dot")
    func pathRejectsAnyComponentWithALeadingDot() {
        #expect(!FolderNameValidation.isAcceptablePath("Work/.git"))
        #expect(!FolderNameValidation.isAcceptablePath(".hidden/Work"))
        #expect(!FolderNameValidation.isAcceptablePath("Work/.config/Drafts"))
    }

    // MARK: - Windows / cross-platform compatibility

    @Test("Name rejects Windows reserved device names regardless of case or extension")
    func nameRejectsWindowsReservedDeviceNamesRegardlessOfCaseOrExtension() {
        for reserved in ["CON", "con", "Con", "PRN", "AUX", "NUL"] {
            #expect(!FolderNameValidation.isAcceptableName(reserved), "\(reserved) should be rejected")
        }
        #expect(!FolderNameValidation.isAcceptableName("CON.txt"))
        #expect(!FolderNameValidation.isAcceptableName("nul.notes"))
    }

    @Test("Name rejects Windows COM and LPT device names with digit 1 through 9")
    func nameRejectsWindowsCOMAndLPTDeviceNamesWithDigit1Through() {
        for index in 1 ... 9 {
            #expect(!FolderNameValidation.isAcceptableName("COM\(index)"))
            #expect(!FolderNameValidation.isAcceptableName("LPT\(index)"))
        }
        // COM10/LPT10 are NOT reserved on Windows — only single-digit suffixes.
        #expect(FolderNameValidation.isAcceptableName("COM10"))
        #expect(FolderNameValidation.isAcceptableName("LPT0"))
    }

    @Test("Name rejects characters that NTFS forbids so cross-platform sync stays safe")
    func nameRejectsCharactersThatNTFSForbidsSoCrossPlatformSyncStaysSafe() {
        for forbidden in ["Work<bad", "Work>bad", "Work:bad", "Work\"bad", "Work|bad", "Work?bad", "Work*bad", "Work\\bad"] {
            #expect(!FolderNameValidation.isAcceptableName(forbidden), "\(forbidden) should be rejected")
        }
    }

    @Test("Name rejects trailing dot or whitespace which Windows silently strips on round trip")
    func nameRejectsTrailingDotOrWhitespaceWhichWindowsSilentlyStripsOnRound() {
        #expect(!FolderNameValidation.isAcceptableName("Work."))
        #expect(!FolderNameValidation.isAcceptableName("Plans..."))
    }

    @Test("Path rejects nested components matching Windows reserved or forbidden patterns")
    func pathRejectsNestedComponentsMatchingWindowsReservedOrForbiddenPatterns() {
        #expect(!FolderNameValidation.isAcceptablePath("Work/CON"))
        #expect(!FolderNameValidation.isAcceptablePath("Drafts/COM1"))
        #expect(!FolderNameValidation.isAcceptablePath("Work/Bad?Name"))
        #expect(!FolderNameValidation.isAcceptablePath("Work/Trailing."))
    }

    // MARK: - Normalization (collapses whitespace around / and strips slashes)

    @Test("Normalize trims surrounding whitespace and slashes")
    func normalizeTrimsSurroundingWhitespaceAndSlashes() {
        #expect(FolderNameValidation.normalizePath("  Work  ") == "Work")
        #expect(FolderNameValidation.normalizePath("/Work/") == "Work")
        #expect(FolderNameValidation.normalizePath("/Work/Drafts/") == "Work/Drafts")
    }

    @Test("Normalize trims whitespace inside each slash separated component")
    func normalizeTrimsWhitespaceInsideEachSlashSeparatedComponent() {
        #expect(FolderNameValidation.normalizePath("Work / Drafts") == "Work/Drafts")
        #expect(FolderNameValidation.normalizePath(" Tasks  /  Todos / Jobs ") == "Tasks/Todos/Jobs")
    }
}
