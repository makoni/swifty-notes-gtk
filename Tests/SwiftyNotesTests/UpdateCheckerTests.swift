import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftyNotes
import Testing

struct UpdateCheckerTests {
    private func fetcher(tag: String, htmlURL: String = "https://github.com/x/y/releases/tag/v1") -> @Sendable () async throws -> GitHubLatestRelease {
        { GitHubLatestRelease(tagName: tag, htmlURL: URL(string: htmlURL)!) }
    }

    @Test("Reports up to date when remote tag equals current version")
    func reportsUpToDateWhenRemoteTagEqualsCurrentVersion() async throws {
        let checker = UpdateChecker(
            currentVersion: "1.2.3",
            forceUpdateAvailable: false,
            fetchLatestRelease: fetcher(tag: "v1.2.3"),
        )
        let result = await checker.check()
        guard case .upToDate = result else {
            Issue.record("Expected upToDate, got \(result)")
            return
        }
    }

    @Test("Reports up to date when remote tag is older than current")
    func reportsUpToDateWhenRemoteTagIsOlderThanCurrent() async throws {
        let checker = UpdateChecker(
            currentVersion: "1.5.0",
            forceUpdateAvailable: false,
            fetchLatestRelease: fetcher(tag: "1.4.9"),
        )
        let result = await checker.check()
        guard case .upToDate = result else {
            Issue.record("Expected upToDate, got \(result)")
            return
        }
    }

    @Test("Reports updateAvailable when remote tag is strictly newer")
    func reportsUpdateAvailableWhenRemoteTagIsStrictlyNewer() async throws {
        let url = "https://github.com/makoni/swifty-notes-gtk/releases/tag/v1.2.4"
        let checker = UpdateChecker(
            currentVersion: "1.2.3",
            forceUpdateAvailable: false,
            fetchLatestRelease: fetcher(tag: "v1.2.4", htmlURL: url),
        )
        let result = await checker.check()
        guard case let .updateAvailable(version, releaseURL) = result else {
            Issue.record("Expected updateAvailable, got \(result)")
            return
        }
        #expect(version == "1.2.4")
        #expect(releaseURL.absoluteString == url)
    }

    @Test("Force flag reports updateAvailable even when current already newer")
    func forceFlagReportsUpdateAvailableEvenWhenCurrentAlreadyNewer() async throws {
        let url = "https://github.com/makoni/swifty-notes-gtk/releases/tag/v0.0.1"
        let checker = UpdateChecker(
            currentVersion: "9.9.9",
            forceUpdateAvailable: true,
            fetchLatestRelease: fetcher(tag: "v0.0.1", htmlURL: url),
        )
        let result = await checker.check()
        guard case let .updateAvailable(version, releaseURL) = result else {
            Issue.record("Expected forced updateAvailable, got \(result)")
            return
        }
        #expect(version == "0.0.1")
        #expect(releaseURL.absoluteString == url)
    }

