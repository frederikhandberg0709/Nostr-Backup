import AVFoundation
import AVKit
import Cocoa

/// A window-contained media overlay. Its frame is owned by the presenting view;
/// it deliberately has no Auto Layout constraints with that view.
@MainActor
final class MediaFocusOverlay: NSView {
    private let mediaStore: BlossomMediaStore
    private let references: [BlossomMediaReference]
    private var currentIndex: Int
    private let imageView = FocusImageView()
    private let playerView = AVPlayerView()
    private let footer = NSVisualEffectView()
    private let fileLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private var player: AVPlayer?
    private var zoomScale: CGFloat = 1
    private var panOffset = CGPoint.zero
    private var rawPanOffset = CGPoint.zero
    private var dragStartOffset = CGPoint.zero
    private var baseMediaFrame = NSRect.zero
    private var zoomAnchor = CGPoint.zero
    private var ignoresMomentumUntilNextGesture = false

    var reference: BlossomMediaReference { references[currentIndex] }
    var onSave: ((BlossomMediaReference) async -> Void)?

    convenience init(reference: BlossomMediaReference, mediaStore: BlossomMediaStore) {
        self.init(references: [reference], initialReference: reference, mediaStore: mediaStore)
    }

    init(references: [BlossomMediaReference], initialReference: BlossomMediaReference, mediaStore: BlossomMediaStore) {
        precondition(!references.isEmpty, "A media overlay needs at least one item.")
        self.references = references
        currentIndex = references.firstIndex(of: initialReference) ?? 0
        self.mediaStore = mediaStore
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        configureInterface()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    func present(over parent: NSView) {
        frame = parent.bounds
        autoresizingMask = [.width, .height]
        alphaValue = 0
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        frame = parent.bounds
        layoutMedia()
        refresh()
        parent.window?.makeFirstResponder(self)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().alphaValue = 1
        }
    }

