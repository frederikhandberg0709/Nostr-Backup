import Cocoa
import ImageIO

@MainActor
final class DashboardViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let npub: String
    private let events: [NostrEvent]
    private let linkedNotesByID: [String: NostrEvent]
    private let profilesByPublicKey: [String: NostrProfile]
    private let mediaStore = BlossomMediaStore()
    private let tableView = NSTableView()
    private var rowHeightReloadWorkItem: DispatchWorkItem?

    var onSaveMedia: ((BlossomMediaReference) async throws -> Bool)?

    init(npub: String, events: [NostrEvent]) {
        self.npub = npub
        if let publicKey = try? NpubDecoder.publicKey(from: npub) {
            self.events = events.filter { $0.kind == 1 && $0.pubkey == publicKey }.sorted { $0.createdAt > $1.createdAt }
        } else {
            self.events = events.filter { $0.kind == 1 }.sorted { $0.createdAt > $1.createdAt }
        }
        linkedNotesByID = Dictionary(uniqueKeysWithValues: events.filter { $0.kind == 1 }.map { ($0.id, $0) })
        profilesByPublicKey = events
            .filter { $0.kind == 0 }
            .sorted { $0.createdAt < $1.createdAt }
            .reduce(into: [:]) { profiles, event in
                if let profile = NostrProfile(event: event) { profiles[event.pubkey] = profile }
            }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSVisualEffectView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableViewColumnDidResize(_ notification: Notification) {
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<events.count))
        rowHeightReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                self.tableView.reloadData()
            }
        }
        rowHeightReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let event = events[row]
        let rowView = TimelineNoteRowView(event: event, linkedNotesByID: linkedNotesByID, profilesByPublicKey: profilesByPublicKey)
        rowView.onOpenMedia = { [weak self] reference in self?.openMedia(reference) }
        return rowView
    }

    private func buildInterface() {
        guard let background = view as? NSVisualEffectView else { return }
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active

        let subtitle = NSTextField(labelWithString: "\(events.count) notes saved locally · \(abbreviated(npub))")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let notesColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notes"))
        notesColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(notesColumn)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = 120 // An estimate for off-screen rows; Auto Layout supplies the final height.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        scrollView.documentView = tableView

        background.addSubview(subtitle)
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            subtitle.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 42),
            subtitle.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -42),
            subtitle.topAnchor.constraint(equalTo: background.topAnchor, constant: 30),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -24)
        ])
    }

    private func openMedia(_ reference: BlossomMediaReference) {
        let overlay = MediaFocusOverlay(reference: reference, mediaStore: mediaStore)
        overlay.onSave = { [weak self, weak overlay] reference in
            guard let self, let save = self.onSaveMedia else { return }
            overlay?.setSaving(true)
            do {
                _ = try await save(reference)
                overlay?.refresh()
            } catch {
                overlay?.showError(error.localizedDescription)
            }
            overlay?.setSaving(false)
        }
        overlay.present(over: view)
    }

    private func abbreviated(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        return "\(npub.prefix(10))…\(npub.suffix(5))"
    }
}

@MainActor
private final class TimelineNoteRowView: NSTableCellView {
    private enum ContentItem {
        case text(String)
        case link(String)
        case image(BlossomMediaReference)
        case embeddedNote(NostrEvent)
    }

    private let event: NostrEvent
    private let items: [ContentItem]
    private let profile: NostrProfile?
    private let profilesByPublicKey: [String: NostrProfile]
    private let avatarView = ProfileAvatarView(diameter: 34)
    private let nameLabel = NSTextField(labelWithString: "")
    private let usernameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    var onOpenMedia: ((BlossomMediaReference) -> Void)?

