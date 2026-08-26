import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import MouseGestureCore
import OSLog

private let windowLogger = Logger(subsystem: "com.yaoyinliang.MouseGesture", category: "WindowActions")

@MainActor
final class ActionExecutor {
    private let windowController = WindowController()

    func restoreWindowLevels() {
        windowController.restorePinnedWindows()
    }

    func execute(_ action: GestureAction, gestureLocation: CGPoint) {
        switch action.kind {
        case .none:
            break
        case .copy:
            postShortcut(keyCode: 8, modifiers: .maskCommand)
        case .paste:
            postShortcut(keyCode: 9, modifiers: .maskCommand)
        case .previousWindow:
            windowController.activatePreviousWindow(from: gestureLocation)
        case .toggleAlwaysOnTop:
            windowController.toggleWindowAlwaysOnTop(at: gestureLocation)
        case .appSwitcher:
            postShortcut(keyCode: 48, modifiers: .maskCommand)
        case .screenshotSelection:
            postShortcut(keyCode: 21, modifiers: [.maskCommand, .maskShift])
        case .screenshotFull:
            postShortcut(keyCode: 20, modifiers: [.maskCommand, .maskShift])
        case .launchApplication:
            launchApplication(at: action.applicationPath)
        case .keyboardShortcut:
            guard let shortcut = action.shortcut else { return }
            postShortcut(
                keyCode: shortcut.keyCode,
                modifiers: CGEventFlags(rawValue: shortcut.modifierRawValue)
            )
        }
    }

    private func postShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
            ),
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
            )
        else { return }

        down.flags = modifiers
        up.flags = modifiers
        down.setIntegerValueField(.eventSourceUserData, value: GestureEngine.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: GestureEngine.syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func launchApplication(at path: String?) {
        guard let path, !path.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }
}

struct WindowInfo: Equatable {
    let id: CGWindowID
    let ownerPID: pid_t
    let title: String
    let bounds: CGRect
    let layer: Int
    let alpha: Double
    let isOnScreen: Bool
}

private let focusedWindowChangedCallback: AXObserverCallback = { _, _, _, context in
    guard let context else { return }
    let controller = Unmanaged<WindowController>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.recordCurrentWindow()
    }
}

@MainActor
private final class WindowController: NSObject {
    private typealias SetFrontProcessFunction =
        @convention(c) (
            UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
        ) -> Int32
    private typealias GetProcessForPIDFunction =
        @convention(c) (
            pid_t, UnsafeMutablePointer<ProcessSerialNumber>
        ) -> OSStatus

    private let pinManager = WindowPinManager()
    private var recentWindows: [WindowInfo] = []
    private var switchPair: [WindowInfo] = []
    private var lastSwitchTargetID: CGWindowID?
    private var workspaceObserver: NSObjectProtocol?
    private var accessibilityObserver: AXObserver?
    private var observedApplicationElement: AXUIElement?
    private lazy var setFrontProcess = loadSetFrontProcessFunction()
    private lazy var getProcessForPID = loadGetProcessForPIDFunction()

