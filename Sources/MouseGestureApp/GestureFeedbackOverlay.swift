import AppKit

/// A short-lived hint near the gesture. It never becomes key or main, never
/// activates the app and lets every click through. Main thread only.
@MainActor
final class GestureFeedbackOverlay {
    enum Style { case recognized, rejected }
    /// Where the hint sits relative to the cursor: beside it for vertical
    /// strokes, below it for horizontal ones, so it never lies on the path.
    enum Placement { case beside, below }

    /// Clears the arrow cursor, which extends about 12 x 19 pt right of and
    /// below its hot spot.
    static let cursorGap: CGFloat = 24
    private static let screenMargin: CGFloat = 4

    private static let visibleDuration: TimeInterval = 0.6
    private static let fadeDuration: TimeInterval = 0.15

    private var panel: NSPanel?
    private var label: NSTextField?
    private var background: NSView?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// `cgLocation` uses Quartz global coordinates (origin at the top left of
    /// the primary display), as event-tap locations do.
    func show(_ text: String, style: Style, placement: Placement, atQuartz cgLocation: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        show(text, style: style, placement: placement, at: CGPoint(x: cgLocation.x, y: primaryHeight - cgLocation.y))
    }

    /// `location` is the cursor in AppKit screen coordinates.
    func show(_ text: String, style: Style, placement: Placement, at location: CGPoint) {
        let (panel, label) = makePanelIfNeeded()
        label.attributedStringValue = NSAttributedString(string: text, attributes: [.shadow: Self.textShadow])
        // Small and quiet: a confirmation, not a notification.
        label.font = .systemFont(ofSize: style == .recognized ? 12 : 13, weight: .medium)
        // Neutral gray on the adaptive material reads on light and dark pages
        // alike; the rejected and pause hints stay a little fainter.
        label.textColor = .secondaryLabelColor
        label.alphaValue = style == .recognized ? 1 : 0.73
        label.sizeToFit()

        let size = CGSize(width: max(label.frame.width + 20, 30), height: max(label.frame.height + 10, 24))
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: CGSize(width: 1e6, height: 1e6))
        panel.setFrame(Self.frame(size: size, cursor: location, placement: placement, visible: visible), display: false)
        label.frame.origin = CGPoint(x: (size.width - label.frame.width) / 2,
                                     y: (size.height - label.frame.height) / 2)
        setCornerRadius(size.height / 2)

        hideWork?.cancel()
        generation += 1
        let shown = generation
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // A newer hint may have reused the panel during the fade.
                    guard let self, self.generation == shown else { return }
                    self.panel?.orderOut(nil)
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    /// AppKit coordinates (y grows upward). Flips to the other side of the
    /// cursor near a screen edge, then keeps the hint on that screen.
    static func frame(size: CGSize, cursor: CGPoint, placement: Placement, visible: CGRect) -> CGRect {
        let minX = visible.minX + screenMargin, maxX = visible.maxX - screenMargin
        let minY = visible.minY + screenMargin, maxY = visible.maxY - screenMargin
        var origin: CGPoint
        switch placement {
        case .beside:
            origin = CGPoint(x: cursor.x + cursorGap, y: cursor.y - size.height / 2)
            if origin.x + size.width > maxX { origin.x = cursor.x - cursorGap - size.width }
        case .below:
            origin = CGPoint(x: cursor.x - size.width / 2, y: cursor.y - cursorGap - size.height)
            if origin.y < minY { origin.y = cursor.y + cursorGap }
        }
        origin.x = min(max(origin.x, minX), maxX - size.width)
        origin.y = min(max(origin.y, minY), maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    private static let textShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 1.5
        return shadow
    }()

    private func setCornerRadius(_ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            background?.layer?.cornerRadius = radius
        }
    }

    private func makePanelIfNeeded() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 80, height: 36),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]

        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        let background: NSView
        if #available(macOS 26.0, *) {
            // Liquid Glass: clear and adaptive. The label lives inside the
            // glass so the system keeps it legible over any content.
            let glass = NSGlassEffectView()
            glass.style = .clear
            let content = NSView()
            content.addSubview(label)
            glass.contentView = content
            background = glass
        } else {
            let effect = NSVisualEffectView()
            // Follows the system appearance, unlike the always-dark HUD material.
            effect.material = .toolTip
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            // A sibling of the material so the text keeps its own opacity.
            effect.addSubview(label)
            background = effect
        }
        panel.contentView = background
        self.background = background

        self.panel = panel
        self.label = label
        return (panel, label)
    }
}
