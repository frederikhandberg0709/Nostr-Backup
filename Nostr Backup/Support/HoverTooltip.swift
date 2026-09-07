import Cocoa
import ObjectiveC

/// A delayed hover tooltip that stays inside the app window's visible area.
/// Install it on any `NSView` with `view.setHoverTooltip("Helpful text")`.
@MainActor
final class HoverTooltip: NSObject {
    private weak var hostView: NSView?
    private let text: String
    private let delay: TimeInterval
    private var trackingArea: NSTrackingArea?
    private var pendingPresentation: DispatchWorkItem?
    private var tooltipPanel: NSPanel?

    init(hostView: NSView, text: String, delay: TimeInterval) {
        self.hostView = hostView
        self.text = text
        self.delay = delay
        super.init()

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hostView.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    deinit {
        pendingPresentation?.cancel()
        let tooltipPanel = tooltipPanel
        let hostView = hostView
        let trackingArea = trackingArea
        MainActor.assumeIsolated {
            tooltipPanel?.close()
            if let hostView, let trackingArea {
                hostView.removeTrackingArea(trackingArea)
            }
        }
    }

    @objc(mouseEntered:)
    func mouseEntered(_ event: NSEvent) {
        pendingPresentation?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.present() }
        pendingPresentation = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @objc(mouseExited:)
    func mouseExited(_ event: NSEvent) {
        pendingPresentation?.cancel()
        pendingPresentation = nil
        dismiss()
    }

    private func present() {
        pendingPresentation = nil
        guard let hostView,
              let window = hostView.window,
              hostView.isHidden == false else { return }

        // A single host can never have more than one bubble, even if the view
        // receives repeated tracking events while the cursor is inside it.
        dismiss()
        let maximumWidth = max(120, min(320, window.frame.width - 24))
        let bubble = TooltipBubbleView(text: text, maximumWidth: maximumWidth)
        let bubbleSize = bubble.frame.size
        let sourceInWindow = hostView.convert(hostView.bounds, to: nil)
        let sourceOnScreen = window.convertToScreen(sourceInWindow)
        guard let visibleFrame = window.screen?.visibleFrame else { return }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: bubbleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = window.level + 1
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = bubble
        panel.setFrame(frame(for: bubbleSize, beside: sourceOnScreen, in: visibleFrame), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        tooltipPanel = panel
    }

    private func dismiss() {
        guard let tooltipPanel else { return }
        tooltipPanel.parent?.removeChildWindow(tooltipPanel)
        tooltipPanel.orderOut(nil)
        tooltipPanel.close()
        self.tooltipPanel = nil
    }

    private func frame(for size: NSSize, beside source: NSRect, in contentBounds: NSRect) -> NSRect {
        let insetBounds = contentBounds.insetBy(dx: 12, dy: 12)
        let gap: CGFloat = 8
        let centeredX = source.midX - size.width / 2
        let centeredY = source.midY - size.height / 2

        let top = NSRect(x: centeredX, y: source.maxY + gap, width: size.width, height: size.height)
        if top.maxY <= insetBounds.maxY { return clamped(top, to: insetBounds) }

        let bottom = NSRect(x: centeredX, y: source.minY - gap - size.height, width: size.width, height: size.height)
        if bottom.minY >= insetBounds.minY { return clamped(bottom, to: insetBounds) }

        let left = NSRect(x: source.minX - gap - size.width, y: centeredY, width: size.width, height: size.height)
        if left.minX >= insetBounds.minX { return clamped(left, to: insetBounds) }

        let right = NSRect(x: source.maxX + gap, y: centeredY, width: size.width, height: size.height)
        if right.maxX <= insetBounds.maxX { return clamped(right, to: insetBounds) }

        // The window is smaller than the bubble in every direction. Keep the
        // preferred top placement as visible as possible rather than clipping it.
        return clamped(top, to: insetBounds)
    }

    private func clamped(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        NSRect(
            x: min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width)),
            y: min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height)),
            width: frame.width,
            height: frame.height
        )
    }
}

@MainActor
private final class TooltipBubbleView: NSView {
    private let label: NSTextField

    init(text: String, maximumWidth: CGFloat) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = max(1, maximumWidth - 20)
        let labelSize = label.fittingSize
        frame.size = NSSize(
            width: min(maximumWidth, ceil(labelSize.width) + 20),
            height: ceil(labelSize.height) + 12
        )
        label.frame = NSRect(x: 10, y: 6, width: frame.width - 20, height: frame.height - 12)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
}

private var hoverTooltipAssociationKey: UInt8 = 0

extension NSView {
    /// Adds a custom hover tooltip. Passing `nil` removes an existing tooltip.
    func setHoverTooltip(_ text: String?, delay: TimeInterval = 0.55) {
        if let text, !text.isEmpty {
            let tooltip = HoverTooltip(hostView: self, text: text, delay: delay)
            objc_setAssociatedObject(self, &hoverTooltipAssociationKey, tooltip, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        } else {
            objc_setAssociatedObject(self, &hoverTooltipAssociationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
