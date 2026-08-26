import ApplicationServices
import CoreGraphics
import Foundation
import MouseGestureCore

final class GestureEngine {
    static let syntheticEventMarker: Int64 = 0x4D47_5354

    private struct TrackingState {
        let start: CGPoint
        var latest: CGPoint
    }

    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tracking: TrackingState?
    private var enabled = true
    private var threshold: CGFloat = 40
    private let actionHandler: (GestureDirection, CGPoint) -> Void

    init(actionHandler: @escaping (GestureDirection, CGPoint) -> Void) {
        self.actionHandler = actionHandler
    }

    deinit {
        stop()
    }

    func update(enabled: Bool, threshold: CGFloat) {
        lock.lock()
        self.enabled = enabled
        self.threshold = threshold
        if !enabled { tracking = nil }
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil, AccessibilityPermission.isGranted else { return eventTap != nil }

        let interestedTypes: [CGEventType] = [
            .rightMouseDown,
            .rightMouseDragged,
            .rightMouseUp
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
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
        lock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
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
            lock.lock()
            tracking = TrackingState(start: event.location, latest: event.location)
            lock.unlock()
            return nil

        case .rightMouseDragged:
            lock.lock()
            if tracking != nil { tracking?.latest = event.location }
            lock.unlock()
            return nil

        case .rightMouseUp:
            lock.lock()
            var completed = tracking
            completed?.latest = event.location
            tracking = nil
            let currentThreshold = threshold
            lock.unlock()

            guard let completed else { return Unmanaged.passUnretained(event) }
            let classifier = GestureClassifier(threshold: currentThreshold)
            if let direction = classifier.direction(from: completed.start, to: completed.latest) {
                DispatchQueue.main.async { [actionHandler] in
                    actionHandler(direction, completed.start)
                }
            } else {
                postNativeRightClick(at: completed.latest)
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func postNativeRightClick(at location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
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
            click.post(tap: .cghidEventTap)
        }
    }
}
