import Cocoa

@MainActor
final class DashboardContainerViewController: NSViewController {
    private let npub: String
    private let events: [NostrEvent]
    private let contentContainer = NSView()
    private var currentContent: NSViewController?
    private var notesViewController: DashboardViewController?

    var onSaveMedia: ((BlossomMediaReference) async throws -> Bool)? {
        didSet { notesViewController?.onSaveMedia = onSaveMedia }
    }

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
        show(.general)
    }

    private func buildInterface() {
        guard let background = view as? NSVisualEffectView else { return }
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active

        let sidebar = DashboardSidebarViewController()
        sidebar.onSelection = { [weak self] selection in self?.show(selection) }
        addChild(sidebar)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sidebar.view)
        background.addSubview(divider)
        background.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: background.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sidebar.view.widthAnchor.constraint(equalToConstant: 210),
            divider.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: background.topAnchor),
            divider.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: background.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
    }

    private func show(_ selection: DashboardSection) {
        currentContent?.view.removeFromSuperview()
        currentContent?.removeFromParent()

        let content: NSViewController
        switch selection {
        case .general:
            content = GeneralDashboardViewController(npub: npub, events: events)
        case .notes:
            let notes = DashboardViewController(npub: npub, events: events)
            notes.onSaveMedia = onSaveMedia
            notesViewController = notes
            content = notes
        case .media:
            content = MediaLibraryViewController()
        }

        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        currentContent = content
    }
}

enum DashboardSection { case general, notes, media }

@MainActor
private final class DashboardSidebarViewController: NSViewController {
    var onSelection: ((DashboardSection) -> Void)?
    private var buttons: [SidebarButton] = []

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = NSTextField(labelWithString: "Nostr Backup")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        let navigationButtons = [
            button("General", symbol: "person.crop.circle", tag: 0),
            button("Notes", symbol: "note.text", tag: 1),
            button("Media", symbol: "photo.on.rectangle", tag: 2)
        ]
        buttons = navigationButtons
        ([title] + navigationButtons).forEach(stack.addArrangedSubview)
        navigationButtons.forEach {
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 32)
        ])
        select(buttons[0])
    }

    private func button(_ title: String, symbol: String, tag: Int) -> SidebarButton {
        let button = SidebarButton(title: title, symbol: symbol, target: self, action: #selector(selectSection(_:)))
        button.tag = tag
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }

    @objc private func selectSection(_ sender: NSButton) {
        guard let button = sender as? SidebarButton else { return }
        select(button)
        onSelection?([.general, .notes, .media][sender.tag])
    }

    private func select(_ selectedButton: SidebarButton) {
        buttons.forEach { $0.isCurrentSection = $0 === selectedButton }
    }
}

@MainActor
private final class SidebarButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    var isCurrentSection = false { didSet { updateAppearance() } }

    convenience init(title: String, symbol: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        titleLabel.stringValue = title
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }

    private func configure() {
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        image = nil
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    private func updateAppearance() {
        let background: NSColor = isCurrentSection ? .selectedContentBackgroundColor : (isHovering ? .controlBackgroundColor.withAlphaComponent(0.7) : .clear)
        layer?.backgroundColor = background.cgColor
        let foreground = isCurrentSection ? NSColor.selectedMenuItemTextColor : .secondaryLabelColor
        iconView.contentTintColor = foreground
        titleLabel.textColor = foreground
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { isHovering = false; updateAppearance() }
}
