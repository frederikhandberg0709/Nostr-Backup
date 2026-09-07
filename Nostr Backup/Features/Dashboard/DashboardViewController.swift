import Cocoa
import AVFoundation
import ImageIO

@MainActor
final class DashboardViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let npub: String
    private let events: [NostrEvent]
    private let linkedNotesByID: [String: NostrEvent]
    private var profilesByPublicKey: [String: NostrProfile]
    private var repliesByPostID: [String: [NostrEvent]] = [:]
    private var expandedPostIDs = Set<String>()
    private let mediaStore = BlossomMediaStore()
    private let tableView = NSTableView()
    private var rowHeightReloadWorkItem: DispatchWorkItem?
    private var rowHeightCache: [Int: CGFloat] = [:]

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
        loadReplies()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableViewColumnDidResize(_ notification: Notification) {
        rowHeightReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                self.rowHeightCache.removeAll()
                self.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.events.count))
            }
        }
        rowHeightReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let event = events[row]
        let replies = repliesByPostID[event.id] ?? []
        let rowView = TimelineNoteRowView(
            event: event,
            linkedNotesByID: linkedNotesByID,
            profilesByPublicKey: profilesByPublicKey,
            replies: replies,
            showsReplies: expandedPostIDs.contains(event.id)
        )
        let columnWidth = tableColumn?.width ?? tableView.bounds.width
        rowView.prepareForMeasurement(contentWidth: max(1, columnWidth - 32))
        rowView.onOpenMedia = { [weak self] reference in self?.openMedia(reference) }
        rowView.onToggleReplies = { [weak self] in self?.toggleReplies(for: event.id) }
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if let height = rowHeightCache[row] { return height }

        let columnWidth = max(1, tableView.tableColumns.first?.width ?? tableView.bounds.width)
        let height = TimelineNoteRowView.measuredHeight(
            event: events[row],
            linkedNotesByID: linkedNotesByID,
            profilesByPublicKey: profilesByPublicKey,
            replies: repliesByPostID[events[row].id] ?? [],
            showsReplies: expandedPostIDs.contains(events[row].id),
            contentWidth: max(1, columnWidth - 32)
        )
        rowHeightCache[row] = height
        return height
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
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 120
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

    private func loadReplies() {
        let postIDs = events.map(\.id)
        guard !postIDs.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let replies = await NostrRelayClient().fetchReplies(to: postIDs)
            let postIDSet = Set(postIDs)
            let grouped = Dictionary(grouping: replies.filter { reply in
                reply.tags.contains { tag in tag.first == "e" && tag.count > 1 && postIDSet.contains(tag[1]) }
            }) { reply in
                // NIP-10 replies retain the root event in their e-tags. This
                // also handles older clients that only supply one e-tag.
                reply.tags.first { tag in tag.first == "e" && tag.count > 1 && postIDSet.contains(tag[1]) }![1]
            }
            let profileEvents = await NostrRelayClient().fetchProfiles(
                publicKeys: Array(Set(replies.map(\.pubkey)))
            )
            profileEvents.forEach {
                if let profile = NostrProfile(event: $0) { self.profilesByPublicKey[$0.pubkey] = profile }
            }
            self.repliesByPostID = grouped
            self.refreshTimelineLayout()
        }
    }

    private func toggleReplies(for postID: String) {
        if expandedPostIDs.contains(postID) {
            expandedPostIDs.remove(postID)
        } else {
            expandedPostIDs.insert(postID)
        }
        refreshTimelineLayout()
    }

    private func refreshTimelineLayout() {
        rowHeightCache.removeAll()
        tableView.reloadData()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<events.count))
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
        case video(BlossomMediaReference)
        case embeddedNote(NostrEvent)
    }

    private let event: NostrEvent
    private let items: [ContentItem]
    private let profile: NostrProfile?
    private let profilesByPublicKey: [String: NostrProfile]
    private let replies: [NostrEvent]
    private let showsReplies: Bool
    private let avatarView = ProfileAvatarView(diameter: 34)
    private let nameLabel = NSTextField(labelWithString: "")
    private let usernameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    var onOpenMedia: ((BlossomMediaReference) -> Void)?
    var onToggleReplies: (() -> Void)?

    init(
        event: NostrEvent,
        linkedNotesByID: [String: NostrEvent],
        profilesByPublicKey: [String: NostrProfile],
        replies: [NostrEvent],
        showsReplies: Bool
    ) {
        self.event = event
        self.profilesByPublicKey = profilesByPublicKey
        self.replies = replies
        self.showsReplies = showsReplies
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
        let commentsButton = NSButton(title: "\(replies.count) \(replies.count == 1 ? "Comment" : "Comments")", target: self, action: #selector(toggleReplies(_:)))
        commentsButton.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "Comments")
        commentsButton.bezelStyle = .inline
        commentsButton.isBordered = false
        commentsButton.contentTintColor = .secondaryLabelColor
        commentsButton.imagePosition = .imageLeading
        commentsButton.toolTip = showsReplies ? "Hide comments" : "Show comments"
        commentsButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        contentStack.addArrangedSubview(commentsButton)
        if showsReplies, !replies.isEmpty {
            let thread = ReplyThreadView(rootEventID: event.id, replies: replies, profilesByPublicKey: profilesByPublicKey)
            thread.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(thread)
            thread.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
            thread.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive = true
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

    /// Sets wrapping widths before NSTableView calculates this cell's automatic
    /// height. Waiting for subview layout is too late when a row is shrinking.
    func prepareForMeasurement(contentWidth: CGFloat) {
        for view in contentStack.arrangedSubviews {
            if let label = view as? WrappingTextField {
                label.setPreferredWrappingWidth(contentWidth)
            } else if let embeddedNote = view as? EmbeddedNoteCard {
                embeddedNote.prepareForMeasurement(contentWidth: contentWidth)
            } else if let thread = view as? ReplyThreadView {
                thread.prepareForMeasurement(contentWidth: contentWidth)
            }
        }
    }

    static func measuredHeight(
        event: NostrEvent,
        linkedNotesByID: [String: NostrEvent],
        profilesByPublicKey: [String: NostrProfile],
        replies: [NostrEvent],
        showsReplies: Bool,
        contentWidth: CGFloat
    ) -> CGFloat {
        let items = contentItems(for: event, linkedNotesByID: linkedNotesByID, profilesByPublicKey: profilesByPublicKey)
        let itemHeights = items.map { item -> CGFloat in
            switch item {
            case let .text(text):
                return wrappedTextHeight(text, font: .systemFont(ofSize: 15), width: contentWidth)
            case .link:
                return 22
            case .image, .video:
                return 160
            case let .embeddedNote(note):
                // Embedded cards have 49 points from their top to the body and
                // 11 points from the body to their bottom.
                return 60 + wrappedTextHeight(note.content, font: .systemFont(ofSize: 14), width: max(1, contentWidth - 24))
            }
        }

        var heights = itemHeights
        heights.append(26) // Comment affordance.
        if showsReplies, !replies.isEmpty {
            heights.append(ReplyThreadView.measuredHeight(rootEventID: event.id, replies: replies, contentWidth: contentWidth))
        }
        // The content stack begins 64 points below the outer card's top and
        // ends 16 points above its bottom. Arranged items are separated by 8.
        return ceil(80 + heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 8)
    }

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
        case let .video(reference):
            let button = ThumbnailButton(frame: .zero)
            button.target = self
            button.action = #selector(openMedia(_:))
            button.isBordered = false
            button.toolTip = "Play video"
            button.payload = reference
            button.showsPlayButton = true
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
                      let localURL = try? BlossomMediaStore().localURL(for: reference.hash) {
                items.append(isVideo(localURL) ? .video(reference) : .image(reference))
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

    fileprivate static func wrappedTextHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(max(font.boundingRectForFont.height, bounds.height))
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

    @objc private func toggleReplies(_ sender: NSButton) {
        onToggleReplies?()
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

    func prepareForMeasurement(contentWidth: CGFloat) {
        // The embedded card has 12-point inset on either side of its body.
        bodyLabel.setPreferredWrappingWidth(max(1, contentWidth - 24))
    }

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

/// A compact, indented presentation of a NIP-10 reply tree. The fetched events
/// live only in this view controller; this view has no archive or disk access.
@MainActor
private final class ReplyThreadView: NSView {
    private let stack = NSStackView()
    private let comments: [(event: NostrEvent, depth: Int)]

    init(rootEventID: String, replies: [NostrEvent], profilesByPublicKey: [String: NostrProfile]) {
        comments = Self.flattenedComments(rootEventID: rootEventID, replies: replies)
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        comments.forEach { comment in
            let view = ReplyCommentView(event: comment.event, depth: comment.depth, profile: profilesByPublicKey[comment.event.pubkey])
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func prepareForMeasurement(contentWidth: CGFloat) {
        for view in stack.arrangedSubviews {
            (view as? ReplyCommentView)?.prepareForMeasurement(contentWidth: contentWidth)
        }
    }

    static func measuredHeight(rootEventID: String, replies: [NostrEvent], contentWidth: CGFloat) -> CGFloat {
        let comments = flattenedComments(rootEventID: rootEventID, replies: replies)
        let heights = comments.map { comment in
            ReplyCommentView.measuredHeight(event: comment.event, depth: comment.depth, contentWidth: contentWidth)
        }
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 8
    }

    private static func flattenedComments(rootEventID: String, replies: [NostrEvent]) -> [(event: NostrEvent, depth: Int)] {
        let byID = Dictionary(uniqueKeysWithValues: replies.map { ($0.id, $0) })
        let children = Dictionary(grouping: replies) { reply -> String in
            // The last e-tag is the immediate parent under NIP-10. Older
            // clients with a single e-tag naturally resolve to the root.
            reply.tags.last(where: { $0.first == "e" && $0.count > 1 })?[1] ?? rootEventID
        }
        func visit(parentID: String, depth: Int, ancestors: Set<String>) -> [(event: NostrEvent, depth: Int)] {
            (children[parentID] ?? []).sorted { $0.createdAt < $1.createdAt }.flatMap { reply in
                guard !ancestors.contains(reply.id) else { return [(event: NostrEvent, depth: Int)]() }
                let childDepth = min(depth, 5)
                return [(reply, childDepth)] + visit(parentID: reply.id, depth: childDepth + 1, ancestors: ancestors.union([reply.id]))
            }
        }
        // A malformed/missing parent remains visible at the root level.
        let roots = replies.filter {
            let parent = $0.tags.last(where: { $0.first == "e" && $0.count > 1 })?[1]
            return parent == nil || parent == rootEventID || byID[parent!] == nil
        }.sorted { $0.createdAt < $1.createdAt }
        return roots.flatMap { reply in [(reply, 0)] + visit(parentID: reply.id, depth: 1, ancestors: [reply.id]) }
    }
}

@MainActor
private final class ReplyCommentView: NSView {
    private let depth: Int
    private let bodyLabel: WrappingTextField

    init(event: NostrEvent, depth: Int, profile: NostrProfile?) {
        self.depth = depth
        bodyLabel = WrappingTextField(event.content)
        super.init(frame: .zero)
        let indent = CGFloat(depth) * 18
        let threadLine = NSView()
        threadLine.wantsLayer = true
        threadLine.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        let avatar = ProfileAvatarView(diameter: 24)
        avatar.configure(with: profile?.pictureURL)
        let name = NSTextField(labelWithString: profile?.displayName ?? Self.abbreviated(event.pubkey))
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let date = NSTextField(labelWithString: Date(timeIntervalSince1970: TimeInterval(event.createdAt)).formatted(date: .abbreviated, time: .omitted))
        date.font = .systemFont(ofSize: 11)
        date.textColor = .tertiaryLabelColor
        bodyLabel.font = .systemFont(ofSize: 14)
        [threadLine, avatar, name, date, bodyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            threadLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent + 7),
            threadLine.topAnchor.constraint(equalTo: topAnchor),
            threadLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            threadLine.widthAnchor.constraint(equalToConstant: 2),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent + 18),
            avatar.topAnchor.constraint(equalTo: topAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 24),
            avatar.heightAnchor.constraint(equalToConstant: 24),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 7),
            name.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            date.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            date.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            date.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 4),
            bodyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        name.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func prepareForMeasurement(contentWidth: CGFloat) {
        bodyLabel.setPreferredWrappingWidth(max(1, contentWidth - CGFloat(depth) * 18 - 49))
    }

    static func measuredHeight(event: NostrEvent, depth: Int, contentWidth: CGFloat) -> CGFloat {
        36 + TimelineNoteRowView.wrappedTextHeight(event.content, font: .systemFont(ofSize: 14), width: max(1, contentWidth - CGFloat(depth) * 18 - 49))
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

    func setPreferredWrappingWidth(_ width: CGFloat) {
        let width = max(1, width)
        guard abs(preferredMaxLayoutWidth - width) > 0.5 else { return }
        preferredMaxLayoutWidth = width
        invalidateIntrinsicContentSize()
    }

    private func updatePreferredWidth() {
        guard bounds.width > 0 else { return }
        setPreferredWrappingWidth(bounds.width)
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
    private let playButtonView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    var showsPlayButton = false {
        didSet {
            playButtonView.isHidden = !showsPlayButton
            needsLayout = true
        }
    }

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
        playButtonView.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play video")
        playButtonView.symbolConfiguration = .init(pointSize: 42, weight: .medium)
        playButtonView.contentTintColor = .white.withAlphaComponent(0.92)
        playButtonView.isHidden = true
        addSubview(thumbnailView)
        addSubview(playButtonView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        title = ""
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 7
        thumbnailView.layer?.masksToBounds = true
        playButtonView.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play video")
        playButtonView.symbolConfiguration = .init(pointSize: 42, weight: .medium)
        playButtonView.contentTintColor = .white.withAlphaComponent(0.92)
        playButtonView.isHidden = true
        addSubview(thumbnailView)
        addSubview(playButtonView)
    }

    override func layout() {
        super.layout()
        guard let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else {
            thumbnailView.frame = .zero
            playButtonView.frame = .zero
            return
        }
        let scale = min(bounds.width / thumbnail.size.width, bounds.height / thumbnail.size.height, 1)
        let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
        thumbnailView.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let playSize: CGFloat = 46
        playButtonView.frame = NSRect(
            x: thumbnailView.frame.midX - playSize / 2,
            y: thumbnailView.frame.midY - playSize / 2,
            width: playSize,
            height: playSize
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

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
        super.mouseEntered(with: event)
        isHovering = true
        animateThumbnailOpacity()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        animateThumbnailOpacity()
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

    private func animateThumbnailOpacity() {
        guard let layer = thumbnailView.layer else { return }
        let targetOpacity: Float = isHovering ? 0.94 : 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = targetOpacity
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = targetOpacity
        layer.add(animation, forKey: "thumbnailHoverOpacity")
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
            let image = await Self.makeThumbnail(from: item.url)
            await MainActor.run {
                ImageThumbnailCache.shared.activeLoads -= 1
                ImageThumbnailCache.shared.finish(image, for: item.hash)
                ImageThumbnailCache.shared.startNextLoad()
            }
        }
        startNextLoad()
    }

    nonisolated private static func makeThumbnail(from url: URL) async -> NSImage? {
        if isVideo(url) {
            return await makeVideoThumbnail(from: url)
        }
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

    nonisolated private static func makeVideoThumbnail(from url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    nonisolated private static func isVideo(_ url: URL) -> Bool {
        ["m4v", "mov", "mp4", "mpeg", "mpg", "webm"].contains(url.pathExtension.lowercased())
    }
}
