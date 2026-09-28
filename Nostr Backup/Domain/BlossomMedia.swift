import Foundation

struct BlossomMediaReference: Hashable {
    let hash: String
    let sourceURLs: [URL]
    let eventIDs: Set<String>

    var sourceURL: URL { sourceURLs[0] }

    init(hash: String, sourceURL: URL, eventIDs: Set<String>) {
        self.init(hash: hash, sourceURLs: [sourceURL], eventIDs: eventIDs)
    }

    private init(hash: String, sourceURLs: [URL], eventIDs: Set<String>) {
        self.hash = hash
        self.sourceURLs = sourceURLs
        self.eventIDs = eventIDs
    }

    func preferring(_ sourceURL: URL) -> BlossomMediaReference {
        BlossomMediaReference(
            hash: hash,
            sourceURLs: [sourceURL] + sourceURLs.filter { $0 != sourceURL },
            eventIDs: eventIDs
        )
    }

    var fileExtension: String? {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard !fileExtension.isEmpty,
              fileExtension.count <= 10,
              fileExtension.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return fileExtension
    }

    static func find(in events: [NostrEvent]) -> [BlossomMediaReference] {
        var references: [String: BlossomMediaReference] = [:]

        for event in events {
            let values = [event.content] + event.tags.flatMap { $0 }
            for value in values {
                for url in urls(in: value) {
                    guard url.scheme?.lowercased() == "https",
                          url.host != nil,
                          let hash = blossomHash(from: url) else {
                        continue
                    }

                    if let existing = references[hash] {
                        let sourceURLs = Array(Set(existing.sourceURLs + [url]))
                            .sorted { $0.absoluteString < $1.absoluteString }
                        references[hash] = BlossomMediaReference(
                            hash: existing.hash,
                            sourceURLs: sourceURLs,
                            eventIDs: existing.eventIDs.union([event.id])
                        )
                    } else {
                        references[hash] = BlossomMediaReference(
                            hash: hash,
                            sourceURL: url,
                            eventIDs: [event.id]
                        )
                    }
                }
            }
        }

        return references.values.sorted { $0.hash < $1.hash }
    }

    private static func urls(in value: String) -> [URL] {
        let pattern = #"https?://[^\s\"'<>]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            let match = String(value[Range($0.range, in: value)!])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            return URL(string: match)
        }
    }

    private static func blossomHash(from url: URL) -> String? {
        // Some Blossom servers serve a bare hash while others retain a file extension.
        let hash = url.deletingPathExtension().lastPathComponent.lowercased()
        guard hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash
    }
}

struct BlossomImportSummary {
    let discoveredCount: Int
    let downloadedCount: Int
    let alreadyStoredCount: Int
    let failedCount: Int
}

enum BlossomImportError: LocalizedError {
    case noArchivedNotes
    case noSupportedMedia
    case integrityCheckFailed

    var errorDescription: String? {
        switch self {
        case .noArchivedNotes:
            return "Import notes before importing Blossom media."
        case .noSupportedMedia:
            return "No hash-addressed Blossom media was found in the archived notes."
        case .integrityCheckFailed:
            return "A downloaded file did not match its Blossom hash."
        }
    }
}
