import ApplicationServices
import CoreGraphics
import Foundation
import MouseGestureCore
import OSLog

private let gestureLogger = Logger(subsystem: "com.yaoyinliang.MouseGesture", category: "GestureEngine")

final class GestureEngine {
    static let syntheticEventMarker: Int64 = 0x4D47_5354
    private static let postReleaseWindowMs = 120

    private struct DeferredRightClick {
        let id = UUID()
        let location: CGPoint
        let startedAt: CGPoint
        let threshold: CGFloat
        let releasedAt = ProcessInfo.processInfo.systemUptime
        let shortcutTarget: Task<ShortcutTarget?, Never>
        var stroke: GestureStroke
        var shortStroke: ShortVerticalStroke
        var moveCount = 0

        init(completed: TrackingState, location: CGPoint) {
            self.location = location
            startedAt = completed.stroke.start
            threshold = completed.thresholdAtMouseDown
            shortcutTarget = completed.shortcutTarget
            stroke = completed.stroke
            shortStroke = completed.shortVerticalStroke
        }

        mutating func record(_ location: CGPoint) {
            stroke.record(location)
            shortStroke.recordDrag(location)
            moveCount += 1
        }

        var recoveredDirection: GestureDirection? {
            PostReleaseGesture.direction(stroke: stroke, shortStroke: shortStroke,
                moveCount: moveCount, threshold: threshold)
        }

    }

    private struct TrackingState {
        var stroke: GestureStroke
        var shortVerticalStroke: ShortVerticalStroke
        let thresholdAtMouseDown: CGFloat
        var firstCommittedDirection: GestureDirection?
        var relativeStroke = GestureStroke(start: .zero)
        var relativePosition = CGPoint.zero
        let shortcutTarget: Task<ShortcutTarget?, Never>
        let startedAt = ProcessInfo.processInfo.systemUptime
        var dragCount = 0
        var moveCount = 0

        init(start: CGPoint, threshold: CGFloat, shortcutTarget: Task<ShortcutTarget?, Never>) {
            stroke = GestureStroke(start: start)
            shortVerticalStroke = ShortVerticalStroke(start: start)
            thresholdAtMouseDown = threshold
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
            dragCount += 1
            if firstCommittedDirection == nil, dragCount >= 2 {
                firstCommittedDirection = GestureClassifier(threshold: thresholdAtMouseDown)
                    .direction(from: stroke.start, to: event.location)
            }
        }
    }

    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tracking: TrackingState?
    private var deferredRightClick: DeferredRightClick?
    private var enabled = true
    private var inputFaulted = false
    private var threshold: CGFloat = 40
    private var nextRightClickEventNumber: Int64 = 0
    private let captureShortcutTarget: () -> Task<ShortcutTarget?, Never>
    private let actionHandler: (GestureDirection, CGPoint, ShortcutTarget?) -> Void

    init(captureShortcutTarget: @escaping () -> Task<ShortcutTarget?, Never>,
         actionHandler: @escaping (GestureDirection, CGPoint, ShortcutTarget?) -> Void) {
        self.captureShortcutTarget = captureShortcutTarget
        self.actionHandler = actionHandler
    }

    deinit {
        stop()
    }

