import Foundation
import OSLog

final class BlossomImportCoordinator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "NostrBackup",
        category: "BlossomImport"
    )

    private let archiveStore: NotesArchiveStore
    private let mediaStore: BlossomMediaStore
    private let mediaClient: BlossomMediaClient
    private static let defaultFallbackServers = [
        URL(string: "https://blossom.primal.net")!
    ]

    init(
        archiveStore: NotesArchiveStore = NotesArchiveStore(),
        mediaStore: BlossomMediaStore = BlossomMediaStore(),
        mediaClient: BlossomMediaClient = BlossomMediaClient()
    ) {
        self.archiveStore = archiveStore
        self.mediaStore = mediaStore
        self.mediaClient = mediaClient
    }

    func importMedia(for npub: String) async throws -> BlossomImportSummary {
        let normalizedNpub = npub.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let publicKey = try NpubDecoder.publicKey(from: npub)
        let events = try archiveStore.allEvents(for: npub)
        guard !events.isEmpty else { throw BlossomImportError.noArchivedNotes }

        // Note archives also contain quoted/referenced events and their profiles.
        // Only the requested account's own events may contribute media here.
        let authoredEvents = events.filter { $0.pubkey == publicKey }
        Self.logger.info(
            "Starting import for pubkey \(publicKey, privacy: .public): \(events.count) archived events, \(authoredEvents.count) authored events"
        )

        let references = BlossomMediaReference.find(in: authoredEvents)
        guard !references.isEmpty else {
            Self.logger.info("No hash-addressed media found in the account's authored events")
            throw BlossomImportError.noSupportedMedia
        }
        Self.logger.info("Discovered \(references.count) unique media hashes in authored events")
        let fallbackServers = Self.blossomServers(in: authoredEvents)
            + Self.defaultFallbackServers
        let serverList = fallbackServers.map(\.absoluteString).joined(separator: ",")
        Self.logger.info("Fallback Blossom servers: \(serverList, privacy: .public)")

        var downloadedCount = 0
        var alreadyStoredCount = 0
        var failedCount = 0
        for reference in references {
            let eventIDs = reference.eventIDs.sorted().joined(separator: ",")
            Self.logger.info(
                "Processing hash \(reference.hash, privacy: .public) from event(s) \(eventIDs, privacy: .public) with \(reference.sourceURLs.count) source(s)"
            )
            do {
                if try mediaStore.contains(reference.hash) {
                    try mediaStore.registerExisting(reference)
                    alreadyStoredCount += 1
                    Self.logger.info("Already stored hash \(reference.hash, privacy: .public)")
                    continue
                }

                if try await downloadAndSave(
                    reference,
                    expectedOwnerNpub: normalizedNpub,
                    fallbackServers: fallbackServers
                ) {
                    downloadedCount += 1
                    Self.logger.info("Imported hash \(reference.hash, privacy: .public)")
                } else {
                    alreadyStoredCount += 1
                    Self.logger.info("Hash became available locally while importing: \(reference.hash, privacy: .public)")
                }
            } catch {
                failedCount += 1
                Self.logger.error(
                    "Failed hash \(reference.hash, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        Self.logger.info(
            "Import finished: \(references.count) discovered, \(downloadedCount) downloaded, \(alreadyStoredCount) already stored, \(failedCount) failed"
        )

        return BlossomImportSummary(
            discoveredCount: references.count,
            downloadedCount: downloadedCount,
            alreadyStoredCount: alreadyStoredCount,
            failedCount: failedCount
        )
    }

    func saveMedia(_ reference: BlossomMediaReference) async throws -> Bool {
        if try mediaStore.contains(reference.hash) {
            try mediaStore.registerExisting(reference)
            return false
        }

        return try await downloadAndSave(
            reference,
            expectedOwnerNpub: nil,
            fallbackServers: Self.defaultFallbackServers
        )
    }

    private func downloadAndSave(
        _ reference: BlossomMediaReference,
        expectedOwnerNpub: String?,
        fallbackServers: [URL]
    ) async throws -> Bool {
        var lastError: Error?
        let candidateURLs = Self.downloadCandidates(for: reference, fallbackServers: fallbackServers)
        Self.logger.info(
            "Trying \(candidateURLs.count) download candidate(s) for hash \(reference.hash, privacy: .public)"
        )
        for sourceURL in candidateURLs {
            Self.logger.info(
                "Downloading hash \(reference.hash, privacy: .public) from \(sourceURL.absoluteString, privacy: .public)"
            )
            do {
                let download = try await mediaClient.download(from: sourceURL)
                if let expectedOwnerNpub,
                   let ownerNpub = download.ownerNpub,
                   ownerNpub != expectedOwnerNpub {
                    Self.logger.warning(
                        "Rejected hash \(reference.hash, privacy: .public): server owner \(ownerNpub, privacy: .public) does not match requested owner \(expectedOwnerNpub, privacy: .public)"
                    )
                    lastError = BlossomImportError.ownerMismatch
                    continue
                }

                let saved = try mediaStore.save(
                    download.data,
                    for: reference.preferring(sourceURL),
                    reportedOriginalHash: download.reportedOriginalHash
                )
                if download.actualHash == reference.hash {
                    Self.logger.info(
                        "Verified exact \(download.data.count)-byte blob for hash \(reference.hash, privacy: .public) from \(download.finalURL.absoluteString, privacy: .public)"
                    )
                } else {
                    Self.logger.info(
                        "Stored transformed \(download.data.count)-byte media for original hash \(reference.hash, privacy: .public); actual content hash is \(download.actualHash, privacy: .public), type is \(download.contentType ?? "unknown", privacy: .public)"
                    )
                }
                return saved
            } catch {
                lastError = error
                Self.logger.warning(
                    "Source failed for hash \(reference.hash, privacy: .public) at \(sourceURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        throw lastError ?? URLError(.badURL)
    }

    private static func blossomServers(in events: [NostrEvent]) -> [URL] {
        guard let serverListEvent = events
            .filter({ $0.kind == 10_063 })
            .max(by: { $0.createdAt < $1.createdAt }) else {
            return []
        }

        return serverListEvent.tags.compactMap { tag in
            guard tag.count > 1,
                  tag[0] == "server",
                  let url = URL(string: tag[1]),
                  url.scheme?.lowercased() == "https",
                  url.host != nil else {
                return nil
            }
            return url
        }
    }

    private static func downloadCandidates(
        for reference: BlossomMediaReference,
        fallbackServers: [URL]
    ) -> [URL] {
        var fallbackURLs: [URL] = []
        let fileExtension = reference.sourceURL.pathExtension

        for server in fallbackServers {
            let bareURL = server.appendingPathComponent(reference.hash)
            if !fileExtension.isEmpty {
                fallbackURLs.append(bareURL.appendingPathExtension(fileExtension))
            }
            fallbackURLs.append(bareURL)
        }

        // Ditto's blob endpoint can accept a connection and then stall. Prefer
        // the account/default mirrors for those URLs; retain Ditto as a fallback.
        let sourceHosts = Set(reference.sourceURLs.compactMap { $0.host?.lowercased() })
        let candidates = sourceHosts.contains("blossom.ditto.pub")
            ? fallbackURLs + reference.sourceURLs
            : reference.sourceURLs + fallbackURLs

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }
}
