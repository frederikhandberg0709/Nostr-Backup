import Cocoa

@MainActor
final class ProfileHeaderView: NSView {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let usernameLabel = NSTextField(labelWithString: "")
    private let biographyLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInterface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInterface()
    }

    func configure(with profile: NostrProfile?, fallbackNpub: String) {
        nameLabel.stringValue = profile?.displayName ?? "Nostr account"
        usernameLabel.stringValue = profile?.username ?? abbreviated(fallbackNpub)
        biographyLabel.stringValue = profile?.biography ?? "No biography published."

        imageView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "Profile picture")
        if let pictureURL = profile?.pictureURL {
            loadImage(from: pictureURL)
        }
    }

    private func configureInterface() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.symbolConfiguration = .init(pointSize: 52, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        usernameLabel.font = .systemFont(ofSize: 13)
        usernameLabel.textColor = .secondaryLabelColor
        biographyLabel.font = .systemFont(ofSize: 13)
        biographyLabel.textColor = .secondaryLabelColor
        biographyLabel.maximumNumberOfLines = 3

        let details = NSStackView(views: [nameLabel, usernameLabel, biographyLabel])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 3

        let stack = NSStackView(views: [imageView, details])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 58),
            imageView.heightAnchor.constraint(equalToConstant: 58),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    private func loadImage(from url: URL) {
        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let image = NSImage(data: data) else { return }
            self?.imageView.image = image
        }
    }

    private func abbreviated(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        return "\(npub.prefix(10))…\(npub.suffix(5))"
    }
}
