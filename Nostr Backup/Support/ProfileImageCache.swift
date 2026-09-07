import CryptoKit
import Foundation

/// Stores downloaded profile image data by URL. A changed Nostr `picture` URL
/// naturally results in a fresh download, while the existing URL is reused.
actor ProfileImageCache {
    static let shared = ProfileImageCache()

    private var memoryCache: [URL: Data] = [:]
    private var inFlightRequests: [URL: Task<Data?, Never>] = [:]

    private let cacheDirectory: URL = {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cachesDirectory.appendingPathComponent("NostrBackup/ProfilePictures", isDirectory: true)
    }()

    func data(for url: URL) async -> Data? {
        if let data = memoryCache[url] {
            return data
        }

        if let request = inFlightRequests[url] {
            return await request.value
        }

        let cacheFileURL = fileURL(for: url)
        let request = Task.detached { [cacheDirectory] () -> Data? in
            if let cachedData = try? Data(contentsOf: cacheFileURL) {
                return cachedData
            }

            guard let data = try? await URLSession.shared.data(from: url).0 else {
                return nil
            }

            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheFileURL, options: .atomic)
            return data
        }
        inFlightRequests[url] = request

        let data = await request.value
        inFlightRequests[url] = nil
        if let data {
            memoryCache[url] = data
        }
        return data
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(fileName).appendingPathExtension("image")
    }
}