    init(event: NostrEvent, linkedNotesByID: [String: NostrEvent], profilesByPublicKey: [String: NostrProfile]) {
        self.event = event
        self.profilesByPublicKey = profilesByPublicKey
        profile = profilesByPublicKey[event.pubkey]
        items = Self.contentItems(for: event, linkedNotesByID: linkedNotesByID, profilesByPublicKey: profilesByPublicKey)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.opacity = 0.82

        avatarView.configure(with: profile?.pictureURL)
        nameLabel.stringValue = Self.displayName(for: event, profile: profile)
        usernameLabel.stringValue = Self.username(for: event, profile: profile)
        dateLabel.stringValue = Date(timeIntervalSince1970: TimeInterval(event.createdAt)).formatted(date: .abbreviated, time: .shortened)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        usernameLabel.font = .systemFont(ofSize: 13)
        usernameLabel.textColor = .secondaryLabelColor
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        [avatarView, nameLabel, usernameLabel, dateLabel].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        items.map(makeContentView).forEach { contentView in
            contentView.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(contentView)
            contentView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor)
            ])
        }
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            avatarView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 34),
            avatarView.heightAnchor.constraint(equalToConstant: 34),
            dateLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dateLabel.widthAnchor.constraint(equalToConstant: 116),
            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            usernameLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            usernameLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            usernameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        usernameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        animateOpacity()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        animateOpacity()
    }

    private func animateOpacity() {
        guard let layer else { return }
        let opacity: Float = isHovering ? 1 : 0.82
        let borderColor = NSColor.white.withAlphaComponent(isHovering ? 0.20 : 0.12).cgColor
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = opacity
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = opacity
        layer.add(animation, forKey: "timelineNoteHoverOpacity")

        let borderAnimation = CABasicAnimation(keyPath: "borderColor")
        borderAnimation.fromValue = layer.presentation()?.borderColor ?? layer.borderColor
        borderAnimation.toValue = borderColor
        borderAnimation.duration = 0.18
        borderAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.borderColor = borderColor
        layer.add(borderAnimation, forKey: "timelineNoteHoverBorder")
    }


    private func makeContentView(for item: ContentItem) -> NSView {
        switch item {
        case let .text(text):
            let label = WrappingTextField(text)
            label.font = .systemFont(ofSize: 15)
            label.alignment = .left
            return label
        case let .link(url):
            let button = PayloadButton(title: url, target: self, action: #selector(openLink(_:)))
            button.isBordered = false
            button.bezelStyle = .inline
            button.contentTintColor = .linkColor
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = url
            button.payload = url
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return button
        case let .image(reference):
            let button = ThumbnailButton(frame: .zero)
            button.target = self
            button.action = #selector(openMedia(_:))
            button.isBordered = false
            button.toolTip = "Open image"
            button.payload = reference
            button.heightAnchor.constraint(equalToConstant: 160).isActive = true
            ImageThumbnailCache.shared.thumbnail(for: reference) { [weak button] image in
                guard let button, let image else { return }
                button.thumbnail = image
            }
            return button
        case let .embeddedNote(note):
            return EmbeddedNoteCard(event: note, profile: profilesByPublicKey[note.pubkey])
        }
    }

    private static func contentItems(for event: NostrEvent, linkedNotesByID: [String: NostrEvent], profilesByPublicKey: [String: NostrProfile]) -> [ContentItem] {
        let references = Dictionary(uniqueKeysWithValues: BlossomMediaReference.find(in: [event]).map { ($0.sourceURL.absoluteString, $0) })
        let pattern = #"(?:https?://[^\s\"'<>]+|nostr:nevent1[023456789acdefghjklmnpqrstuvwxyz]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [.text(event.content)] }
        let range = NSRange(event.content.startIndex..., in: event.content)
        var items: [ContentItem] = []
        var cursor = event.content.startIndex

        for match in expression.matches(in: event.content, range: range) {
            guard let matchRange = Range(match.range, in: event.content) else { continue }
            if cursor < matchRange.lowerBound {
                items.append(.text(String(event.content[cursor..<matchRange.lowerBound])))
            }
            let referenceText = String(event.content[matchRange])
            let url = referenceText.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if referenceText.hasPrefix("nostr:nevent"),
               let eventID = NeventDecoder.eventID(from: referenceText),
               let linkedNote = linkedNotesByID[eventID] {
                items.append(.embeddedNote(linkedNote))
            } else if let reference = references[url],
               let localURL = try? BlossomMediaStore().localURL(for: reference.hash),
               !isVideo(localURL) {
                items.append(.image(reference))
            } else {
                items.append(.link(url))
            }
            cursor = matchRange.upperBound
        }
        if cursor < event.content.endIndex {
            items.append(.text(String(event.content[cursor...])))
        }
        return items.filter {
            if case let .text(text) = $0 { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }

    private static func isVideo(_ url: URL) -> Bool {
        ["m4v", "mov", "mp4", "mpeg", "mpg", "webm"].contains(url.pathExtension.lowercased())
    }

    private static func displayName(for event: NostrEvent, profile: NostrProfile?) -> String {
        profile?.displayName ?? abbreviated(event.pubkey)
    }

    private static func username(for event: NostrEvent, profile: NostrProfile?) -> String {
        let username = profile?.username ?? abbreviated(event.pubkey)
        return username.hasPrefix("@") ? username : "@\(username)"
    }

    private static func abbreviated(_ publicKey: String) -> String {
        guard publicKey.count > 16 else { return publicKey }
        return "\(publicKey.prefix(8))…\(publicKey.suffix(6))"
    }

    @objc private func openMedia(_ sender: NSButton) {
        guard let reference = (sender as? PayloadButton)?.payload as? BlossomMediaReference else { return }
        onOpenMedia?(reference)
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let string = (sender as? PayloadButton)?.payload as? String, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class EmbeddedNoteCard: NSView {
    private let event: NostrEvent
    private let avatarView = ProfileAvatarView(diameter: 26)
    private let nameLabel = NSTextField(labelWithString: "")
    private let usernameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let bodyLabel: WrappingTextField
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(event: NostrEvent, profile: NostrProfile?) {
        self.event = event
        bodyLabel = WrappingTextField(event.content)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.opacity = 0.82
        avatarView.configure(with: profile?.pictureURL)
        nameLabel.stringValue = profile?.displayName ?? Self.abbreviated(event.pubkey)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let username = profile?.username ?? Self.abbreviated(event.pubkey)
        usernameLabel.stringValue = username.hasPrefix("@") ? username : "@\(username)"
        usernameLabel.font = .systemFont(ofSize: 12)
        usernameLabel.textColor = .secondaryLabelColor
        dateLabel.stringValue = Date(timeIntervalSince1970: TimeInterval(event.createdAt)).formatted(date: .abbreviated, time: .omitted)
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        bodyLabel.font = .systemFont(ofSize: 14)
        [avatarView, nameLabel, usernameLabel, dateLabel, bodyLabel].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            avatarView.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            avatarView.widthAnchor.constraint(equalToConstant: 26),
            avatarView.heightAnchor.constraint(equalToConstant: 26),
            dateLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dateLabel.widthAnchor.constraint(equalToConstant: 78),
            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            usernameLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 5),
            usernameLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            usernameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -9),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bodyLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 10),
            bodyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        ])
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        usernameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        animateOpacity()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        animateOpacity()
    }

    private func animateOpacity() {
        guard let layer else { return }
        let opacity: Float = isHovering ? 1 : 0.82
        let borderColor = NSColor.white.withAlphaComponent(isHovering ? 0.20 : 0.12).cgColor
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = opacity
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = opacity
        layer.add(animation, forKey: "embeddedNoteHoverOpacity")

        let borderAnimation = CABasicAnimation(keyPath: "borderColor")
        borderAnimation.fromValue = layer.presentation()?.borderColor ?? layer.borderColor
        borderAnimation.toValue = borderColor
        borderAnimation.duration = 0.18
        borderAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.borderColor = borderColor
        layer.add(borderAnimation, forKey: "embeddedNoteHoverBorder")
    }

    private static func abbreviated(_ publicKey: String) -> String {
        guard publicKey.count > 16 else { return publicKey }
        return "\(publicKey.prefix(8))…\(publicKey.suffix(6))"
    }
}

