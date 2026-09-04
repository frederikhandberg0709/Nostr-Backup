import Foundation

final class NotesImportCoordinator {
    private let relayClient: NostrRelayClient
    private let archiveStore: NotesArchiveStore

    init(relayClient: NostrRelayClient = NostrRelayClient(), archiveStore: NotesArchiveStore = NotesArchiveStore()) {
        self.relayClient = relayClient
        self.archiveStore = archiveStore
    }

    func importNotes(for npub: String) async throws -> NotesImportSummary {
        let publicKey = try NpubDecoder.publicKey(from: npub)
        let events = try await relayClient.fetchAuthoredEvents(publicKey: publicKey)
        let archiveURL = try archiveStore.save(
            npub: npub,
            publicKey: publicKey,
            relays: ["wss://relay.damus.io", "wss://nos.lol"],
            events: events
        )
        let profile = events
            .filter { $0.kind == 0 }
            .max { $0.createdAt < $1.createdAt }
            .flatMap(NostrProfile.init(event:))

        return NotesImportSummary(
            npub: npub,
            eventCount: events.count,
            archiveURL: archiveURL,
            profile: profile
        )
    }
}
