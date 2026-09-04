import Cocoa

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet private var window: NSWindow!

    private let importCoordinator = NotesImportCoordinator()
    private let blossomImportCoordinator = BlossomImportCoordinator()
    private var importViewController: ImportViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindow()

        importViewController = ImportViewController()
        importViewController.onImportNotes = { [weak self] npub in
            self?.importNotes(for: npub)
        }
        importViewController.onImportBlossom = { [weak self] npub in
            self?.importBlossom(for: npub)
        }
        if let npub = UserDefaults.standard.string(forKey: "lastImportedNpub"),
           let events = try? NotesArchiveStore().allEvents(for: npub),
           !events.isEmpty {
            showDashboard(for: npub)
        } else {
            window.contentViewController = importViewController
        }
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
                _ = try await importCoordinator.importNotes(for: npub)
                UserDefaults.standard.set(npub, forKey: "lastImportedNpub")
                showDashboard(for: npub)
            } catch {
                importViewController.showImportFailed(error)
            }

            importViewController.setImporting(false)
        }
    }

    private func importBlossom(for npub: String) {
        importViewController.setBlossomImporting(true)

        Task { [weak self] in
            guard let self else { return }

            do {
                let summary = try await blossomImportCoordinator.importMedia(for: npub)
                importViewController.showBlossomImportSucceeded(summary)
            } catch {
                importViewController.showImportFailed(error)
            }

            importViewController.setBlossomImporting(false)
        }
    }

    private func showDashboard(for npub: String) {
        let archiveStore = NotesArchiveStore()
        guard let events = try? archiveStore.allEvents(for: npub) else { return }

        let dashboard = DashboardContainerViewController(npub: npub, events: events)
        dashboard.onSaveMedia = { [blossomImportCoordinator] reference in
            try await blossomImportCoordinator.saveMedia(reference)
        }
        window.contentViewController = dashboard
    }
}
