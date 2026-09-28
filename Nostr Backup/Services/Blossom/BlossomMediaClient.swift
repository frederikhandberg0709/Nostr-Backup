import CryptoKit
import Foundation

struct BlossomMediaDownload {
    let data: Data
    let finalURL: URL
    let contentType: String?
    let reportedOriginalHash: String?
    let ownerNpub: String?

    var actualHash: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct BlossomMediaClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Move on to another content-addressed host when a server accepts
            // the connection but stops delivering bytes.
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 10 * 60
            self.session = URLSession(configuration: configuration)
        }
    }

    func download(from url: URL) async throws -> BlossomMediaDownload {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return BlossomMediaDownload(
            data: data,
            finalURL: response.url ?? url,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            reportedOriginalHash: response.value(forHTTPHeaderField: "X-Original-Content-SHA256")?.lowercased(),
            ownerNpub: response.value(forHTTPHeaderField: "X-Owner-Npub")?.lowercased()
        )
    }
}
