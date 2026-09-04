import Foundation

enum RelayConfiguration {
    static let defaultRelayURLs = [
        URL(string: "wss://relay.damus.io")!,
        URL(string: "wss://nos.lol")!,
        URL(string: "wss://relay.ditto.pub")!,
        URL(string: "wss://relay.primal.net")!
    ]
}