    @Test("Force flag still reports error when network fetch fails")
    func forceFlagStillReportsErrorWhenNetworkFetchFails() async throws {
        struct Boom: Error {}
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            forceUpdateAvailable: true,
            fetchLatestRelease: { throw Boom() },
        )
        let result = await checker.check()
        guard case .error = result else {
            Issue.record("Expected error, got \(result)")
            return
        }
    }

    @Test("Reports error when fetcher throws")
    func reportsErrorWhenFetcherThrows() async throws {
        struct Boom: Error {}
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            forceUpdateAvailable: false,
            fetchLatestRelease: { throw Boom() },
        )
        let result = await checker.check()
        guard case .error = result else {
            Issue.record("Expected error, got \(result)")
            return
        }
    }

    @Test("Reports error when remote tag is not parseable as semver")
    func reportsErrorWhenRemoteTagIsNotParseableAsSemver() async throws {
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            forceUpdateAvailable: false,
            fetchLatestRelease: fetcher(tag: "release-with-no-version"),
        )
        let result = await checker.check()
        guard case .error = result else {
            Issue.record("Expected error for unparseable tag, got \(result)")
            return
        }
    }

    @Test("Reports error when current version is not parseable as semver")
    func reportsErrorWhenCurrentVersionIsNotParseableAsSemver() async throws {
        let checker = UpdateChecker(
            currentVersion: "not-a-version",
            forceUpdateAvailable: false,
            fetchLatestRelease: fetcher(tag: "v1.0.0"),
        )
        let result = await checker.check()
        guard case .error = result else {
            Issue.record("Expected error for unparseable current version, got \(result)")
            return
        }
    }

    @Test("Unresolvable host is classified as networkUnavailable")
    func unresolvableHostIsNetworkUnavailable() async {
        // The exact failure a sandboxed (Flatpak/Snap) install produces:
        // NSURLErrorDomain Code=-1003 "Could not resolve host".
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            forceUpdateAvailable: false,
            fetchLatestRelease: { throw URLError(.cannotFindHost) },
        )
        let result = await checker.check()
        guard case .networkUnavailable = result else {
            Issue.record("Expected networkUnavailable for cannotFindHost, got \(result)")
            return
        }
    }

    @Test("Offline and connection failures are classified as networkUnavailable")
    func offlineFailuresAreNetworkUnavailable() async {
        let codes: [URLError.Code] = [.notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed]
        for code in codes {
            let checker = UpdateChecker(
                currentVersion: "1.0.0",
                forceUpdateAvailable: false,
                fetchLatestRelease: { throw URLError(code) },
            )
            let result = await checker.check()
            guard case .networkUnavailable = result else {
                Issue.record("Expected networkUnavailable for \(code), got \(result)")
                continue
            }
        }
    }

    @Test("A bridged NSError with the URL error domain is classified as networkUnavailable")
    func bridgedNSErrorIsNetworkUnavailable() async {
        // Matches the production error shape from the bug report:
        // Error Domain=NSURLErrorDomain Code=-1003.
        let underlying = NSError(domain: URLError.errorDomain, code: URLError.Code.cannotFindHost.rawValue)
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            forceUpdateAvailable: false,
            fetchLatestRelease: { throw underlying },
        )
        let result = await checker.check()
        guard case .networkUnavailable = result else {
            Issue.record("Expected networkUnavailable for bridged NSError -1003, got \(result)")
            return
        }
    }

    @Test("An HTTP error stays a plain error, not networkUnavailable")
    func httpErrorStaysPlainError() async {
        // The network IS reachable — GitHub answered with a 500. The
        // manual re-check stays useful, so this must not be classified
        // as unreachable.
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            forceUpdateAvailable: false,
            fetchLatestRelease: {
                throw NSError(
                    domain: "UpdateChecker",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP 500"],
                )
            },
        )
        let result = await checker.check()
        guard case .error = result else {
            Issue.record("Expected plain error for HTTP 500, got \(result)")
            return
        }
    }

    @Test("Ambiguous network errors stay plain errors so flaky links do not hide the menu item")
    func ambiguousNetworkErrorsStayPlainErrors() async {
        // .timedOut: slow GitHub vs no network — unknowable. .networkConnectionLost:
        // the connection DID establish and dropped mid-transfer, which a
        // sandbox (never connects at all) cannot produce. Neither is proof
        // the install has no network, so neither may hide the entry.
        let codes: [URLError.Code] = [.timedOut, .networkConnectionLost]
        for code in codes {
            let checker = UpdateChecker(
                currentVersion: "1.0.0",
                forceUpdateAvailable: false,
                fetchLatestRelease: { throw URLError(code) },
            )
            let result = await checker.check()
            guard case .error = result else {
                Issue.record("Expected plain error for \(code), got \(result)")
                continue
            }
        }
    }

    @Test("Parses GitHub release JSON payload")
    func parsesGitHubReleaseJSONPayload() throws {
        let json = #"""
        {
          "tag_name": "v1.4.2",
          "html_url": "https://github.com/owner/repo/releases/tag/v1.4.2",
          "name": "Release 1.4.2"
        }
        """#.data(using: .utf8)!
        let release = try GitHubLatestRelease.decode(from: json)
        #expect(release.tagName == "v1.4.2")
        #expect(release.htmlURL.absoluteString == "https://github.com/owner/repo/releases/tag/v1.4.2")
    }
}
