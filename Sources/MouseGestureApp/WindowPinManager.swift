import AVFoundation
import AppKit
import CoreMedia
import MouseGestureCore
import ScreenCaptureKit

@MainActor
final class WindowPinManager {
    /// How often a pinned window's position and coverage are checked.
    private static let refreshInterval: TimeInterval = 0.25
    private var sessions: [CGWindowID: WindowPinSession] = [:]
    private var refreshTimer: Timer?

    func toggle(window: WindowInfo, focusHandler: @escaping () -> Void) {
        if let existing = sessions.removeValue(forKey: window.id) {
            existing.stop()
            updateRefreshTimer()
            return
        }

        guard ScreenRecordingPermission.isGranted || ScreenRecordingPermission.request() else {
            ScreenRecordingPermission.openSystemSettings()
            return
        }

        let session = WindowPinSession(window: window, focusHandler: focusHandler) { [weak self] in
            // The source window closed or capture ended.
            self?.sessions.removeValue(forKey: window.id)?.stop()
            self?.updateRefreshTimer()
        }
        sessions[window.id] = session
        session.start { [weak self] result in
            switch result {
            case .success:
                self?.refresh()
            case .failure(let error):
                self?.sessions.removeValue(forKey: window.id)?.stop()
                self?.updateRefreshTimer()
                self?.showCaptureError(error)
            }
        }
        updateRefreshTimer()
    }

    func unpin(at quartzLocation: CGPoint) -> Bool {
        guard let entry = sessions.first(where: { $0.value.contains(quartzLocation) }) else { return false }
        sessions.removeValue(forKey: entry.key)?.stop()
        updateRefreshTimer()
        return true
    }

    func stopAll() {
        let activeSessions = sessions.values
        sessions.removeAll()
        for session in activeSessions {
            session.stop()
        }
        updateRefreshTimer()
    }