    override init() {
        super.init()
        observeWorkspace()
        if let app = NSWorkspace.shared.frontmostApplication {
            observeFocusedWindowChanges(for: app)
        }
        DispatchQueue.main.async { [weak self] in
            self?.recordCurrentWindow()
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let accessibilityObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(accessibilityObserver),
                .commonModes
            )
        }
    }

    func toggleWindowAlwaysOnTop(at location: CGPoint) {
        if pinManager.unpin(at: location) { return }
        guard let target = window(at: location) ?? focusedWindowInfo() else { return }
        pinManager.toggle(window: target) { [weak self] in
            self?.focus(target)
        }
    }

    func restorePinnedWindows() {
        pinManager.stopAll()
    }

    func activatePreviousWindow(from location: CGPoint) {
        // The window under the pointer can still be the old Stage Manager thumbnail after a
        // switch. The actual focused window is therefore the authoritative current window.
        let current = focusedWindowInfo() ?? window(at: location)
        if let current { record(current) }

        let currentID = current?.id
        windowLogger.debug("Previous-window action current=\(currentID ?? 0) history=\(self.recentWindows.count)")

        if switchPair.count == 2,
            currentID == nil || switchPair.contains(where: { $0.id == currentID }),
            let lastSwitchTargetID,
            let target = switchPair.first(where: { $0.id != lastSwitchTargetID }),
            let liveTarget = liveWindow(matching: target)
        {
            windowLogger.debug("Toggling paired window=\(liveTarget.id) pid=\(liveTarget.ownerPID)")
            self.lastSwitchTargetID = liveTarget.id
            focus(liveTarget)
            record(liveTarget)
            return
        }

        switchPair.removeAll()
        lastSwitchTargetID = nil

        if let target = recentWindows.first(where: {
            $0.id != currentID && isEligible($0)
        }) {
            windowLogger.debug("Focusing history window=\(target.id) pid=\(target.ownerPID)")
            beginSwitchPair(current: current, target: target)
            focus(target)
            record(target)
            return
        }

        if let fallback = allWindows().first(where: {
            $0.id != currentID && isEligible($0) && $0.isOnScreen
        }) {
            beginSwitchPair(current: current, target: fallback)
            focus(fallback)
            record(fallback)
        }
    }

    private func beginSwitchPair(current: WindowInfo?, target: WindowInfo) {
        if let current {
            switchPair = [current, target]
            lastSwitchTargetID = target.id
        }
    }

    private func liveWindow(matching savedWindow: WindowInfo) -> WindowInfo? {
        guard isEligible(savedWindow) else { return nil }
        return allWindows().first(where: { $0.id == savedWindow.id && isEligible($0) }) ?? savedWindow
    }

    fileprivate func recordCurrentWindow() {
        guard let info = focusedWindowInfo() else { return }
        record(info)
    }

    private func record(_ info: WindowInfo) {
        guard isEligible(info) else { return }
        recentWindows.removeAll { $0.id == info.id }
        recentWindows.insert(info, at: 0)
        if recentWindows.count > 12 {
            recentWindows.removeLast(recentWindows.count - 12)
        }
        windowLogger.debug("Recorded window=\(info.id) pid=\(info.ownerPID) history=\(self.recentWindows.count)")
    }

    private func observeWorkspace() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.observeFocusedWindowChanges(for: app)
                self?.recordCurrentWindow()
            }
        }
    }

    private func observeFocusedWindowChanges(for app: NSRunningApplication) {
        removeAccessibilityObserver()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var observer: AXObserver?
        guard AXObserverCreate(app.processIdentifier, focusedWindowChangedCallback, &observer) == .success,
            let observer
        else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            AXObserverAddNotification(
                observer,
                appElement,
                kAXFocusedWindowChangedNotification as CFString,
                context
            ) == .success
        else { return }

        accessibilityObserver = observer
        observedApplicationElement = appElement
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeAccessibilityObserver() {
        guard let observer = accessibilityObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        accessibilityObserver = nil
        observedApplicationElement = nil
    }

    private func window(at location: CGPoint) -> WindowInfo? {
        allWindows().first {
            isEligible($0) && $0.isOnScreen && $0.bounds.contains(location)
        }
    }

    private func focusedWindowInfo() -> WindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let candidates = allWindows().filter {
            $0.ownerPID == app.processIdentifier && isEligible($0)
        }
        guard !candidates.isEmpty else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedWindow: AXUIElement = attribute(kAXFocusedWindowAttribute, of: appElement) else {
            return candidates.first(where: \.isOnScreen) ?? candidates.first
        }

        let title: String = attribute(kAXTitleAttribute, of: focusedWindow) ?? ""
        let position = pointAttribute(kAXPositionAttribute, of: focusedWindow)
        let size = sizeAttribute(kAXSizeAttribute, of: focusedWindow)
        let frame = position.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } }
        return candidates.min {
            matchScore($0, title: title, frame: frame) < matchScore($1, title: title, frame: frame)
        }
    }

    private func focus(_ info: WindowInfo) {
        guard let runningApplication = NSRunningApplication(processIdentifier: info.ownerPID) else { return }
        runningApplication.activate(options: [])
        setWindowServerFocus(info)
        raise(info)
        DispatchQueue.main.async { [weak self] in
            self?.setWindowServerFocus(info)
            self?.raise(info)
        }
    }

    private func setWindowServerFocus(_ info: WindowInfo) {
        guard let setFrontProcess, let getProcessForPID else {
            windowLogger.error("Window focus functions are unavailable")
            return
        }
        var processSerialNumber = ProcessSerialNumber()
        let processResult = getProcessForPID(info.ownerPID, &processSerialNumber)
        guard processResult == noErr else {
            windowLogger.error("PID conversion failed result=\(processResult)")
            return
        }
        let focusResult = setFrontProcess(&processSerialNumber, info.id, 0x200)
        windowLogger.debug("WindowServer focus window=\(info.id) result=\(focusResult)")
    }

    private func raise(_ info: WindowInfo) {
        let appElement = AXUIElementCreateApplication(info.ownerPID)
        let windows: [AXUIElement] = attribute(kAXWindowsAttribute, of: appElement) ?? []
        guard
            let target = windows.min(by: {
                axMatchScore($0, info: info) < axMatchScore($1, info: info)
            })
        else { return }

        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }

    private func allWindows() -> [WindowInfo] {
        guard
            let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return raw.compactMap(windowInfo(from:))
    }

    private func windowInfo(from dictionary: [String: Any]) -> WindowInfo? {
        guard let id = dictionary[kCGWindowNumber as String] as? NSNumber,
            let pid = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
            let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else { return nil }

        return WindowInfo(
            id: id.uint32Value,
            ownerPID: pid.int32Value,
            title: dictionary[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            layer: (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            isOnScreen: (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        )
    }

    private func isEligible(_ info: WindowInfo) -> Bool {
        guard info.ownerPID != ProcessInfo.processInfo.processIdentifier,
            let application = NSRunningApplication(processIdentifier: info.ownerPID),
            !application.isTerminated,
            application.activationPolicy == .regular
        else { return false }

        return info.layer == 0 && info.alpha > 0 && info.bounds.width >= 120 && info.bounds.height >= 80
    }

    private func matchScore(_ info: WindowInfo, title: String, frame: CGRect?) -> CGFloat {
        var score: CGFloat = info.title == title ? 0 : 1_000
        if let frame {
            score += abs(info.bounds.minX - frame.minX)
            score += abs(info.bounds.minY - frame.minY)
            score += abs(info.bounds.width - frame.width)
            score += abs(info.bounds.height - frame.height)
        }
        return score
    }

    private func axMatchScore(_ element: AXUIElement, info: WindowInfo) -> CGFloat {
        let title: String = attribute(kAXTitleAttribute, of: element) ?? ""
        let position = pointAttribute(kAXPositionAttribute, of: element)
        let size = sizeAttribute(kAXSizeAttribute, of: element)
        let frame = position.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } }
        return matchScore(info, title: title, frame: frame)
    }

    private func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func pointAttribute(_ name: String, of element: AXUIElement) -> CGPoint? {
        guard let value: AXValue = attribute(name, of: element), AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ name: String, of element: AXUIElement) -> CGSize? {
        guard let value: AXValue = attribute(name, of: element), AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func loadSetFrontProcessFunction() -> SetFrontProcessFunction? {
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                RTLD_LAZY
            ), let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions")
        else { return nil }
        return unsafeBitCast(symbol, to: SetFrontProcessFunction.self)
    }

    private func loadGetProcessForPIDFunction() -> GetProcessForPIDFunction? {
        guard
            let handle = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                RTLD_LAZY
            ), let symbol = dlsym(handle, "GetProcessForPID")
        else { return nil }
        return unsafeBitCast(symbol, to: GetProcessForPIDFunction.self)
    }
}