    func update(enabled: Bool, threshold: CGFloat) {
        lock.lock()
        self.enabled = enabled && !inputFaulted
        self.threshold = threshold
        if !enabled {
            tracking = nil
            deferredRightClick = nil
        }
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        guard !inputFaulted, eventTap == nil, AccessibilityPermission.isGranted else { return eventTap != nil }

        let interestedTypes: [CGEventType] = [
            .rightMouseDown,
            .rightMouseDragged,
            .rightMouseUp,
            .mouseMoved
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
            gestureLogger.error("Could not create the right-mouse event tap")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        gestureLogger.notice("Right-mouse event tap started")
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        lock.lock()
        tracking = nil
        deferredRightClick = nil
        lock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Fail open: a repeatedly re-enabled filter can interfere with the
            // whole input session. Require an app restart after an input fault.
            gestureLogger.error("Input listener disabled by system; stopping interception until app restart")
            inputFaulted = true
            stop()
            lock.lock()
            enabled = false
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let isEnabled = enabled
        lock.unlock()
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        switch type {
        case .rightMouseDown:
            let target = captureShortcutTarget()
            lock.lock()
            let oldClick = deferredRightClick
            deferredRightClick = nil
            tracking = TrackingState(start: event.location, threshold: threshold, shortcutTarget: target)
            lock.unlock()
            if let oldClick {
                // Preserve an ordinary click when a second press arrives before
                // its short post-release observation window has expired.
                DispatchQueue.main.async { [weak self] in
                    self?.postNativeRightClick(at: oldClick.location)
                }
            }
            return nil

        case .rightMouseDragged:
            lock.lock()
            tracking?.recordDrag(event)
            lock.unlock()
            return nil

        case .mouseMoved:
            lock.lock()
            if tracking != nil {
                tracking?.record(event)
                tracking?.shortVerticalStroke.recordDrag(event.location)
                tracking?.moveCount += 1
            } else if let pending = deferredRightClick,
                ProcessInfo.processInfo.systemUptime - pending.releasedAt
                    <= Double(Self.postReleaseWindowMs) / 1_000 {
                deferredRightClick?.record(event.location)
            }
            lock.unlock()
            return Unmanaged.passUnretained(event)

        case .rightMouseUp:
            lock.lock()
            var completed = tracking
            completed?.record(event)
            completed?.shortVerticalStroke.recordDrag(event.location)
            tracking = nil
            let currentThreshold = threshold
            lock.unlock()

            guard let completed else { return Unmanaged.passUnretained(event) }
            let originalCoordinateDirection = completed.stroke.direction(threshold: currentThreshold)
            let coordinateDirection = completed.stroke.direction(
                threshold: currentThreshold, preferring: completed.firstCommittedDirection
            )
            let relativeDirection = completed.relativeStroke.direction(threshold: currentThreshold)
            let shortVerticalDirection = completed.shortVerticalStroke.direction(threshold: currentThreshold)
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
            let direction = coordinateDirection ?? deltaDirection ?? shortVerticalDirection
            let decisionPath = coordinateDirection != nil
                ? (coordinateDirection == originalCoordinateDirection ? "coordinate" : "first-direction")
                : (deltaDirection != nil ? "delta" : (shortVerticalDirection != nil ? "short-vertical" : "none"))
            let durationMs = Int((ProcessInfo.processInfo.systemUptime - completed.startedAt) * 1_000)
            gestureLogger.notice(
                "Right gesture direction=\(direction?.rawValue ?? "none", privacy: .public) path=\(decisionPath, privacy: .public) threshold=\(Int(currentThreshold)) shortThreshold=\(Int(ShortVerticalStroke.minimumDistance(for: currentThreshold))) start=(\(Int(completed.stroke.start.x)),\(Int(completed.stroke.start.y))) coord=(\(Int(coordinateOffset.x)),\(Int(coordinateOffset.y))) axisPeak=(\(Int(axisPeak.x)),\(Int(axisPeak.y))) first=\(completed.firstCommittedDirection?.rawValue ?? "none", privacy: .public) delta=(\(Int(relativeOffset.x)),\(Int(relativeOffset.y))) durationMs=\(durationMs) drags=\(completed.dragCount) moves=\(completed.moveCount)"
            )
            if let direction {
                Task { @MainActor [actionHandler] in
                    let target = await completed.shortcutTarget.value
                    actionHandler(direction, completed.stroke.start, target)
                }
            } else {
                let location = event.location
                if hypot(coordinateOffset.x, coordinateOffset.y) >= currentThreshold {
                    gestureLogger.notice("Unassigned diagonal drag suppressed; no right-click replay")
                    return nil
                }
                if completed.dragCount == 0 && completed.moveCount == 0 {
                    // Deskflow's movement can arrive after release even when
                    // the press lasted over 100 ms. Recover a supported gesture
                    // without treating a zero-motion click as a gesture.
                    let deferred = DeferredRightClick(completed: completed, location: location)
                    lock.lock()
                    deferredRightClick = deferred
                    lock.unlock()
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + .milliseconds(Self.postReleaseWindowMs)
                    ) { [weak self] in
                        self?.finishDeferredRightClick(id: deferred.id)
                    }
                } else {
                    // Posting into the HID stream from this synchronous event-tap
                    // callback can stall the tap. Replay after returning instead.
                    DispatchQueue.main.async { [weak self] in
                        self?.postNativeRightClick(at: location)
                    }
                }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func finishDeferredRightClick(id: UUID) {
        lock.lock()
        guard let deferred = deferredRightClick, deferred.id == id else {
            lock.unlock()
            return
        }
        deferredRightClick = nil
        lock.unlock()

        if let direction = deferred.recoveredDirection {
            let offset = deferred.stroke.axisPeakDisplacement
            gestureLogger.notice(
                "Recovered gesture direction=\(direction.rawValue, privacy: .public) from post-release motion start=(\(Int(deferred.startedAt.x)),\(Int(deferred.startedAt.y))) axisPeak=(\(Int(offset.x)),\(Int(offset.y))) moves=\(deferred.moveCount)"
            )
            Task { @MainActor [actionHandler] in
                let target = await deferred.shortcutTarget.value
                actionHandler(direction, deferred.startedAt, target)
            }
        } else {
            gestureLogger.notice("Deferred ordinary right-click replay lateMoves=\(deferred.moveCount)")
            postNativeRightClick(at: deferred.location)
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
