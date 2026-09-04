import Foundation

struct NotesArchiveStore {
    private let fileManager: FileManager
    private let now: () -> Date

    init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.now = now
    }

    func save(npub: String, publicKey: String, relays: [String], events: [NostrEvent]) throws -> URL {
        let directory = try archiveDirectory()
        let timestamp = now()
        let archive = NotesArchive(
            exportedAt: timestamp,
            npub: npub,
            publicKey: publicKey,
            relays: relays,
            events: events
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)

        let destination = nextAvailableURL(in: directory, date: timestamp)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func archiveDirectory() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("Nostr Relay", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func nextAvailableURL(in directory: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let prefix = "notes-\(formatter.string(from: date))"

        var number = 1
        while true {
            let suffix = number == 1 ? "" : "-\(number)"
            let url = directory.appendingPathComponent("\(prefix)\(suffix).json")
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
            number += 1
        }
    }
}

private struct NotesArchive: Encodable {
    let formatVersion = 1
    let exportedAt: Date
    let npub: String
    let publicKey: String
    let relays: [String]
    let events: [NostrEvent]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case exportedAt = "exported_at"
        case npub, relays, events
        case publicKey = "public_key"
    }
}
