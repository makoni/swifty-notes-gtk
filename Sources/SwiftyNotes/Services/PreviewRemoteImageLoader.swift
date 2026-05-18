import Adwaita
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

typealias PreviewRemoteImageLoadCompletion = @MainActor @Sendable (URL?) -> Void
typealias PreviewRemoteImageLoadHandler = (URL, @escaping PreviewRemoteImageLoadCompletion) -> Void

final class PreviewRemoteImageLoader: @unchecked Sendable {
    static let shared = PreviewRemoteImageLoader()

    private let session: URLSession
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let lock = NSLock()
    private var cachedFiles: [URL: URL] = [:]
    private var inFlight: [URL: [PreviewRemoteImageLoadCompletion]] = [:]

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        cacheDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
            .appendingPathComponent("preview-image-cache", isDirectory: true),
    ) {
        self.session = session
        self.fileManager = fileManager
        self.cacheDirectory = cacheDirectory
    }

    func loadImage(_ remoteURL: URL, completion: @escaping PreviewRemoteImageLoadCompletion) {
        lock.lock()
        if let cachedFile = cachedFiles[remoteURL],
           // `percentEncoded: false` because FileManager expects a
           // decoded native path. Without this the cache check fails
           // for any user whose cache lives under a path with spaces
           // (e.g. macOS users with "/Users/First Last/" home dirs) —
           // same regression class as issue #24.
           fileManager.fileExists(atPath: cachedFile.path(percentEncoded: false))
        {
            lock.unlock()
            dispatch(cachedFile, completion: completion)
            return
        }

        if inFlight[remoteURL] != nil {
            inFlight[remoteURL, default: []].append(completion)
            lock.unlock()
            return
        }

        inFlight[remoteURL] = [completion]
        lock.unlock()
        startDownload(for: remoteURL)
    }
}

private extension PreviewRemoteImageLoader {
    func startDownload(for remoteURL: URL) {
        session.downloadTask(with: remoteURL) { [weak self] temporaryURL, response, _ in
            guard let self else { return }
            let localURL = persistDownloadedImage(
                from: temporaryURL,
                remoteURL: remoteURL,
                response: response,
            )
            lock.lock()
            let completions = inFlight.removeValue(forKey: remoteURL) ?? []
            if let localURL {
                cachedFiles[remoteURL] = localURL
            }
            lock.unlock()

            for completion in completions {
                dispatch(localURL, completion: completion)
            }
        }.resume()
    }

    func persistDownloadedImage(from temporaryURL: URL?, remoteURL: URL, response: URLResponse?) -> URL? {
        guard let temporaryURL else { return nil }

        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let destinationURL = cacheDirectory.appendingPathComponent(cacheFilename(for: remoteURL, response: response), isDirectory: false)
            // See cache-lookup comment above — FileManager wants the
            // decoded path, not the URL-encoded form `URL.path()` ships.
            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: temporaryURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    func cacheFilename(for remoteURL: URL, response: URLResponse?) -> String {
        let hash = stableHash(of: remoteURL.absoluteString)
        let ext = preferredExtension(for: remoteURL, response: response)
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    func preferredExtension(for remoteURL: URL, response: URLResponse?) -> String {
        if let suggestedFilename = response?.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggestedFilename.isEmpty
        {
            let ext = URL(fileURLWithPath: suggestedFilename).pathExtension.lowercased()
            if !ext.isEmpty {
                return ext
            }
        }

        let pathExtension = remoteURL.pathExtension.lowercased()
        if !pathExtension.isEmpty {
            return pathExtension
        }

        switch response?.mimeType?.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/svg+xml":
            return "svg"
        default:
            return ""
        }
    }

    func stableHash(of string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    func dispatch(_ localURL: URL?, completion: @escaping PreviewRemoteImageLoadCompletion) {
        MainContext.idle {
            completion(localURL)
        }
    }
}
