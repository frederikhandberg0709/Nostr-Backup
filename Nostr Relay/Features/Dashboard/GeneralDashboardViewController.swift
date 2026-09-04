import Cocoa

@MainActor
final class GeneralDashboardViewController: NSViewController {
    private let npub: String
    private let events: [NostrEvent]

    init(npub: String, events: [NostrEvent]) {
        self.npub = npub
        self.events = events
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSVisualEffectView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    private func buildInterface() {
        let profile = events.filter { $0.kind == 0 }.max { $0.createdAt < $1.createdAt }.flatMap(NostrProfile.init(event:))
        let mediaStats = BlossomMediaStore().storageStatistics()
        let title = NSTextField(labelWithString: "General")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let name = NSTextField(labelWithString: profile?.displayName ?? "Nostr account")
        name.font = .systemFont(ofSize: 19, weight: .semibold)
        let username = NSTextField(labelWithString: profile?.username ?? abbreviated(npub))
        username.textColor = .secondaryLabelColor
        let biography = NSTextField(wrappingLabelWithString: profile?.biography ?? "No biography published.")
        biography.textColor = .secondaryLabelColor
        let profileStack = NSStackView(views: [name, username, biography])
        profileStack.orientation = .vertical
        profileStack.alignment = .leading
        profileStack.spacing = 5

        let eventsStat = stat(title: "Events", value: "\(events.count) saved")
        let mediaStat = stat(title: "Media storage", value: "\(mediaStats.fileCount) files · \(ByteCountFormatter.string(fromByteCount: Int64(mediaStats.byteCount), countStyle: .file))")
        let stats = NSStackView(views: [eventsStat, mediaStat])
        stats.orientation = .vertical
        stats.alignment = .leading
        stats.spacing = 12

        let content = NSStackView(views: [title, profileStack, NSBox(), stats])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 42),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -42),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 44)
        ])
    }

    private func stat(title: String, value: String) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 16, weight: .medium)
        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func abbreviated(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        return "\(npub.prefix(10))…\(npub.suffix(5))"
    }
}

@MainActor
final class MediaLibraryViewController: NSViewController {
    override func loadView() { view = NSVisualEffectView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = NSTextField(labelWithString: "Media")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let detail = NSTextField(labelWithString: "Your local media library will appear here.")
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 42),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 44)
        ])
    }
}
