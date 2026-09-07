import AVFoundation
import Cocoa
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class GeneralDashboardViewController: NSViewController {
    private let npub: String
    private let events: [NostrEvent]

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
    }

    private func buildInterface() {
        let profile = events.filter { $0.kind == 0 }.max { $0.createdAt < $1.createdAt }.flatMap(NostrProfile.init(event:))
        let mediaStats = BlossomMediaStore().storageStatistics()
        let imageView = AspectFillImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "Profile picture")
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.symbolConfiguration = .init(pointSize: 68, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 36
        imageView.layer?.masksToBounds = true
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: profile?.displayName ?? "Nostr account")
        name.font = .systemFont(ofSize: 19, weight: .semibold)
        let username = NSTextField(labelWithString: profile?.username ?? abbreviated(npub))
        username.textColor = .secondaryLabelColor
        let biography = NSTextField(wrappingLabelWithString: profile?.biography ?? "No biography published.")
        biography.textColor = .secondaryLabelColor
        let profileStack = NSStackView(views: [name, username, biography])
        profileStack.orientation = .vertical
        profileStack.alignment = .leading
        profileStack.spacing = 5
        profileStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        biography.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let identity = NSStackView(views: [imageView, profileStack])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 14

        let eventsStat = stat(title: "Events", value: "\(events.count) saved")
        let mediaStat = stat(title: "Media storage", value: "\(mediaStats.fileCount) files · \(ByteCountFormatter.string(fromByteCount: Int64(mediaStats.byteCount), countStyle: .file))")
        let stats = NSStackView(views: [eventsStat, mediaStat])
        stats.orientation = .vertical
        stats.alignment = .leading
        stats.spacing = 12

        let content = NSStackView(views: [identity, NSBox(), stats])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        content.edgeInsets = NSEdgeInsets(top: 44, left: 42, bottom: 28, right: 42)
        content.translatesAutoresizingMaskIntoConstraints = false

        // The scroll view aligns a document view that is shorter than its clip view
        // to the bottom. Keep a document container at least viewport-height and pin
        // the actual dashboard content to its top instead.
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 72),
            imageView.heightAnchor.constraint(equalToConstant: 72),
            profileStack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -84)
        ])

        if let pictureURL = profile?.pictureURL {
            Task { [weak imageView] in
                guard let data = try? await URLSession.shared.data(from: pictureURL).0,
                      let image = NSImage(data: data) else { return }
                imageView?.image = image
                imageView?.contentTintColor = nil
            }
        }
    }

    private func stat(title: String, value: String) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 16, weight: .medium)
        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func abbreviated(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        return "\(npub.prefix(10))…\(npub.suffix(5))"
    }
}

@MainActor
private final class AspectFillImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            super.draw(dirtyRect)
            return
        }

        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1, respectFlipped: isFlipped, hints: nil)
    }
}

@MainActor
final class MediaLibraryViewController: NSViewController {
    var onImportBlossom: (() async throws -> BlossomImportSummary)?

    fileprivate struct MediaItem {
        let reference: BlossomMediaReference
        let localURL: URL
        let createdAt: Int?
        let isVideo: Bool
    }

    private let events: [NostrEvent]
    private let mediaStore = BlossomMediaStore()
    private let blossomButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No saved images or videos yet. Import Blossom media to add the media referenced by your notes.")
    private let collectionView = NSCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private var items: [MediaItem] = []
    private var thumbnailCache: [String: NSImage] = [:]