    override func layout() {
        super.layout()
        layoutMedia()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: dismiss()
        case 123: navigate(to: currentIndex - 1)
        case 124: navigate(to: currentIndex + 1)
        default: super.keyDown(with: event)
        }
    }

    // Events reaching the overlay were not handled by media or controls, and are
    // therefore backdrop clicks.
    override func mouseDown(with event: NSEvent) { dismiss() }

    override func scrollWheel(with event: NSEvent) {
        guard zoomScale > 1 else { return }
        if event.phase == .began { ignoresMomentumUntilNextGesture = false }
        if ignoresMomentumUntilNextGesture, event.momentumPhase != [] { return }
        if imageView.layer?.animation(forKey: "mediaRubberBandPosition") != nil {
            stopPanAnimation()
        }
        let maxX = baseMediaFrame.width * (zoomScale - 1) / 2
        let maxY = baseMediaFrame.height * (zoomScale - 1) / 2
        let deltaLimit: CGFloat = event.hasPreciseScrollingDeltas ? 28 : 12
        let deltaX = min(max(event.scrollingDeltaX, -deltaLimit), deltaLimit)
        let deltaY = min(max(-event.scrollingDeltaY, -deltaLimit), deltaLimit)
        rawPanOffset.x += deltaX
        rawPanOffset.y += deltaY
        rawPanOffset = limitedRawPan(rawPanOffset, maxX: maxX, maxY: maxY)
        panOffset = rubberBanded(rawPanOffset, maxX: maxX, maxY: maxY)
        logPan("scroll", input: CGPoint(x: deltaX, y: deltaY), maxX: maxX, maxY: maxY)
        applyTransform()
        if event.phase == .ended || event.phase == .cancelled {
            ignoresMomentumUntilNextGesture = true
            snapPanToBounds()
        }
    }

    func refresh() {
        messageLabel.stringValue = ""
        fileLabel.stringValue = reference.sourceURL.lastPathComponent.isEmpty ? reference.hash : reference.sourceURL.lastPathComponent
        previousButton.isHidden = currentIndex == 0
        nextButton.isHidden = currentIndex == references.count - 1
        player?.pause()
        player = nil
        playerView.player = nil

        guard let url = try? mediaStore.localURL(for: reference.hash) else {
            playerView.isHidden = true
            imageView.isHidden = false
            imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            imageView.contentTintColor = .secondaryLabelColor
            stateLabel.stringValue = "Not saved locally"
            stateLabel.textColor = .systemYellow
            saveButton.isHidden = false
            resetTransform()
            return
        }

        stateLabel.stringValue = "Saved locally"
        stateLabel.textColor = .white.withAlphaComponent(0.7)
        saveButton.isHidden = true
        if Self.isVideo(url) {
            imageView.isHidden = true
            playerView.isHidden = false
            let player = AVPlayer(url: url)
            self.player = player
            playerView.player = player
            player.play()
        } else {
            playerView.isHidden = true
            imageView.isHidden = false
            imageView.image = NSImage(contentsOf: url) ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            imageView.contentTintColor = imageView.image?.isTemplate == true ? .secondaryLabelColor : nil
        }
        resetTransform()
        layoutMedia()
    }

    func setSaving(_ isSaving: Bool) {
        saveButton.isEnabled = !isSaving
        saveButton.title = isSaving ? "Saving…" : "Save locally"
    }

    func showError(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.textColor = .systemRed
        layoutMedia()
    }

    private func configureInterface() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.onClick = { [weak self] point in self?.toggleZoom(at: point) }
        imageView.onDragStart = { [weak self] in self?.dragStartOffset = self?.rawPanOffset ?? .zero }
        imageView.onDrag = { [weak self] offset in self?.pan(by: offset) }
        imageView.onDragEnd = { [weak self] offset in self?.handleSwipe(offset) }
        imageView.onMagnify = { [weak self] amount, point in self?.adjustZoom(by: amount, at: point) }

        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = 12
        playerView.layer?.masksToBounds = true

        footer.material = .hudWindow
        footer.blendingMode = .withinWindow
        footer.state = .active
        footer.wantsLayer = true
        footer.layer?.cornerRadius = 8
        footer.layer?.masksToBounds = true
        fileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fileLabel.textColor = .white.withAlphaComponent(0.9)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        stateLabel.font = .systemFont(ofSize: 12)
        messageLabel.font = .systemFont(ofSize: 12)
        saveButton.title = "Save locally"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save(_:))

        configureNavigationButton(previousButton, symbol: "chevron.left", action: #selector(showPrevious))
        configureNavigationButton(nextButton, symbol: "chevron.right", action: #selector(showNext))
        [imageView, playerView, footer, previousButton, nextButton].forEach(addSubview)
        [fileLabel, stateLabel, messageLabel, saveButton].forEach(footer.addSubview)
    }

    private func layoutMedia() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let footerHeight: CGFloat = 38
        let available = CGSize(width: max(bounds.width - 100, 1), height: max(bounds.height - footerHeight - 104, 1))
        let source = mediaSize
        let scale = min(available.width / source.width, available.height / source.height)
        let stageSize = CGSize(width: max(1, source.width * scale), height: max(1, source.height * scale))
        let stageFrame = NSRect(
            x: (bounds.width - stageSize.width) / 2,
            y: (bounds.height - stageSize.height) / 2 + 18,
            width: stageSize.width,
            height: stageSize.height
        )
        imageView.frame = stageFrame
        playerView.frame = stageFrame
        baseMediaFrame = stageFrame
        if zoomScale == 1 { zoomAnchor = CGPoint(x: stageFrame.midX, y: stageFrame.midY) }

        let footerWidth = min(max(280, stageSize.width), max(1, bounds.width - 80))
        footer.frame = NSRect(x: (bounds.width - footerWidth) / 2, y: max(24, stageFrame.minY - 54), width: footerWidth, height: footerHeight)
        let inset: CGFloat = 10
        let saveWidth: CGFloat = saveButton.isHidden ? 0 : 100
        let stateWidth: CGFloat = 100
        let messageWidth: CGFloat = messageLabel.stringValue.isEmpty ? 0 : 140
        let fileWidth = max(CGFloat(20), footerWidth - inset * 2 - stateWidth - saveWidth - messageWidth)
        fileLabel.frame = NSRect(x: inset, y: 10, width: fileWidth, height: 18)
        stateLabel.frame = NSRect(x: fileLabel.frame.maxX + 6, y: 10, width: stateWidth, height: 18)
        saveButton.frame = NSRect(x: stateLabel.frame.maxX + 4, y: 5, width: saveWidth, height: 28)
        messageLabel.frame = NSRect(x: saveButton.frame.maxX + 4, y: 10, width: messageWidth, height: 18)
        previousButton.frame = NSRect(x: 24, y: (bounds.height - 38) / 2, width: 38, height: 38)
        nextButton.frame = NSRect(x: bounds.width - 62, y: (bounds.height - 38) / 2, width: 38, height: 38)
        applyTransform()
    }

    private var mediaSize: CGSize {
        if !playerView.isHidden { return CGSize(width: 16, height: 9) }
        if let size = imageView.image?.size, size.width > 0, size.height > 0 { return size }
        return CGSize(width: 4, height: 3)
    }

    private func configureNavigationButton(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .circular
        button.controlSize = .large
        button.contentTintColor = .white
        button.target = self
        button.action = action
    }

    @objc private func save(_ sender: NSButton) { Task { await onSave?(reference) } }
    @objc private func showPrevious() { navigate(to: currentIndex - 1) }
    @objc private func showNext() { navigate(to: currentIndex + 1) }

    private func navigate(to index: Int) {
        guard references.indices.contains(index) else { return }
        currentIndex = index
        refresh()
    }

    private func toggleZoom(at localPoint: CGPoint) {
        zoomAnchor = convert(localPoint, from: imageView)
        zoomScale = zoomScale > 1 ? 1 : 2.5
        panOffset = .zero
        rawPanOffset = .zero
        applyTransform()
    }
    private func adjustZoom(by amount: CGFloat, at localPoint: CGPoint) {
        zoomAnchor = convert(localPoint, from: imageView)
        zoomScale = min(max(zoomScale + amount, 1), 5)
        if zoomScale == 1 { panOffset = .zero; rawPanOffset = .zero }
        applyTransform()
    }
    private func resetTransform() { zoomScale = 1; panOffset = .zero; rawPanOffset = .zero; applyTransform() }
    private func pan(by offset: CGPoint) {
        guard zoomScale > 1 else { return }
        let maxX = baseMediaFrame.width * (zoomScale - 1) / 2
        let maxY = baseMediaFrame.height * (zoomScale - 1) / 2
        rawPanOffset = limitedRawPan(
            CGPoint(x: dragStartOffset.x + offset.x, y: dragStartOffset.y + offset.y),
            maxX: maxX,
            maxY: maxY
        )
        panOffset = rubberBanded(rawPanOffset, maxX: maxX, maxY: maxY)
        logPan("drag", input: offset, maxX: maxX, maxY: maxY)
        applyTransform()
    }

    private func rubberBanded(_ offset: CGPoint, maxX: CGFloat, maxY: CGFloat) -> CGPoint {
        CGPoint(
            x: rubberBand(offset.x, bound: maxX, dimension: baseMediaFrame.width),
            y: rubberBand(offset.y, bound: maxY, dimension: baseMediaFrame.height)
        )
    }

    private func rubberBand(_ value: CGFloat, bound: CGFloat, dimension: CGFloat) -> CGFloat {
        let excess = max(0, abs(value) - bound)
        guard excess > 0 else { return value }
        let resistance: CGFloat = 0.65
        let elasticLimit = elasticLimit(for: dimension)
        let distance = (excess * elasticLimit * resistance) / (elasticLimit + excess * resistance)
        return (value < 0 ? -1 : 1) * (bound + distance)
    }

    private func limitedRawPan(_ offset: CGPoint, maxX: CGFloat, maxY: CGFloat) -> CGPoint {
        func limit(_ value: CGFloat, bound: CGFloat, dimension: CGFloat) -> CGFloat {
            let elasticLimit = self.elasticLimit(for: dimension)
            return min(max(value, -bound - elasticLimit * 8), bound + elasticLimit * 8)
        }
        return CGPoint(
            x: limit(offset.x, bound: maxX, dimension: baseMediaFrame.width),
            y: limit(offset.y, bound: maxY, dimension: baseMediaFrame.height)
        )
    }

    private func elasticLimit(for dimension: CGFloat) -> CGFloat {
        min(max(dimension * 0.35, 56), 160)
    }

    private func snapPanToBounds() {
        let maxX = baseMediaFrame.width * (zoomScale - 1) / 2
        let maxY = baseMediaFrame.height * (zoomScale - 1) / 2
        let clamped = CGPoint(
            x: min(max(rawPanOffset.x, -maxX), maxX),
            y: min(max(rawPanOffset.y, -maxY), maxY)
        )
        guard clamped != rawPanOffset else { return }
        NSLog(
            "[MediaFocusPan] snap raw=(%.1f, %.1f) visual=(%.1f, %.1f) target=(%.1f, %.1f)",
            rawPanOffset.x, rawPanOffset.y, panOffset.x, panOffset.y, clamped.x, clamped.y
        )
        rawPanOffset = clamped
        panOffset = clamped
        animateMediaFrame(to: transformedMediaFrame())
    }

    private func applyTransform() {
        guard baseMediaFrame != .zero else { return }
        imageView.layer?.setAffineTransform(.identity)
        imageView.frame = transformedMediaFrame()
    }

    private func transformedMediaFrame() -> NSRect {
        let origin = CGPoint(
            x: baseMediaFrame.minX + (1 - zoomScale) * (zoomAnchor.x - baseMediaFrame.minX) + panOffset.x,
            y: baseMediaFrame.minY + (1 - zoomScale) * (zoomAnchor.y - baseMediaFrame.minY) + panOffset.y
        )
        return NSRect(
            origin: origin,
            size: CGSize(width: baseMediaFrame.width * zoomScale, height: baseMediaFrame.height * zoomScale)
        )
    }

    private func animateMediaFrame(to targetFrame: NSRect) {
        guard let layer = imageView.layer else { applyTransform(); return }
        let startPosition = layer.presentation()?.position ?? layer.position
        let startBounds = layer.presentation()?.bounds ?? layer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = targetFrame
        CATransaction.commit()

        let positionSpring = CASpringAnimation(keyPath: "position")
        positionSpring.fromValue = startPosition
        positionSpring.toValue = layer.position
        positionSpring.mass = 1
        positionSpring.stiffness = 230
        positionSpring.damping = 19
        positionSpring.duration = positionSpring.settlingDuration
        layer.add(positionSpring, forKey: "mediaRubberBandPosition")

        let boundsSpring = CASpringAnimation(keyPath: "bounds")
        boundsSpring.fromValue = startBounds
        boundsSpring.toValue = layer.bounds
        boundsSpring.mass = positionSpring.mass
        boundsSpring.stiffness = positionSpring.stiffness
        boundsSpring.damping = positionSpring.damping
        boundsSpring.duration = positionSpring.duration
        layer.add(boundsSpring, forKey: "mediaRubberBandBounds")
    }

    private func stopPanAnimation() {
        guard let layer = imageView.layer,
              let presentation = layer.presentation() else { return }
        let displayedFrame = presentation.frame
        let scaleOrigin = CGPoint(
            x: baseMediaFrame.minX + (1 - zoomScale) * (zoomAnchor.x - baseMediaFrame.minX),
            y: baseMediaFrame.minY + (1 - zoomScale) * (zoomAnchor.y - baseMediaFrame.minY)
        )
        let displayedOffset = CGPoint(
            x: displayedFrame.minX - scaleOrigin.x,
            y: displayedFrame.minY - scaleOrigin.y
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "mediaRubberBandPosition")
        layer.removeAnimation(forKey: "mediaRubberBandBounds")
        imageView.frame = displayedFrame
        CATransaction.commit()
        panOffset = displayedOffset
        rawPanOffset = displayedOffset
    }

    private func logPan(_ source: String, input: CGPoint, maxX: CGFloat, maxY: CGFloat) {
        NSLog(
            "[MediaFocusPan] %@ input=(%.1f, %.1f) raw=(%.1f, %.1f) visual=(%.1f, %.1f) bounds=(%.1f, %.1f) zoom=%.2f",
            source,
            input.x, input.y,
            rawPanOffset.x, rawPanOffset.y,
            panOffset.x, panOffset.y,
            maxX, maxY,
            zoomScale
        )
    }
    private func handleSwipe(_ offset: CGPoint) {
        if zoomScale > 1 { snapPanToBounds() }
        if abs(offset.y) > 60, abs(offset.y) > abs(offset.x) { dismiss() }
        else if abs(offset.x) > 60, abs(offset.x) > abs(offset.y) { navigate(to: currentIndex + (offset.x < 0 ? 1 : -1)) }
    }
    private func dismiss() {
        guard superview != nil else { return }
        player?.pause()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.removeFromSuperview() }
    }
    private static func isVideo(_ url: URL) -> Bool { ["mov", "mp4", "m4v", "webm", "avi"].contains(url.pathExtension.lowercased()) }
}

@MainActor
private final class FocusImageView: NSImageView {
    var onClick: ((CGPoint) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onDragStart: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        onDragStart?()
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let location = event.locationInWindow
            let offset = CGPoint(x: location.x - start.x, y: location.y - start.y)
            if event.type == .leftMouseDragged { onDrag?(offset) }
            if event.type == .leftMouseUp {
                if abs(offset.x) < 4, abs(offset.y) < 4 { onClick?(convert(location, from: nil)) }
                else { onDragEnd?(offset) }
                return
            }
        }
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification, convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}
