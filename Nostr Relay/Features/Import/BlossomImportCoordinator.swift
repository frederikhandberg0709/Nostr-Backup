import Foundation

final class BlossomImportCoordinator {
    private let archiveStore: NotesArchiveStore
    private let mediaStore: BlossomMediaStore
    private let mediaClient: BlossomMediaClient

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
        let events = try archiveStore.allEvents(for: npub)
        guard !events.isEmpty else { throw BlossomImportError.noArchivedNotes }

        let references = BlossomMediaReference.find(in: events)
        guard !references.isEmpty else { throw BlossomImportError.noSupportedMedia }

        var downloadedCount = 0
        var alreadyStoredCount = 0
        var failedCount = 0
        for reference in references {
            do {
                if try mediaStore.contains(reference.hash) {
                    try mediaStore.registerExisting(reference)
                    alreadyStoredCount += 1
                    continue
                }

                let data = try await mediaClient.download(from: reference.sourceURL)
                if try mediaStore.save(data, for: reference) {
                    downloadedCount += 1
                } else {
                    alreadyStoredCount += 1
                }
            } catch {
                failedCount += 1
            }
        }

        return BlossomImportSummary(
            discoveredCount: references.count,
            downloadedCount: downloadedCount,
            alreadyStoredCount: alreadyStoredCount,
            failedCount: failedCount
        )
    }
}