    init(events: [NostrEvent]) {
        self.events = events
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSVisualEffectView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configure(button: blossomButton, title: "Import Blossom", imageName: "photo.on.rectangle", action: #selector(importBlossom(_:)))
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        flowLayout.minimumInteritemSpacing = 8
        flowLayout.minimumLineSpacing = 8
        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(MediaGridItem.self, forItemWithIdentifier: MediaGridItem.identifier)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = collectionView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [countLabel, blossomButton, statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),
            emptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 10),
            emptyLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -10),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 22)
        ])
        reloadMedia()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let availableWidth = max(1, view.bounds.width - 64)
        let columnCount = max(2, Int(availableWidth / 180))
        let side = floor((availableWidth - CGFloat(columnCount - 1) * flowLayout.minimumInteritemSpacing) / CGFloat(columnCount))
        if flowLayout.itemSize.width != side {
            flowLayout.itemSize = NSSize(width: side, height: side)
            flowLayout.invalidateLayout()
        }
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

    @objc private func importBlossom(_ sender: NSButton) {
        guard let onImportBlossom else { return }
        blossomButton.isEnabled = false
        statusLabel.stringValue = "Importing Blossom media…"
        statusLabel.textColor = .secondaryLabelColor

        Task { [weak self] in
            do {
                let summary = try await onImportBlossom()
                self?.statusLabel.stringValue = "Media import complete: \(summary.downloadedCount) downloaded, \(summary.alreadyStoredCount) already stored."
                self?.statusLabel.textColor = summary.failedCount == 0 ? .secondaryLabelColor : .systemOrange
                self?.reloadMedia()
            } catch {
                self?.statusLabel.stringValue = error.localizedDescription
                self?.statusLabel.textColor = .systemRed
            }
            self?.blossomButton.isEnabled = true
        }
    }

    private func reloadMedia() {
        let timestampsByEventID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0.createdAt) })
        items = BlossomMediaReference.find(in: events).compactMap { reference in
            guard let localURL = try? mediaStore.localURL(for: reference.hash),
                  Self.isDisplayableMedia(localURL) else { return nil }
            return MediaItem(
                reference: reference,
                localURL: localURL,
                createdAt: reference.eventIDs.compactMap { timestampsByEventID[$0] }.max(),
                isVideo: Self.isVideo(localURL)
            )
        }.sorted {
            switch ($0.createdAt, $1.createdAt) {
            case let (left?, right?): return left == right ? $0.reference.hash < $1.reference.hash : left > right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return $0.reference.hash < $1.reference.hash
            }
        }
        countLabel.stringValue = items.isEmpty ? "Media" : "\(items.count) \(items.count == 1 ? "item" : "items") · newest first"
        emptyLabel.isHidden = !items.isEmpty
        collectionView.reloadData()
    }

    private func thumbnail(for item: MediaItem, completion: @escaping (NSImage?) -> Void) {
        if let image = thumbnailCache[item.reference.hash] { completion(image); return }
        let hash = item.reference.hash
        Task { [weak self] in
            let cgImage = await Task.detached(priority: .userInitiated) {
                await Self.makeThumbnail(for: item)
            }.value
            guard let self else { return }
            // Create NSImage only on the main actor. AppKit's lazy image decoding
            // can otherwise create a bitmap context on a background thread.
            let image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
            self.thumbnailCache[hash] = image
            completion(image)
        }
    }

    nonisolated private static func makeThumbnail(for item: MediaItem) async -> CGImage? {
        if item.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.localURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
            return normalizedThumbnail(from: image)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(item.localURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return normalizedThumbnail(from: image)
    }

    /// AppKit has trouble rendering certain RGB images advertised as 32-bit
    /// bitmaps. Draw into a known-good sRGB/RGBA surface before displaying it.
    nonisolated private static func normalizedThumbnail(from image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private func openMedia(at index: Int) {
        let references = items.map(\.reference)
        let overlay = MediaFocusOverlay(references: references, initialReference: items[index].reference, mediaStore: mediaStore)
        overlay.present(over: view)
    }

    private static func isVideo(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) { return true }
        return ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased())
    }

    private static func isDisplayableMedia(_ url: URL) -> Bool {
        if isVideo(url) { return true }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true || NSImage(contentsOf: url) != nil
    }
}

