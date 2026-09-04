import Cocoa

@MainActor
final class ImportViewController: NSViewController {
    var onImportNotes: ((String) -> Void)?
    var onImportBlossom: ((String) -> Void)?

    private let npubField = NSTextField()
    private let notesButton = NSButton()
    private let blossomButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "Your data stays on this Mac.")
    private let profileView = ProfileHeaderView()

    override func loadView() {
        view = NSVisualEffectView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
    }

    func setImporting(_ isImporting: Bool) {
        notesButton.isEnabled = !isImporting
        blossomButton.isEnabled = !isImporting
        npubField.isEnabled = !isImporting

        if isImporting {
            statusLabel.stringValue = "Importing notes from Nostr relays…"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    func setBlossomImporting(_ isImporting: Bool) {
        notesButton.isEnabled = !isImporting
        blossomButton.isEnabled = !isImporting
        npubField.isEnabled = !isImporting

        if isImporting {
            statusLabel.stringValue = "Importing Blossom media…"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    func showImportSucceeded(_ summary: NotesImportSummary) {
        profileView.configure(with: summary.profile, fallbackNpub: summary.npub)
        profileView.isHidden = false
        statusLabel.stringValue = "Saved \(summary.eventCount) events to \(summary.archiveURL.lastPathComponent)."
        statusLabel.textColor = .secondaryLabelColor
    }

    func showImportFailed(_ error: Error) {
        statusLabel.stringValue = error.localizedDescription
        statusLabel.textColor = .systemRed
    }

    func showBlossomImportSucceeded(_ summary: BlossomImportSummary) {
        var message = "Media import complete: \(summary.downloadedCount) downloaded, \(summary.alreadyStoredCount) already stored."
        if summary.failedCount > 0 {
            message += " \(summary.failedCount) failed."
        }
        statusLabel.stringValue = message
        statusLabel.textColor = summary.failedCount == 0 ? .secondaryLabelColor : .systemOrange
    }

    private func configureInterface() {
        guard let background = view as? NSVisualEffectView else { return }
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)

        let title = NSTextField(labelWithString: "Your personal Nostr archive")
        title.font = .systemFont(ofSize: 30, weight: .bold)

        let subtitle = NSTextField(wrappingLabelWithString: "Import your notes and Blossom media into a private local backup, stored on this device.")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2

        let npubLabel = NSTextField(labelWithString: "NOSTR PUBLIC KEY")
        npubLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        npubLabel.textColor = .secondaryLabelColor

        npubField.placeholderString = "npub1…"
        npubField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        npubField.setAccessibilityLabel("Nostr public key")

        let keySection = NSStackView(views: [npubLabel, npubField])
        keySection.orientation = .vertical
        keySection.alignment = .leading
        keySection.spacing = 8

        let divider = NSBox()
        divider.boxType = .separator

        configure(button: notesButton, title: "Import Notes", imageName: "note.text", action: #selector(importNotes(_:)))
        configure(button: blossomButton, title: "Import Blossom", imageName: "photo.on.rectangle", action: #selector(importBlossom(_:)))

        let notesRow = importRow(button: notesButton, description: "Download and archive all events authored by this account")
        let blossomRow = importRow(button: blossomButton, description: "Archive media from supported Blossom hosts")

        profileView.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .tertiaryLabelColor

        [title, subtitle, keySection, divider, notesRow, blossomRow, profileView, statusLabel].forEach(content.addArrangedSubview)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 44),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -44),
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 52),
            content.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -36),
            npubField.widthAnchor.constraint(equalTo: content.widthAnchor),
            npubField.heightAnchor.constraint(equalToConstant: 32),
            divider.widthAnchor.constraint(equalTo: content.widthAnchor),
            notesRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            blossomRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            profileView.widthAnchor.constraint(equalTo: content.widthAnchor)
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

    private func importRow(button: NSButton, description: String) -> NSStackView {
        let descriptionLabel = NSTextField(labelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [button, descriptionLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    @objc private func importNotes(_ sender: NSButton) {
        let npub = npubField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !npub.isEmpty else {
            statusLabel.stringValue = "Enter an npub before importing."
            statusLabel.textColor = .systemRed
            view.window?.makeFirstResponder(npubField)
            return
        }
        onImportNotes?(npub)
    }

    @objc private func importBlossom(_ sender: NSButton) {
        let npub = npubField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !npub.isEmpty else {
            statusLabel.stringValue = "Enter the npub whose media you want to import."
            statusLabel.textColor = .systemRed
            view.window?.makeFirstResponder(npubField)
            return
        }
        onImportBlossom?(npub)
    }
}
