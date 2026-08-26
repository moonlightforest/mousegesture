import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

@MainActor
final class WindowPinManager {
    private var sessions: [CGWindowID: WindowPinSession] = [:]

    func toggle(window: WindowInfo, focusHandler: @escaping () -> Void) {
        if let existing = sessions.removeValue(forKey: window.id) {
            existing.stop()
            return
        }

        guard ScreenRecordingPermission.isGranted || ScreenRecordingPermission.request() else {
            ScreenRecordingPermission.openSystemSettings()
            return
        }

        let session = WindowPinSession(window: window, focusHandler: focusHandler)
        sessions[window.id] = session
        session.start { [weak self] result in
            guard case .failure(let error) = result else { return }
            self?.sessions.removeValue(forKey: window.id)?.stop()
            self?.showCaptureError(error)
        }
    }

    func unpin(at quartzLocation: CGPoint) -> Bool {
        guard let entry = sessions.first(where: { $0.value.contains(quartzLocation) }) else { return false }
        sessions.removeValue(forKey: entry.key)?.stop()
        return true
    }

    func stopAll() {
        let activeSessions = sessions.values
        sessions.removeAll()
        for session in activeSessions {
            session.stop()
        }
    }

    private func showCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法置顶窗口"
        alert.informativeText = "创建实时窗口镜像失败：\(error.localizedDescription)"
        alert.runModal()
    }
}

private final class WindowPinSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let window: WindowInfo
    private let panel: PinnedPanel
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let sampleQueue = DispatchQueue(label: "com.yaoyinliang.MouseGesture.window-capture")
    private var stream: SCStream?
    private var hasPresentedPanel = false

    init(window: WindowInfo, focusHandler: @escaping () -> Void) {
        self.window = window
        panel = PinnedPanel(quartzFrame: window.bounds, focusHandler: focusHandler)
        super.init()
        configureDisplayLayer()
    }

    func contains(_ quartzLocation: CGPoint) -> Bool {
        window.bounds.contains(quartzLocation)
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
                let configuration = self.captureConfiguration(for: sourceWindow.frame)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                self.stream = stream
                try await stream.startCapture()
                await MainActor.run {
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

        if !hasPresentedPanel {
            hasPresentedPanel = true
            DispatchQueue.main.async { [weak self] in
                self?.panel.orderFrontRegardless()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.clear.cgColor
        displayLayer.frame = panel.contentView?.bounds ?? .zero
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.addSublayer(displayLayer)
    }

    private func captureConfiguration(for frame: CGRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let longestEdge = max(frame.width, frame.height)
        let scale = min(2, 1_600 / max(longestEdge, 1))
        configuration.width = max(2, Int(frame.width * scale))
        configuration.height = max(2, Int(frame.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
