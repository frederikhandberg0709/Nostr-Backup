import Cocoa

@MainActor
final class DashboardContainerViewController: NSSplitViewController {
    private let npub: String
    private let events: [NostrEvent]
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

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebar = DashboardSidebarViewController()
        sidebar.onSelection = { [weak self] selection in self?.show(selection) }
        addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebar))
        show(.general)
    }

    private func show(_ selection: DashboardSection) {
        if splitViewItems.count > 1 {
            removeSplitViewItem(splitViewItems[1])
        }

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
        addSplitViewItem(NSSplitViewItem(viewController: content))
    }
}

enum DashboardSection {
    case general, notes, media
}

@MainActor
private final class DashboardSidebarViewController: NSViewController {
    var onSelection: ((DashboardSection) -> Void)?

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = NSTextField(labelWithString: "Nostr Relay")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        [title, button("General", symbol: "person.crop.circle", tag: 0), button("Notes", symbol: "note.text", tag: 1), button("Media", symbol: "photo.on.rectangle", tag: 2)].forEach(stack.addArrangedSubview)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 178),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 32)
        ])
    }

    private func button(_ title: String, symbol: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(selectSection(_:)))
        button.tag = tag
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .texturedRounded
        button.alignment = .left
        return button
    }

    @objc private func selectSection(_ sender: NSButton) {
        onSelection?([.general, .notes, .media][sender.tag])
    }
}