    private func updateRefreshTimer() {
        if sessions.isEmpty {
            refreshTimer?.invalidate()
            refreshTimer = nil
        } else if refreshTimer == nil {
            let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
    }

    /// Mirror each pinned window only while another window covers it, at its
    /// current frame; when nothing covers it the real window stays usable.
    private func refresh() {
        guard !sessions.isEmpty else { return }
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = raw.compactMap(Self.screenWindow(from:))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let stageManagerPIDs = Set(NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.WindowManager").map(\.processIdentifier))

        for (id, session) in sessions {
            let state = PinPresentation.state(
                of: id, frontToBack: windows, ignoringOwners: [ownPID],
                stageManagerOwners: stageManagerPIDs, lastFullFrame: session.lastFullFrame)
            if state == .hidden, Self.isClosed(id) {
                sessions.removeValue(forKey: id)?.stop()
                continue
            }
            session.present(state)
        }
        updateRefreshTimer()
    }

    private static func isClosed(_ id: CGWindowID) -> Bool {
        let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return raw.isEmpty
    }

    private static func screenWindow(from dictionary: [String: Any]) -> ScreenWindow? {
        guard let id = dictionary[kCGWindowNumber as String] as? NSNumber,
              let pid = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else { return nil }
        return ScreenWindow(
            id: id.uint32Value, ownerPID: pid.int32Value, bounds: bounds,
            layer: (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }

    private func showCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法置顶窗口"
        alert.informativeText = "创建实时窗口镜像失败：\(error.localizedDescription)"
        alert.runModal()
    }
}

private final class WindowPinSession: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Frame rates while the mirror is shown and while the real window is exposed.
    private static let visibleFrameRate: Int32 = 15
    private static let standbyFrameRate: Int32 = 2
    private static let maximumCaptureEdge: CGFloat = 6_000

    private let window: WindowInfo
    private let panel: PinnedPanel
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let sampleQueue = DispatchQueue(label: "com.yaoyinliang.MouseGesture.window-capture")
    private let onStop: @MainActor () -> Void
    private var stream: SCStream?
    private var hasFrame = false
    private var mirrorShown = false
    private var captureSize: CGSize = .zero
    private var frameRate: Int32 = 0
    /// Backing scale of the screen showing the window (2 on HiDPI).
    private var pixelScale: CGFloat
    /// The window's last frame outside Stage Manager's strip.
    private(set) var lastFullFrame: CGRect?

    init(window: WindowInfo, focusHandler: @escaping () -> Void, onStop: @escaping @MainActor () -> Void) {
        self.window = window
        self.onStop = onStop
        lastFullFrame = window.bounds
        panel = PinnedPanel(quartzFrame: window.bounds, focusHandler: focusHandler)
        pixelScale = PinnedPanel.backingScale(for: window.bounds)
        super.init()
        configureDisplayLayer()
    }

    func contains(_ quartzLocation: CGPoint) -> Bool {
        (lastFullFrame ?? window.bounds).contains(quartzLocation)
    }

    @MainActor
    func present(_ state: PinnedWindowState) {
        switch state {
        case .hidden:
            setMirrorShown(false)
            updateCapture(size: nil, frameRate: Self.standbyFrameRate)
        case .exposed(let frame):
            lastFullFrame = frame
            setMirrorShown(false)
            updateCapture(size: frame.size, frameRate: Self.standbyFrameRate)
        case .covered(let frame):
            if frame != lastFullFrame { lastFullFrame = frame }
            panel.setQuartzFrame(frame)
            setPixelScale(PinnedPanel.backingScale(for: frame))
            updateCapture(size: frame.size, frameRate: Self.visibleFrameRate)
            setMirrorShown(true)
        }
    }

    /// The window may move to a screen with a different scale.
    @MainActor
    private func setPixelScale(_ scale: CGFloat) {
        guard scale != pixelScale else { return }
        pixelScale = scale
        displayLayer.contentsScale = scale
        captureSize = .zero
    }

    @MainActor
    private func setMirrorShown(_ shown: Bool) {
        guard shown != mirrorShown else { return }
        mirrorShown = shown
        if shown, hasFrame { panel.orderFrontRegardless() } else if !shown { panel.orderOut(nil) }
    }

    /// Lower the frame rate while the mirror is hidden and keep the capture
    /// size matched to the window after it is resized.
    @MainActor
    private func updateCapture(size: CGSize?, frameRate rate: Int32) {
        guard let stream else { return }
        let newSize = size ?? captureSize
        guard rate != frameRate || newSize != captureSize else { return }
        frameRate = rate
        captureSize = newSize
        let configuration = captureConfiguration(for: CGRect(origin: .zero, size: newSize), frameRate: rate)
        Task { try? await stream.updateConfiguration(configuration) }
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                guard let sourceWindow = content.windows.first(where: { $0.windowID == self.window.id }) else {
                    throw WindowPinError.windowUnavailable
                }

                let filter = SCContentFilter(desktopIndependentWindow: sourceWindow)
                let configuration = self.captureConfiguration(
                    for: sourceWindow.frame, frameRate: Self.standbyFrameRate)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                try await stream.startCapture()
                await MainActor.run {
                    self.stream = stream
                    self.captureSize = sourceWindow.frame.size
                    self.frameRate = Self.standbyFrameRate
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func stop() {
        panel.orderOut(nil)
        displayLayer.flushAndRemoveImage()
        let activeStream = stream
        stream = nil
        Task {
            try? await activeStream?.stopCapture()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        displayLayer.enqueue(sampleBuffer)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasFrame else { return }
            self.hasFrame = true
            if self.mirrorShown { self.panel.orderFrontRegardless() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.panel.orderOut(nil)
            self?.onStop()
        }
    }

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.contentsScale = pixelScale
        displayLayer.backgroundColor = NSColor.clear.cgColor
        displayLayer.frame = panel.contentView?.bounds ?? .zero
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.addSublayer(displayLayer)
    }

    private func captureConfiguration(for frame: CGRect, frameRate: Int32) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Capture one pixel per screen pixel so the mirror matches the real
        // window on a HiDPI display; cap only very large windows.
        let longestEdge = max(frame.width, frame.height)
        let scale = max(1, min(pixelScale, Self.maximumCaptureEdge / max(longestEdge, 1)))
        configuration.width = max(2, Int(frame.width * scale))
        configuration.height = max(2, Int(frame.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }
}

private enum WindowPinError: LocalizedError {
    case windowUnavailable

    var errorDescription: String? {
        "找不到要置顶的窗口。"
    }
}

private final class PinnedPanel: NSPanel {
    init(quartzFrame: CGRect, focusHandler: @escaping () -> Void) {
        super.init(
            contentRect: Self.cocoaFrame(from: quartzFrame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovable = false
        contentView = PinnedContentView(frame: NSRect(origin: .zero, size: frame.size), onClick: focusHandler)
    }

    func setQuartzFrame(_ quartzFrame: CGRect) {
        let frame = Self.cocoaFrame(from: quartzFrame)
        if frame != self.frame { setFrame(frame, display: false) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func backingScale(for quartzFrame: CGRect) -> CGFloat {
        let cocoa = cocoaFrame(from: quartzFrame)
        let screen = NSScreen.screens.max { lhs, rhs in
            area(lhs.frame.intersection(cocoa)) < area(rhs.frame.intersection(cocoa))
        }
        return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    private static func cocoaFrame(from quartzFrame: CGRect) -> CGRect {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.intersects(quartzFrame) else { continue }
            return CGRect(
                x: screen.frame.minX + quartzFrame.minX - displayBounds.minX,
                y: screen.frame.maxY - (quartzFrame.minY - displayBounds.minY) - quartzFrame.height,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
        }

        let mainFrame = NSScreen.main?.frame ?? .zero
        return CGRect(
            x: quartzFrame.minX,
            y: mainFrame.maxY - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

private final class PinnedContentView: NSView {
    private let onClick: () -> Void

    init(frame: NSRect, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
