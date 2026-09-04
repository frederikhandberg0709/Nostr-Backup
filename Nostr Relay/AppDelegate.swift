//
//  AppDelegate.swift
//  Nostr Relay
//
//  Created by Frederik Handberg on 04/09/2026.
//

import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet private var window: NSWindow!

    private let npubField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "Your data stays on this Mac.")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindow()
        buildInterface()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func configureWindow() {
        window.title = "Nostr Relay"
        window.minSize = NSSize(width: 560, height: 460)
        window.setContentSize(NSSize(width: 620, height: 500))
        window.center()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
    }

    private func buildInterface() {
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = background

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)

        let title = NSTextField(labelWithString: "Your personal Nostr archive")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textColor = .labelColor

        let subtitle = NSTextField(wrappingLabelWithString: "Import your notes and Blossom media into a private local backup, stored on this device.")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2

        let npubLabel = NSTextField(labelWithString: "NOSTR PUBLIC KEY")
        npubLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        npubLabel.textColor = .secondaryLabelColor

        npubField.placeholderString = "npub1…"
        npubField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        npubField.focusRingType = .default
        npubField.translatesAutoresizingMaskIntoConstraints = false
        npubField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        npubField.setAccessibilityLabel("Nostr public key")

        let keySection = NSStackView(views: [npubLabel, npubField])
        keySection.orientation = .vertical
        keySection.alignment = .leading
        keySection.spacing = 8
        keySection.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator

        let notesButton = importButton(title: "Import Notes", imageName: "note.text", action: #selector(importNotes(_:)))
        let blossomButton = importButton(title: "Import Blossom", imageName: "photo.on.rectangle", action: #selector(importBlossom(_:)))

        let notesDescription = NSTextField(labelWithString: "Download and save your Nostr notes")
        let blossomDescription = NSTextField(labelWithString: "Download and save media referenced by your notes")
        [notesDescription, blossomDescription].forEach {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
        }

        let notesRow = importRow(button: notesButton, description: notesDescription)
        let blossomRow = importRow(button: blossomButton, description: blossomDescription)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .tertiaryLabelColor

        [title, subtitle, keySection, divider, notesRow, blossomRow, statusLabel].forEach(content.addArrangedSubview)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 44),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -44),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            npubField.widthAnchor.constraint(equalTo: keySection.widthAnchor),
            npubField.heightAnchor.constraint(equalToConstant: 32),
            divider.widthAnchor.constraint(equalTo: content.widthAnchor),
            notesRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            blossomRow.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func importButton(title: String, imageName: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.controlSize = .large
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        return button
    }

    private func importRow(button: NSButton, description: NSTextField) -> NSStackView {
        let row = NSStackView(views: [button, description])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        description.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func importNotes(_ sender: NSButton) {
        beginImport(named: "notes")
    }

    @objc private func importBlossom(_ sender: NSButton) {
        beginImport(named: "Blossom media")
    }

    private func beginImport(named content: String) {
        let npub = npubField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard npub.hasPrefix("npub1") else {
            statusLabel.stringValue = "Enter a valid npub before importing."
            statusLabel.textColor = .systemRed
            window.makeFirstResponder(npubField)
            return
        }

        statusLabel.stringValue = "(content.capitalized) import will be available next."
        statusLabel.textColor = .secondaryLabelColor
    }
}
