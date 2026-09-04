import Foundation

struct NostrEvent: Codable, Hashable {
    let id: String
    let pubkey: String
    let createdAt: Int
    let kind: Int
    let tags: [[String]]
    let content: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case id, pubkey, kind, tags, content
        case createdAt = "created_at"
        case signature = "sig"
    }
}

struct NostrProfile: Equatable {
    let displayName: String?
    let username: String?
    let biography: String?
    let pictureURL: URL?

    init?(event: NostrEvent) {
        guard event.kind == 0,
              let data = event.content.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return nil
        }

        displayName = metadata.displayName ?? metadata.name
        username = metadata.nip05 ?? metadata.username
        biography = metadata.about
        pictureURL = metadata.picture.flatMap(URL.init(string:))
    }

    private struct Metadata: Decodable {
        let name: String?
        let displayName: String?
        let username: String?
        let nip05: String?
        let about: String?
        let picture: String?

        enum CodingKeys: String, CodingKey {
            case name, username, nip05, about, picture
            case displayName = "display_name"
        }
    }
}
