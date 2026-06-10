import Foundation
@testable import SwiftyNotes
import Testing

struct PreviewRemoteImageLoaderTests {
    @Test("persistDownloadedImage writes into a cache directory whose path contains spaces")
    func persistDownloadedImageWritesIntoACacheDirectoryWhosePathContainsSpaces() throws {
        // The user-facing symptom that motivated the fix was that
        // remote images embedded in markdown previews re-downloaded on
        // every render for macOS users whose home directory contains a
        // space (e.g. "/Users/First Last/Library/Caches/..."). The
        // root cause: `URL.path()` on Swift 6 returns a
        // percent-encoded string, but `FileManager.fileExists(atPath:)`
        // (used by the cache-overwrite branch) expects the decoded
        // native path — so the existence check always returned false
        // even when the file was already in cache. Pin the
        // `percentEncoded: false` form by exercising the helper
        // through a spaced cache dir end to end.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let spacedCacheDir = temp.appendingPathComponent("Image Cache With Spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: spacedCacheDir, withIntermediateDirectories: true)

        // Stand-in for the temp file URLSession hands back from a
        // download — `persistDownloadedImage` copies it into the
        // permanent cache dir.
        let stagedSource = temp.appendingPathComponent("incoming.png", isDirectory: false)
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try payload.write(to: stagedSource)

        let loader = PreviewRemoteImageLoader(cacheDirectory: spacedCacheDir)
        let remoteURL = URL(string: "https://example.com/with%20spaces/photo.png")!

        let cached = loader.persistDownloadedImage(from: stagedSource, remoteURL: remoteURL, response: nil)
        #expect(cached != nil)
        if let cached {
            // The cache landed under the spaced directory and is reachable
            // via the decoded-path FileManager API.
            #expect(cached.deletingLastPathComponent().standardizedFileURL == spacedCacheDir.standardizedFileURL)
            #expect(FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)))
            #expect(try Data(contentsOf: cached) == payload)
        }

        // Second persist call with a fresh staged file must overwrite
        // the existing cache entry (the cache-overwrite branch is the
        // one that touches `fileExists` + `removeItem` against the
        // already-spaced destination URL). Without the
        // percentEncoded:false fix the existence check returned false,
        // the removeItem step ran on a non-existent decoded path, and
        // copyItem then threw "file already exists" because the
        // copyItem path is decoded and DOES see the file.
        let restagedSource = temp.appendingPathComponent("incoming-2.png", isDirectory: false)
        let secondPayload = Data([0x01, 0x02])
        try secondPayload.write(to: restagedSource)

        let recached = loader.persistDownloadedImage(from: restagedSource, remoteURL: remoteURL, response: nil)
        #expect(recached != nil)
        if let recached {
            #expect(try Data(contentsOf: recached) == secondPayload)
        }
    }
}
