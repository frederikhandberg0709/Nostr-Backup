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
        let imageView = AspectFillImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "Profile picture")
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.symbolConfiguration = .init(pointSize: 68, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 36
        imageView.layer?.masksToBounds = true
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        profileStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        biography.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let identity = NSStackView(views: [imageView, profileStack])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 14

        let eventsStat = stat(title: "Events", value: "\(events.count) saved")
        let mediaStat = stat(title: "Media storage", value: "\(mediaStats.fileCount) files · \(ByteCountFormatter.string(fromByteCount: Int64(mediaStats.byteCount), countStyle: .file))")
        let stats = NSStackView(views: [eventsStat, mediaStat])
        stats.orientation = .vertical
        stats.alignment = .leading
        stats.spacing = 12

        let content = NSStackView(views: [identity, NSBox(), stats])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        content.edgeInsets = NSEdgeInsets(top: 44, left: 42, bottom: 28, right: 42)
        content.translatesAutoresizingMaskIntoConstraints = false

        // The scroll view aligns a document view that is shorter than its clip view
        // to the bottom. Keep a document container at least viewport-height and pin
        // the actual dashboard content to its top instead.
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 72),
            imageView.heightAnchor.constraint(equalToConstant: 72),
            profileStack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -84)
        ])

        if let pictureURL = profile?.pictureURL {
            Task { [weak imageView] in
                guard let data = try? await URLSession.shared.data(from: pictureURL).0,
                      let image = NSImage(data: data) else { return }
                imageView?.image = image
                imageView?.contentTintColor = nil
            }
        }
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
private final class AspectFillImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            super.draw(dirtyRect)
            return
        }

        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1, respectFlipped: isFlipped, hints: nil)
    }
}

@MainActor
final class MediaLibraryViewController: NSViewController {
    var onImportBlossom: (() async throws -> BlossomImportSummary)?

    private let blossomButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    override func loadView() { view = NSVisualEffectView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let detail = NSTextField(labelWithString: "Your local media library will appear here.")
        detail.textColor = .secondaryLabelColor
        configure(button: blossomButton, title: "Import Blossom", imageName: "photo.on.rectangle", action: #selector(importBlossom(_:)))
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [detail, blossomButton, statusLabel])
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

    private func configure(button: NSButton, title: String, imageName: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.controlSize = .large
        button.font = .systemFont(ofSize: 14, weight: .semibold)
    }

    @objc private func importBlossom(_ sender: NSButton) {
        guard let onImportBlossom else { return }
        blossomButton.isEnabled = false
        statusLabel.stringValue = "Importing Blossom media…"
        statusLabel.textColor = .secondaryLabelColor

        Task { [weak self] in
            do {
                let summary = try await onImportBlossom()
                self?.statusLabel.stringValue = "Media import complete: \(summary.downloadedCount) downloaded, \(summary.alreadyStoredCount) already stored."
                self?.statusLabel.textColor = summary.failedCount == 0 ? .secondaryLabelColor : .systemOrange
            } catch {
                self?.statusLabel.stringValue = error.localizedDescription
                self?.statusLabel.textColor = .systemRed
            }
            self?.blossomButton.isEnabled = true
        }
    }
}
