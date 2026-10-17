import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MouseGestureCore
import OSLog

private let gestureLogger = Logger(subsystem: "com.yaoyinliang.MouseGesture", category: "GestureEngine")

enum InputListenerStatus { case running, paused, faulted, permissionMissing }

final class GestureEngine {
    static let syntheticEventMarker: Int64 = 0x4D47_5354

    private struct TrackingState {
        var stroke: GestureStroke
        var shortVerticalStroke: ShortVerticalStroke
        let thresholdAtMouseDown: CGFloat
        var firstCommittedDirection: GestureDirection?
        var relativeStroke = GestureStroke(start: .zero)
        var relativePosition = CGPoint.zero
        let token: InputToken
        let shortcutTarget: Task<ShortcutTarget?, Never>
        let startedAt = ProcessInfo.processInfo.systemUptime
        let prePressMotion: [MotionSample]
        var dragPoints: [CGPoint] = []
        var dragCount = 0
        var moveCount = 0

        init(start: CGPoint, threshold: CGFloat, token: InputToken, shortcutTarget: Task<ShortcutTarget?, Never>,
             prePressMotion: [MotionSample]) {
            self.prePressMotion = prePressMotion
            stroke = GestureStroke(start: start)
            shortVerticalStroke = ShortVerticalStroke(start: start)
            thresholdAtMouseDown = threshold
            self.token = token
            self.shortcutTarget = shortcutTarget
        }

        mutating func record(_ event: CGEvent) {
            stroke.record(event.location)
            relativePosition.x += CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
            relativePosition.y += CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
            relativeStroke.record(relativePosition)
        }

        mutating func recordDrag(_ event: CGEvent) {
            record(event)
            shortVerticalStroke.recordDrag(event.location)
            if dragPoints.count < 256 { dragPoints.append(event.location) }
            dragCount += 1
            if firstCommittedDirection == nil, dragCount >= 2 {
                firstCommittedDirection = GestureClassifier(threshold: thresholdAtMouseDown)
                    .direction(from: stroke.start, to: event.location)
            }
        }
    }

    private let inputLoop = InputRunLoop()
    private let diagnosticsQueue = DispatchQueue(label: "MouseGesture.Diagnostics")
    private let lifetime: InputLifetime
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tracking: TrackingState?
    private var recentMotion = RecentMotion()
    private var rightPressCaptured = false
    private var enabled = true
    private var inputFaulted = false
    private var threshold: CGFloat = 40
    private var nextRightClickEventNumber: Int64 = 0
    private let captureShortcutTarget: @MainActor (InputToken) -> Task<ShortcutTarget?, Never>
    private let actionHandler: @MainActor (GestureDirection, CGPoint, ShortcutTarget?, InputToken) -> Void
    private let statusHandler: (InputListenerStatus) -> Void

    init(lifetime: InputLifetime,
         captureShortcutTarget: @escaping @MainActor (InputToken) -> Task<ShortcutTarget?, Never>,
         actionHandler: @escaping @MainActor (GestureDirection, CGPoint, ShortcutTarget?, InputToken) -> Void,
         statusHandler: @escaping (InputListenerStatus) -> Void) {
        self.lifetime = lifetime
        self.captureShortcutTarget = captureShortcutTarget
        self.actionHandler = actionHandler
        self.statusHandler = statusHandler
    }

    func update(enabled: Bool, threshold: CGFloat) {
        lifetime.configure(enabled: enabled)
        inputLoop.perform { [weak self] in
            guard let self else { return }
            self.enabled = enabled
            self.threshold = threshold
            if !enabled { self.stopOnInputThread(); self.publish(.paused) }
        }
    }
    func foregroundChanged(to pid: Int32) {
        guard lifetime.foregroundChanged(to: pid) else { return }
        inputLoop.perform { [weak self] in self?.tracking = nil; self?.recentMotion.removeAll() }
    }
    func recover() {
        lifetime.recover()
        inputLoop.perform { [weak self] in
            guard let self else { return }
            self.stopOnInputThread()
            self.inputFaulted = false
            _ = self.startOnInputThread()
        }
    }
    private func publish(_ status: InputListenerStatus) {
        DispatchQueue.main.async { [statusHandler] in statusHandler(status) }
    }
    func start() {
        inputLoop.perform { [weak self] in _ = self?.startOnInputThread() }
    }

