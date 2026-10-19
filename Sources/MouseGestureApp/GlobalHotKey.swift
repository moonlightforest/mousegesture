import AppKit
import Carbon.HIToolbox
import MouseGestureCore
import OSLog

private let hotKeyLogger = Logger(subsystem: "com.yaoyinliang.MouseGesture", category: "HotKey")

/// A system-wide shortcut registered with the Carbon hot-key API. It needs no
/// extra permission, does not depend on the gesture event tap (so it still
/// works while gestures are paused), and fires on the main thread.
@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x4D47_484B // "MGHK"

    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: RecordedShortcut?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register(_ shortcut: RecordedShortcut) {
        guard shortcut != registered || hotKeyRef == nil else { return }
        unregister()
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifierRawValue),
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            hotKeyLogger.error("Toggle shortcut registration failed status=\(status) key=\(shortcut.keyCode)")
            return
        }
        hotKeyRef = ref
        registered = shortcut
        hotKeyLogger.notice("Toggle shortcut registered key=\(shortcut.keyCode) modifiers=\(shortcut.modifierRawValue)")
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private static func carbonModifiers(_ rawValue: UInt64) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(rawValue))
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
