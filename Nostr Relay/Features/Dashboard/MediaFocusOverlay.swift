import Cocoa

@MainActor
final class MediaFocusOverlay: NSVisualEffectView {
    let reference: BlossomMediaReference
    private let mediaStore: BlossomMediaStore
    private let imageView = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton()
    private let messageLabel = NSTextField(labelWithString: "")

    var onSave: ((BlossomMediaReference) async -> Void)?

    init(reference: BlossomMediaReference, mediaStore: BlossomMediaStore) {
        self.reference = reference
        self.mediaStore = mediaStore
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        configureInterface()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func present(over parent: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            removeFromSuperview()
        } else {
            super.keyDown(with: event)
        }
    }

    func refresh() {
        guard let url = try? mediaStore.localURL(for: reference.hash) else {
            imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            imageView.contentTintColor = .secondaryLabelColor
            stateLabel.stringValue = "Not saved locally"
            stateLabel.textColor = .systemYellow
            saveButton.isHidden = false
            return
        }
        let image = NSImage(contentsOf: url)
        imageView.image = image ?? NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        imageView.contentTintColor = image == nil ? .secondaryLabelColor : nil
        stateLabel.stringValue = "Saved locally"
        stateLabel.textColor = .systemGreen
        saveButton.isHidden = true
    }

    func setSaving(_ isSaving: Bool) {
        saveButton.isEnabled = !isSaving
        saveButton.title = isSaving ? "Saving…" : "Save locally"
    }

    func showError(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.textColor = .systemRed
    }

    private func configureInterface() {
        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: self, action: #selector(close(_:)))
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = .secondaryLabelColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.symbolConfiguration = .init(pointSize: 96, weight: .light)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        stateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        saveButton.title = "Save locally"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        messageLabel.font = .systemFont(ofSize: 12)

        let controls = NSStackView(views: [stateLabel, saveButton, messageLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12

        let stack = NSStackView(views: [closeButton, imageView, controls])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -34),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -100),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -180),
            imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 1_200),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 800)
        ])
    }

    @objc private func close(_ sender: NSButton) { removeFromSuperview() }
    @objc private func save(_ sender: NSButton) { Task { await onSave?(reference) } }
}
