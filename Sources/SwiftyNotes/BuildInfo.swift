import Foundation

enum BuildInfo {
    private static let defaultVersion = "Development"

    static var version: String {
        let rawValue = ProcessInfo.processInfo.environment["SWIFTY_NOTES_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, !rawValue.isEmpty else {
            return defaultVersion
        }
        return rawValue
    }
}
