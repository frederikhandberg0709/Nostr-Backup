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
        let authoredEvents = try await relayClient.fetchAuthoredEvents(publicKey: publicKey)
        let linkedEventIDs = Self.linkedEventIDs(in: authoredEvents)
        let linkedEvents = await relayClient.fetchReferencedEvents(eventIDs: Array(linkedEventIDs))
        let linkedProfiles = await relayClient.fetchProfiles(publicKeys: Array(Set(linkedEvents.map(\.pubkey))))
        var eventsByID = Dictionary(uniqueKeysWithValues: authoredEvents.map { ($0.id, $0) })
        linkedEvents.forEach { eventsByID[$0.id] = $0 }
        linkedProfiles.forEach { eventsByID[$0.id] = $0 }
        let events = Array(eventsByID.values)
        let archiveURL = try archiveStore.save(
            npub: npub,
            publicKey: publicKey,
            relays: relayClient.relayAddresses,
            events: events
        )
        let profile = events
            .filter { $0.kind == 0 && $0.pubkey == publicKey }
            .max { $0.createdAt < $1.createdAt }
            .flatMap(NostrProfile.init(event:))

        return NotesImportSummary(
            npub: npub,
            eventCount: events.count,
            archiveURL: archiveURL,
            profile: profile
        )
    }

    private static func linkedEventIDs(in events: [NostrEvent]) -> Set<String> {
        let pattern = #"nostr:nevent1[023456789acdefghjklmnpqrstuvwxyz]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        var eventIDs = Set<String>()
        for event in events {
            let range = NSRange(event.content.startIndex..., in: event.content)
            for match in expression.matches(in: event.content, range: range) {
                guard let range = Range(match.range, in: event.content) else { continue }
                if let eventID = NeventDecoder.eventID(from: String(event.content[range])) {
                    eventIDs.insert(eventID)
                }
            }
        }
        return eventIDs
    }
}
