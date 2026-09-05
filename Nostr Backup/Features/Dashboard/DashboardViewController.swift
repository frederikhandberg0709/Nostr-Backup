import Cocoa
import ImageIO

@MainActor
final class DashboardViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let npub: String
    private let events: [NostrEvent]
    private let mediaStore = BlossomMediaStore()
    private let tableView = NSTableView()

    var onSaveMedia: ((BlossomMediaReference) async throws -> Bool)?

    init(npub: String, events: [NostrEvent]) {
        self.npub = npub
        self.events = events.filter { $0.kind == 1 }.sorted { $0.createdAt > $1.createdAt }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSVisualEffectView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        TimelineNoteRowView.height(for: events[row], width: max(tableView.bounds.width, 520))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let event = events[row]
        let rowView = TimelineNoteRowView(event: event)
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
private final class TimelineNoteRowView: NSView {
    private enum ContentItem {
        case text(String)
        case link(String)
        case image(BlossomMediaReference)
    }

    private let event: NostrEvent
    private let items: [ContentItem]
    private let dateLabel = NSTextField(labelWithString: "")
    private let savedLabel = NSTextField(labelWithString: "Saved locally")
    private var contentViews: [NSView] = []

    var onOpenMedia: ((BlossomMediaReference) -> Void)?

    init(event: NostrEvent) {
        self.event = event
        items = Self.contentItems(for: event)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor

        dateLabel.stringValue = Date(timeIntervalSince1970: TimeInterval(event.createdAt)).formatted(date: .abbreviated, time: .shortened)
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor
        savedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        savedLabel.textColor = .systemGreen
        [dateLabel, savedLabel].forEach(addSubview)
        contentViews = items.map(makeContentView)
        contentViews.forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let inset: CGFloat = 16
        let contentWidth = max(bounds.width - inset * 2, 1)
        dateLabel.frame = NSRect(x: inset, y: bounds.height - 31, width: 240, height: 16)
        savedLabel.sizeToFit()
        savedLabel.frame.origin = NSPoint(x: bounds.width - inset - savedLabel.frame.width, y: bounds.height - 31)

        var y: CGFloat = inset
        for (item, contentView) in zip(items, contentViews).reversed() {
            let size = Self.size(for: item, availableWidth: contentWidth)
            contentView.frame = NSRect(x: inset, y: y, width: size.width, height: size.height)
            y += size.height + 8
        }
    }

    static func height(for event: NostrEvent, width: CGFloat) -> CGFloat {
        let contentWidth = max(width - 32, 1)
        let items = contentItems(for: event)
        let contentHeight = items.reduce(CGFloat.zero) { $0 + size(for: $1, availableWidth: contentWidth).height } + CGFloat(max(items.count - 1, 0) * 8)
        return ceil(contentHeight) + 68
    }

    private static func textHeight(_ text: String, width: CGFloat, font: NSFont = .systemFont(ofSize: 15)) -> CGFloat {
        (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
    }

    private func makeContentView(for item: ContentItem) -> NSView {
        switch item {
        case let .text(text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 15)
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
            return button
        case let .image(reference):
            let button = ThumbnailButton(frame: .zero)
            button.target = self
            button.action = #selector(openMedia(_:))
            button.isBordered = false
            button.toolTip = "Open image"
            button.payload = reference
            ImageThumbnailCache.shared.thumbnail(for: reference) { [weak button] image in
                guard let button, let image else { return }
                button.thumbnail = image
            }
            return button
        }
    }

    private static func contentItems(for event: NostrEvent) -> [ContentItem] {
        let references = Dictionary(uniqueKeysWithValues: BlossomMediaReference.find(in: [event]).map { ($0.sourceURL.absoluteString, $0) })
        let pattern = #"https?://[^\s\"'<>]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [.text(event.content)] }
        let range = NSRange(event.content.startIndex..., in: event.content)
        var items: [ContentItem] = []
        var cursor = event.content.startIndex

        for match in expression.matches(in: event.content, range: range) {
            guard let matchRange = Range(match.range, in: event.content) else { continue }
            if cursor < matchRange.lowerBound {
                items.append(.text(String(event.content[cursor..<matchRange.lowerBound])))
            }
            let url = String(event.content[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if let reference = references[url],
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

    private static func size(for item: ContentItem, availableWidth: CGFloat) -> NSSize {
        switch item {
        case let .text(text):
            return NSSize(width: availableWidth, height: ceil(textHeight(text, width: availableWidth)))
        case .link:
            return NSSize(width: availableWidth, height: 22)
        case .image:
            return NSSize(width: min(240, availableWidth), height: 160)
        }
    }

    private static func isVideo(_ url: URL) -> Bool {
        ["m4v", "mov", "mp4", "mpeg", "mpg", "webm"].contains(url.pathExtension.lowercased())
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
