import Foundation
@testable import SwiftyNotes
import Adwaita
import Testing

/// Tests for the localization infrastructure: locale directory reachability.
@Suite(.serialized)
struct LocalizationTests {
    private static let _setup: Void = {
        initializeLocalization()
    }()

    // MARK: - Blocker 1: Locale directory reachability

    @Test func localeDirectoryPathReturnsNonNilWithMoFiles() {
        _ = Self._setup
        let localeDir = localeDirectoryPath()
        #expect(localeDir != nil, "localeDirectoryPath() must resolve when .mo files are present")

        if let dir = localeDir {
            #expect(FileManager.default.fileExists(atPath: dir))
        }
    }
}
