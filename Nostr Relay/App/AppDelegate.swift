import Cocoa

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet private var window: NSWindow!

    private let importCoordinator = NotesImportCoordinator()
    private var importViewController: ImportViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindow()

        importViewController = ImportViewController()
        importViewController.onImportNotes = { [weak self] npub in
            self?.importNotes(for: npub)
        }
        window.contentViewController = importViewController
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func configureWindow() {
        window.title = "Nostr Relay"
        window.minSize = NSSize(width: 560, height: 500)
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
    }

    private func importNotes(for npub: String) {
        importViewController.setImporting(true)

        Task { [weak self] in
            guard let self else { return }

            do {
                let summary = try await importCoordinator.importNotes(for: npub)
                importViewController.showImportSucceeded(summary)
            } catch {
                importViewController.showImportFailed(error)
            }

            importViewController.setImporting(false)
        }
    }
}