    @discardableResult
    private func startOnInputThread() -> Bool {
        guard enabled else { publish(.paused); return false }
        guard !inputFaulted else { publish(.faulted); return false }
        guard AccessibilityPermission.isGranted else { publish(.permissionMissing); return false }
        guard eventTap == nil else { return true }

        let interestedTypes: [CGEventType] = [
            .rightMouseDown,
            .rightMouseDragged,
            .rightMouseUp,
            .mouseMoved, .leftMouseDown, .otherMouseDown, .keyDown, .scrollWheel
        ]
        let mask = interestedTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<GestureEngine>.fromOpaque(userInfo).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            inputFaulted = true
            lifetime.fault()
            publish(.faulted)
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        publish(.running)
        diagnosticsQueue.async { gestureLogger.notice("Right-mouse event tap started on dedicated input thread") }
        return true
    }

    func stop() {
        lifetime.invalidate()
        inputLoop.perform { [weak self] in self?.stopOnInputThread(); self?.publish(.paused) }
    }
    func shutdown() {
        stop()
        inputLoop.shutdown()
    }
    private func stopOnInputThread() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode) }
        eventTap = nil
        runLoopSource = nil
        tracking = nil
        recentMotion.removeAll()
        rightPressCaptured = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Fail open: a repeatedly re-enabled filter can interfere with the
            // whole input session. Require manual recovery after an input fault.
            diagnosticsQueue.async { gestureLogger.error("Input listener disabled by system; interception stopped until manual recovery") }
            inputFaulted = true
            lifetime.fault()
            stopOnInputThread()
            publish(.faulted)
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let isEnabled = enabled && !inputFaulted
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        switch type {
        case .leftMouseDown, .otherMouseDown, .keyDown, .scrollWheel:
            lifetime.invalidate()
            tracking = nil
            recentMotion.removeAll()
            return Unmanaged.passUnretained(event)

        case .rightMouseDown:
            rightPressCaptured = true
            let token = lifetime.begin()
            let prePressMotion = recentMotion.samples
            recentMotion.removeAll()
            let target = Task { @MainActor [captureShortcutTarget, lifetime] in
                guard lifetime.isCurrent(token) else { return nil as ShortcutTarget? }
                return await captureShortcutTarget(token).value
            }
            tracking = TrackingState(start: event.location, threshold: threshold, token: token, shortcutTarget: target,
                                     prePressMotion: prePressMotion)
            return nil

        case .rightMouseDragged:
            tracking?.recordDrag(event)
            return rightPressCaptured ? nil : Unmanaged.passUnretained(event)

        case .mouseMoved:
            if tracking != nil {
                tracking?.record(event)
                tracking?.shortVerticalStroke.recordDrag(event.location)
                tracking?.moveCount += 1
            } else {
                recentMotion.record(event.location, at: ProcessInfo.processInfo.systemUptime)
            }
            return Unmanaged.passUnretained(event)

        case .rightMouseUp:
            let intercepted = rightPressCaptured
            rightPressCaptured = false
            var completed = tracking
            completed?.record(event)
            completed?.shortVerticalStroke.recordDrag(event.location)
            tracking = nil
            let currentThreshold = threshold

            guard let completed, lifetime.isCurrent(completed.token) else {
                return intercepted ? nil : Unmanaged.passUnretained(event)
            }
            let originalCoordinateDirection = completed.stroke.direction(threshold: currentThreshold)
            let coordinateDirection = completed.stroke.direction(
                threshold: currentThreshold, preferring: completed.firstCommittedDirection
            )
            let relativeDirection = completed.relativeStroke.direction(threshold: currentThreshold)
            let shortVerticalDirection = completed.shortVerticalStroke.direction(threshold: currentThreshold)
            let prePressDirection = PrePressGesture.direction(
                before: completed.prePressMotion, pressedAt: completed.startedAt, press: completed.stroke.start,
                drags: completed.dragPoints, release: event.location,
                releasedAt: ProcessInfo.processInfo.systemUptime, threshold: currentThreshold
            )
            let prePressOffset = completed.prePressMotion.first.map {
                CGPoint(x: completed.stroke.start.x - $0.point.x, y: completed.stroke.start.y - $0.point.y)
            } ?? .zero
            let pressGapMs = completed.prePressMotion.last.map { Int((completed.startedAt - $0.time) * 1_000) } ?? -1
            let coordinateOffset = completed.stroke.furthestDisplacement
            let axisPeak = completed.stroke.axisPeakDisplacement
            let relativeOffset = completed.relativeStroke.furthestDisplacement
            // A native device may report the opposite sign for relative Y.
            // Use the delta fallback only when the cursor's smaller movement
            // confirms the same dominant direction.
            let deltaIsAligned: Bool
            switch relativeDirection {
            case .up: deltaIsAligned = coordinateOffset.y < -1 && abs(coordinateOffset.y) >= abs(coordinateOffset.x)
            case .down: deltaIsAligned = coordinateOffset.y > 1 && GestureClassifier.isWithinDownSector(dx: coordinateOffset.x, dy: coordinateOffset.y)
            case .left: deltaIsAligned = coordinateOffset.x < -1 && abs(coordinateOffset.x) >= abs(coordinateOffset.y)
            case .right: deltaIsAligned = coordinateOffset.x > 1 && GestureClassifier(threshold: 1).direction(from: .zero, to: coordinateOffset) == .right
            case nil: deltaIsAligned = false
            }
            let deltaDirection = deltaIsAligned ? relativeDirection : nil
            let direction = prePressDirection ?? coordinateDirection ?? deltaDirection ?? shortVerticalDirection
            let decisionPath = prePressDirection != nil ? "pre-press" : coordinateDirection != nil
                ? (coordinateDirection == originalCoordinateDirection ? "coordinate" : "first-direction")
                : (deltaDirection != nil ? "delta" : (shortVerticalDirection != nil ? "short-vertical" : "none"))
            let durationMs = Int((ProcessInfo.processInfo.systemUptime - completed.startedAt) * 1_000)
            diagnosticsQueue.async {
            gestureLogger.notice(
                "Right gesture direction=\(direction?.rawValue ?? "none", privacy: .public) path=\(decisionPath, privacy: .public) threshold=\(Int(currentThreshold)) shortThreshold=\(Int(ShortVerticalStroke.minimumDistance(for: currentThreshold))) start=(\(Int(completed.stroke.start.x)),\(Int(completed.stroke.start.y))) coord=(\(Int(coordinateOffset.x)),\(Int(coordinateOffset.y))) axisPeak=(\(Int(axisPeak.x)),\(Int(axisPeak.y))) first=\(completed.firstCommittedDirection?.rawValue ?? "none", privacy: .public) delta=(\(Int(relativeOffset.x)),\(Int(relativeOffset.y))) durationMs=\(durationMs) drags=\(completed.dragCount) moves=\(completed.moveCount) prePress=(\(Int(prePressOffset.x)),\(Int(prePressOffset.y))) prePressSamples=\(completed.prePressMotion.count) pressGapMs=\(pressGapMs)"
            )
            }
            if let direction {
                Task { @MainActor [actionHandler, lifetime] in
                    let target = await completed.shortcutTarget.value
                    guard lifetime.isCurrent(completed.token) else { return }
                    actionHandler(direction, completed.stroke.start, target, completed.token)
                }
            } else {
                if hypot(coordinateOffset.x, coordinateOffset.y) >= currentThreshold {
                    diagnosticsQueue.async { gestureLogger.notice("Unassigned diagonal drag suppressed; no right-click replay") }
                    return nil
                }
                // Posting into the HID stream from this synchronous event-tap
                // callback can stall the tap. Replay after returning instead.
                DispatchQueue.main.async { [weak self] in
                    guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == completed.token.applicationPID, self.lifetime.claim(completed.token) else { return }
                    self.postNativeRightClick(at: completed.stroke.start)
                }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func postNativeRightClick(at location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        // macOS 27 needs one nonzero event number shared by the press and
        // release for a synthetic click to activate the target window.
        nextRightClickEventNumber = nextRightClickEventNumber == Int64(Int32.max)
            ? 1 : nextRightClickEventNumber + 1
        let eventNumber = nextRightClickEventNumber
        let types: [CGEventType] = [.rightMouseDown, .rightMouseUp]
        for type in types {
            guard
                let click = CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: location,
                    mouseButton: .right
                )
            else { continue }
            click.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            click.setIntegerValueField(.mouseEventNumber, value: eventNumber)
            click.post(tap: .cgSessionEventTap)
        }
    }
}
