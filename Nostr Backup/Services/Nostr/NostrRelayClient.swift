import Foundation

struct NostrRelayClient {
    private let pageSize = 10_000
    private let relayURLs: [URL]

    init(relayURLs: [URL] = RelayConfiguration.defaultRelayURLs) {
        self.relayURLs = relayURLs
    }

    var relayAddresses: [String] {
        relayURLs.map(\.absoluteString)
    }

    func fetchAuthoredEvents(publicKey: String) async throws -> [NostrEvent] {
        var uniqueEvents: [String: NostrEvent] = [:]
        var responded = false

        for relayURL in relayURLs {
            do {
                let events = try await fetchAllEvents(from: relayURL, publicKey: publicKey)
                events.forEach { uniqueEvents[$0.id] = $0 }
                responded = true
            } catch {
                continue
            }
        }

        guard responded else { throw NostrImportError.noRelayResponded }
        return uniqueEvents.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Linked notes are fetched separately so an unavailable quoted event never
    /// prevents an otherwise valid personal backup from completing.
    func fetchReferencedEvents(eventIDs: [String]) async -> [NostrEvent] {
        guard !eventIDs.isEmpty else { return [] }
        var uniqueEvents: [String: NostrEvent] = [:]

        for relayURL in relayURLs {
            guard let events = try? await fetchPage(
                from: relayURL,
                filter: ["ids": eventIDs, "limit": eventIDs.count]
            ) else { continue }
            events.forEach { uniqueEvents[$0.id] = $0 }
        }
        return uniqueEvents.values.sorted { $0.createdAt < $1.createdAt }
    }

    func fetchProfiles(publicKeys: [String]) async -> [NostrEvent] {
        guard !publicKeys.isEmpty else { return [] }
        var uniqueEvents: [String: NostrEvent] = [:]

        for relayURL in relayURLs {
            guard let events = try? await fetchPage(
                from: relayURL,
                filter: ["authors": publicKeys, "kinds": [0], "limit": publicKeys.count]
            ) else { continue }
            events.forEach { uniqueEvents[$0.id] = $0 }
        }
        return uniqueEvents.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func fetchAllEvents(from relayURL: URL, publicKey: String) async throws -> [NostrEvent] {
        var allEvents: [NostrEvent] = []
        var until: Int?

        while true {
            var filter: [String: Any] = ["authors": [publicKey], "limit": pageSize]
            if let until { filter["until"] = until }
            let page = try await fetchPage(from: relayURL, filter: filter)
            allEvents.append(contentsOf: page)

            guard page.count == pageSize, let oldestEvent = page.min(by: { $0.createdAt < $1.createdAt }) else {
                return allEvents
            }

            // `until` is inclusive in a Nostr filter, so move past the oldest event.
            guard oldestEvent.createdAt > 0 else { return allEvents }
            until = oldestEvent.createdAt - 1
        }
    }

    private func fetchPage(from relayURL: URL, filter: [String: Any]) async throws -> [NostrEvent] {
        let task = URLSession.shared.webSocketTask(with: relayURL)
        task.resume()

        let timeout = Task {
            try? await Task.sleep(for: .seconds(25))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }

        let subscriptionID = UUID().uuidString
        let request: [Any] = [
            "REQ",
            subscriptionID,
            filter
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard let requestString = String(data: requestData, encoding: .utf8) else { return [] }
        try await task.send(.string(requestString))

        var events: [NostrEvent] = []
        while true {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let string):
                data = Data(string.utf8)
            case .data(let receivedData):
                data = receivedData
            @unknown default:
                continue
            }

            guard let messageParts = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let type = messageParts.first as? String else {
                continue
            }

            if type == "EOSE", messageParts.dropFirst().first as? String == subscriptionID {
                return events
            }

            guard type == "EVENT",
                  messageParts.count >= 3,
                  messageParts[1] as? String == subscriptionID else {
                continue
            }

            let eventData = try JSONSerialization.data(withJSONObject: messageParts[2])
            if let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {
                events.append(event)
            }
        }
    }
}