/// Gives Auto Layout a current wrapping width whenever the table column changes.
@MainActor
private final class WrappingTextField: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
        cell?.truncatesLastVisibleLine = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePreferredWidth()
    }

    override func layout() {
        super.layout()
        updatePreferredWidth()
    }

    private func updatePreferredWidth() {
        let width = bounds.width
        guard width > 0, abs(preferredMaxLayoutWidth - width) > 0.5 else { return }
        preferredMaxLayoutWidth = width
        invalidateIntrinsicContentSize()
    }
}

@MainActor
private final class ProfileAvatarView: NSImageView {
    init(diameter: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "Profile picture")
        contentTintColor = .secondaryLabelColor
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

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
        image.draw(
            in: rect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: isFlipped,
            hints: nil
        )
    }

    func configure(with pictureURL: URL?) {
        guard let pictureURL else { return }
        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: pictureURL).0,
                  let image = NSImage(data: data) else { return }
            self?.image = image
            self?.contentTintColor = nil
        }
    }
}

private class PayloadButton: NSButton {
    var payload: Any?
}

private final class ThumbnailButton: PayloadButton {
    private let thumbnailView = NSImageView()

    var thumbnail: NSImage? {
        didSet {
            thumbnailView.image = thumbnail
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 7
        thumbnailView.layer?.masksToBounds = true
        addSubview(thumbnailView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        title = ""
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 7
        thumbnailView.layer?.masksToBounds = true
        addSubview(thumbnailView)
    }

    override func layout() {
        super.layout()
        guard let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else {
            thumbnailView.frame = .zero
            return
        }
        let scale = min(bounds.width / thumbnail.size.width, bounds.height / thumbnail.size.height, 1)
        let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
        thumbnailView.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard thumbnail != nil else {
            super.mouseDown(with: event)
            return
        }
        animateThumbnail(to: 0.94, duration: 0.1)
        super.mouseDown(with: event)
        animateThumbnail(to: 1, duration: 0.16)
    }

    private func animateThumbnail(to scale: CGFloat, duration: CFTimeInterval) {
        guard let layer = thumbnailView.layer else { return }
        centerAnimationAnchor(for: layer)
        let target = CATransform3DMakeScale(scale, scale, 1)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "thumbnailPressScale")
        layer.transform = target
    }

    private func centerAnimationAnchor(for layer: CALayer) {
        let center = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != center else { return }
        let oldAnchor = layer.anchorPoint
        let position = layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = center
        layer.position = CGPoint(
            x: position.x + (center.x - oldAnchor.x) * layer.bounds.width,
            y: position.y + (center.y - oldAnchor.y) * layer.bounds.height
        )
        CATransaction.commit()
    }
}

@MainActor
private final class ImageThumbnailCache {
    static let shared = ImageThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private var failedHashes = Set<String>()
    private var queued: [(hash: String, url: URL)] = []
    private var activeLoads = 0

