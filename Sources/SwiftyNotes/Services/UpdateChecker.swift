import Foundation
// On Linux, `URLSession`, `URLRequest`, and the async `data(for:)`
// helper live in a separate `FoundationNetworking` module rather than
// in Foundation proper. Without this conditional import the Linux
// build sees `URLSession` as the opaque `AnyObject` typealias from
// pure Foundation, and `.shared` / `data(for:)` fail to resolve. The
// macOS build resolves the same names from Foundation directly, so
// the canImport guard makes both platforms compile.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub `/releases/latest` payload, narrowed to the two fields we use.
struct GitHubLatestRelease: Sendable, Equatable {
    let tagName: String
    let htmlURL: URL

    static func decode(from data: Data) throws -> GitHubLatestRelease {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return GitHubLatestRelease(tagName: raw.tagName, htmlURL: raw.htmlURL)
    }

    private struct Raw: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}

/// Outcome of a single GitHub-releases check.
enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case updateAvailable(version: String, releaseURL: URL)
    case error(message: String)
}

/// Pure logic that turns a current version + a release-fetcher closure into
/// an `UpdateCheckResult`. UI layers (banner, menu) call `check()` and act
/// on the returned value; the closure is injected so the unit tests can
/// exercise success / failure / forced paths without touching the network.
struct UpdateChecker: Sendable {
    let currentVersion: String
    let forceUpdateAvailable: Bool
    let fetchLatestRelease: @Sendable () async throws -> GitHubLatestRelease

    func check() async -> UpdateCheckResult {
        let release: GitHubLatestRelease
        do {
            release = try await fetchLatestRelease()
        } catch {
            return .error(message: String(describing: error))
        }
        guard let remote = SemanticVersion(release.tagName) else {
            return .error(message: "Could not parse remote version \"\(release.tagName)\"")
        }
        guard let current = SemanticVersion(currentVersion) else {
            return .error(message: "Could not parse current version \"\(currentVersion)\"")
        }
        let normalized = Self.normalizedVersionString(release.tagName)
        if forceUpdateAvailable || remote > current {
            return .updateAvailable(version: normalized, releaseURL: release.htmlURL)
        }
        return .upToDate
    }

    private static func normalizedVersionString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "v" || first == "V" {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }
}

extension UpdateChecker {
    /// Default fetcher used by the app at runtime. Hits the GitHub REST API
    /// (`/repos/<owner>/<repo>/releases/latest`) with a 10s timeout and a
    /// `User-Agent` (required by GitHub for unauthenticated requests).
    static func gitHubReleasesFetcher(
        owner: String,
        repo: String,
        session: URLSession = .shared,
    ) -> @Sendable () async throws -> GitHubLatestRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        return {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("swifty-notes-gtk", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(
                    domain: "UpdateChecker",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(http.statusCode)"],
                )
            }
            return try GitHubLatestRelease.decode(from: data)
        }
    }
}
