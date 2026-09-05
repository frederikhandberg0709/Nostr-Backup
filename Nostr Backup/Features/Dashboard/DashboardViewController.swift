import Cocoa

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
        case image(NSImage, BlossomMediaReference)
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
        case let .image(image, reference):
            let button = PayloadButton(image: image, target: self, action: #selector(openMedia(_:)))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = "Open image"
            button.payload = reference
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.layer?.masksToBounds = true
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
               let image = NSImage(contentsOf: localURL) {
                items.append(.image(image, reference))
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
        case let .image(image, _):
            let maximum = NSSize(width: min(240, availableWidth), height: 160)
            let source = image.size.width > 0 && image.size.height > 0 ? image.size : NSSize(width: 4, height: 3)
            let scale = min(maximum.width / source.width, maximum.height / source.height, 1)
            return NSSize(width: max(1, floor(source.width * scale)), height: max(1, floor(source.height * scale)))
        }
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

private final class PayloadButton: NSButton {
    var payload: Any?
}
