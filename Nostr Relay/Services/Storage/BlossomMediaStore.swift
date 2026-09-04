import CryptoKit
import Foundation

struct BlossomMediaStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func contains(_ hash: String) throws -> Bool {
        try existingMediaURL(for: hash) != nil
    }

    @discardableResult
    func save(_ data: Data, for reference: BlossomMediaReference) throws -> Bool {
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualHash == reference.hash else { throw BlossomImportError.integrityCheckFailed }

        let mediaURL = try preferredMediaURL(for: reference)
        let existingURL = try existingMediaURL(for: reference.hash)
        let wasDownloaded = existingURL == nil
        if wasDownloaded {
            try data.write(to: mediaURL, options: .atomic)
        } else if let existingURL, existingURL != mediaURL {
            try fileManager.moveItem(at: existingURL, to: mediaURL)
        }
        try updateManifest(with: reference, mediaURL: mediaURL)
        return wasDownloaded
    }

    func registerExisting(_ reference: BlossomMediaReference) throws {
        guard let existingURL = try existingMediaURL(for: reference.hash) else { return }
        let preferredURL = try preferredMediaURL(for: reference)
        if existingURL != preferredURL {
            try fileManager.moveItem(at: existingURL, to: preferredURL)
        }
        try updateManifest(with: reference, mediaURL: preferredURL)
    }

    private func preferredMediaURL(for reference: BlossomMediaReference) throws -> URL {
        let fileName = reference.fileExtension.map { "\(reference.hash).\($0)" } ?? reference.hash
        return try mediaDirectory().appendingPathComponent(fileName)
    }

    private func existingMediaURL(for hash: String) throws -> URL? {
        let directory = try mediaDirectory()
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first {
            $0.deletingPathExtension().lastPathComponent == hash || $0.lastPathComponent == hash
        }
    }

    private func mediaDirectory() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("Nostr Relay", isDirectory: true)
            .appendingPathComponent("Blossom", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func updateManifest(with reference: BlossomMediaReference, mediaURL: URL) throws {
        let directory = try mediaDirectory()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        let existing = (try? Data(contentsOf: manifestURL)).flatMap { try? decoder.decode(BlossomManifest.self, from: $0) }
        var records = existing?.records ?? [:]
        let oldRecord = records[reference.hash]
        records[reference.hash] = BlossomMediaRecord(
            hash: reference.hash,
            sourceURL: reference.sourceURL.absoluteString,
            sourceHost: reference.sourceURL.host ?? "",
            eventIDs: Array(Set(oldRecord?.eventIDs ?? []).union(reference.eventIDs)).sorted(),
            importedAt: oldRecord?.importedAt ?? Date(),
            fileName: mediaURL.lastPathComponent,
            byteCount: (try? fileManager.attributesOfItem(atPath: mediaURL.path)[.size] as? NSNumber)?.intValue
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(BlossomManifest(records: records)).write(to: manifestURL, options: .atomic)
    }
}

private struct BlossomManifest: Codable {
    let formatVersion: Int
    let records: [String: BlossomMediaRecord]

    init(records: [String: BlossomMediaRecord]) {
        formatVersion = 1
        self.records = records
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case records
    }
}

private struct BlossomMediaRecord: Codable {
    let hash: String
    let sourceURL: String
    let sourceHost: String
    let eventIDs: [String]
    let importedAt: Date
    let fileName: String?
    let byteCount: Int?

    enum CodingKeys: String, CodingKey {
        case hash
        case sourceURL = "source_url"
        case sourceHost = "source_host"
        case eventIDs = "event_ids"
        case importedAt = "imported_at"
        case fileName = "file_name"
        case byteCount = "byte_count"
    }
}