    private init() {
        cache.countLimit = 200
    }

    func thumbnail(for reference: BlossomMediaReference, completion: @escaping (NSImage?) -> Void) {
        let key = reference.hash as NSString
        if let image = cache.object(forKey: key) {
            completion(image)
            return
        }
        if failedHashes.contains(reference.hash) {
            completion(nil)
            return
        }

        pending[reference.hash, default: []].append(completion)
        guard pending[reference.hash]?.count == 1 else { return }
        guard let url = try? BlossomMediaStore().localURL(for: reference.hash) else {
            finish(nil, for: reference.hash)
            return
        }
        queued.append((reference.hash, url))
        startNextLoad()
    }

    private func finish(_ image: NSImage?, for hash: String) {
        if let image {
            cache.setObject(image, forKey: hash as NSString)
        } else {
            failedHashes.insert(hash)
        }
        let completions = pending.removeValue(forKey: hash) ?? []
        completions.forEach { $0(image) }
    }

    private func startNextLoad() {
        guard activeLoads < 2, !queued.isEmpty else { return }
        let item = queued.removeFirst()
        activeLoads += 1
        Task.detached(priority: .utility) {
            let image = Self.makeThumbnail(from: item.url)
            await MainActor.run {
                ImageThumbnailCache.shared.activeLoads -= 1
                ImageThumbnailCache.shared.finish(image, for: item.hash)
                ImageThumbnailCache.shared.startNextLoad()
            }
        }
        startNextLoad()
    }

    nonisolated private static func makeThumbnail(from url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
