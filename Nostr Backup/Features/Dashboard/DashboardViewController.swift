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
        let rowView = TimelineNoteRowView(event: event, media: BlossomMediaReference.find(in: [event]).first)
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
    private let event: NostrEvent
    private let media: BlossomMediaReference?
    private let dateLabel = NSTextField(labelWithString: "")
    private let contentLabel = NSTextField(wrappingLabelWithString: "")
    private let savedLabel = NSTextField(labelWithString: "Saved locally")
    private let mediaButton = NSButton()

    var onOpenMedia: ((BlossomMediaReference) -> Void)?

    init(event: NostrEvent, media: BlossomMediaReference?) {
        self.event = event
        self.media = media
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor

        dateLabel.stringValue = Date(timeIntervalSince1970: TimeInterval(event.createdAt)).formatted(date: .abbreviated, time: .shortened)
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor
        contentLabel.stringValue = event.content
        contentLabel.font = .systemFont(ofSize: 15)
        savedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        savedLabel.textColor = .systemGreen
        [dateLabel, contentLabel, savedLabel].forEach(addSubview)

        if media != nil {
            mediaButton.title = "Open media"
            mediaButton.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            mediaButton.imagePosition = .imageLeading
            mediaButton.target = self
            mediaButton.action = #selector(openMedia(_:))
            mediaButton.bezelStyle = .rounded
            addSubview(mediaButton)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let inset: CGFloat = 16
        let contentWidth = max(bounds.width - inset * 2, 1)
        dateLabel.frame = NSRect(x: inset, y: bounds.height - 31, width: 240, height: 16)
        savedLabel.sizeToFit()
        savedLabel.frame.origin = NSPoint(x: bounds.width - inset - savedLabel.frame.width, y: bounds.height - 31)
        let contentHeight = Self.textHeight(event.content, width: contentWidth)
        let buttonHeight: CGFloat = media == nil ? 0 : 30
        contentLabel.frame = NSRect(x: inset, y: inset + buttonHeight, width: contentWidth, height: contentHeight)
        if media != nil {
            mediaButton.frame = NSRect(x: inset, y: inset, width: 112, height: 28)
        }
    }

    static func height(for event: NostrEvent, width: CGFloat) -> CGFloat {
        let contentWidth = max(width - 32, 1)
        return ceil(textHeight(event.content, width: contentWidth)) + (BlossomMediaReference.find(in: [event]).isEmpty ? 0 : 34) + 52
    }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        ).height
    }

    @objc private func openMedia(_ sender: NSButton) {
        guard let media else { return }
        onOpenMedia?(media)
    }
}
