import Foundation

struct BlossomMediaReference: Hashable {
    let hash: String
    let sourceURL: URL
    let eventIDs: Set<String>

    var fileExtension: String? {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard !fileExtension.isEmpty,
              fileExtension.count <= 10,
              fileExtension.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return fileExtension
    }

    static let supportedHosts: Set<String> = ["blossom.primal.net", "nostr.build", "blossom.ditto.pub"]

    static func find(in events: [NostrEvent]) -> [BlossomMediaReference] {
        var references: [String: BlossomMediaReference] = [:]

        for event in events {
            let values = [event.content] + event.tags.flatMap { $0 }
            for value in values {
                for url in urls(in: value) {
                    guard let host = url.host?.lowercased(),
                          supportedHosts.contains(host),
                          let hash = blossomHash(from: url) else {
                        continue
                    }

                    if var existing = references[hash] {
                        existing = BlossomMediaReference(
                            hash: existing.hash,
                            sourceURL: existing.sourceURL,
                            eventIDs: existing.eventIDs.union([event.id])
                        )
                        references[hash] = existing
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
            let match = String(value[Range($0.range, in: value)!]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?") )
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
            return "No media from a supported Blossom host was found."
        case .integrityCheckFailed:
            return "A downloaded file did not match its Blossom hash."
        }
    }
}