extension MediaLibraryViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: MediaGridItem.identifier, for: indexPath) as! MediaGridItem
        let item = items[indexPath.item]
        cell.configure(item: item, thumbnail: thumbnailCache[item.reference.hash])
        if thumbnailCache[item.reference.hash] == nil {
            thumbnail(for: item) { [weak collectionView] image in
                guard let collectionView,
                      collectionView.numberOfItems(inSection: 0) > indexPath.item else { return }
                (collectionView.item(at: indexPath) as? MediaGridItem)?.setThumbnail(image)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item else { return }
        openMedia(at: index)
        collectionView.deselectItems(at: indexPaths)
    }
}

@MainActor
private final class MediaGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MediaGridItem")
    private let thumbnailView = AspectFillImageView()
    private let videoBadge = NSTextField(labelWithString: "VIDEO")

    override func loadView() { view = MediaGridCardView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        (view as? MediaGridCardView)?.onHoverChanged = { [weak self] isHovering in
            self?.animateHover(isHovering)
        }
        (view as? MediaGridCardView)?.onPressed = { [weak self] in
            self?.animatePress()
        }
        (view as? MediaGridCardView)?.onReleased = { [weak self] in
            self?.animateRelease()
        }
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 8
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        thumbnailView.contentTintColor = .secondaryLabelColor
        videoBadge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        videoBadge.textColor = .white
        videoBadge.backgroundColor = .black.withAlphaComponent(0.6)
        videoBadge.wantsLayer = true
        videoBadge.layer?.cornerRadius = 4
        videoBadge.layer?.masksToBounds = true
        videoBadge.alignment = .center
        videoBadge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnailView)
        view.addSubview(videoBadge)
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor), thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor), thumbnailView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoBadge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), videoBadge.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            videoBadge.widthAnchor.constraint(equalToConstant: 43), videoBadge.heightAnchor.constraint(equalToConstant: 19)
        ])
    }

    func configure(item: MediaLibraryViewController.MediaItem, thumbnail: NSImage?) {
        videoBadge.isHidden = !item.isVideo
        setThumbnail(thumbnail)
    }

    func setThumbnail(_ image: NSImage?) {
        thumbnailView.image = image ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        thumbnailView.contentTintColor = image == nil ? .secondaryLabelColor : nil
    }

    private func animateHover(_ isHovering: Bool) {
        guard let layer = view.layer else { return }
        let opacity: Float = isHovering ? 0.9 : 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = opacity
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
        layer.add(animation, forKey: "mediaGridHoverOpacity")
    }

    private func animatePress() {
        guard let layer = view.layer else { return }
        centerAnimationAnchor(for: layer)
        let pressedTransform = CATransform3DMakeScale(0.96, 0.96, 1)
        let pressAnimation = CABasicAnimation(keyPath: "transform")
        pressAnimation.fromValue = layer.presentation()?.transform ?? layer.transform
        pressAnimation.toValue = pressedTransform
        pressAnimation.duration = 0.09
        pressAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = pressedTransform
        CATransaction.commit()
        layer.add(pressAnimation, forKey: "mediaGridPressScale")
        CATransaction.flush()
    }

    private func animateRelease() {
        guard let layer = view.layer else { return }
        let releaseAnimation = CABasicAnimation(keyPath: "transform")
        releaseAnimation.fromValue = layer.presentation()?.transform ?? layer.transform
        releaseAnimation.toValue = CATransform3DIdentity
        releaseAnimation.duration = 0.16
        releaseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.transform = CATransform3DIdentity
        layer.add(releaseAnimation, forKey: "mediaGridPressScale")
    }

    private func centerAnimationAnchor(for layer: CALayer) {
        let center = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != center else { return }
        let oldAnchor = layer.anchorPoint
        let position = layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = center
        layer.position = CGPoint(
            x: position.x + (center.x - oldAnchor.x) * layer.bounds.width,
            y: position.y + (center.y - oldAnchor.y) * layer.bounds.height
        )
        CATransaction.commit()
    }
}

@MainActor
private final class MediaGridCardView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var mouseUpMonitor: Any?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onPressed?()
        removeMouseUpMonitor()
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.onReleased?()
            self?.removeMouseUpMonitor()
            return event
        }
        super.mouseDown(with: event)
    }

    private func removeMouseUpMonitor() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }
}
