import AppKit
import Combine
import MouseGestureCore
import OSLog
import ServiceManagement
import SwiftUI

private let appLogger = Logger(subsystem: "com.yaoyinliang.MouseGesture", category: "Application")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore()
    private let lifetime = InputLifetime()
    private lazy var executor = ActionExecutor(lifetime: lifetime)
    private var listenerStatus: InputListenerStatus = .paused
    private var listenerStatusItem: NSMenuItem?
    private var recoverItem: NSMenuItem?
    var settingsContent: SettingsView { SettingsView(store: store) }
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var enabledItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var screenRecordingItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var cancellable: AnyCancellable?
    private var appActivationObserver: NSObjectProtocol?

    private lazy var engine = GestureEngine(lifetime: lifetime,
        captureShortcutTarget: { [weak self] token in
            guard let self else { return Task { nil } }
            return self.executor.captureShortcutTarget(token)
        }, actionHandler: { [weak self] direction, location, target, token in
            guard let self else { return }
            let action = self.store.action(for: direction)
            self.executor.execute(action, gestureLocation: location, shortcutTarget: target, token: token)
        }, statusHandler: { [weak self] status in
            guard let self else { return }
            self.listenerStatus = status
            if case .faulted = status { self.executor.cancelPendingShortcut() }
            self.refreshMenuState()
        })

    private func updateForegroundSnapshot() {
        let front = NSWorkspace.shared.frontmostApplication
        let application = (front?.processIdentifier ?? -1) > 0 ? front
            : NSWorkspace.shared.runningApplications.first { $0.isActive && $0.processIdentifier > 0 }
        engine.foregroundChanged(to: application?.processIdentifier ?? -1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.notice("Gesture input revision 16: pre-press recovery only for replayed strokes")
        appLogger.notice(
            "Permissions accessibility=\(AccessibilityPermission.isGranted) screenRecording=\(ScreenRecordingPermission.isGranted)"
        )
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        observeSettings()
        updateForegroundSnapshot()
        syncEngine()
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateForegroundSnapshot()
                self?.syncEngine()
            }
        }

        if !AccessibilityPermission.isGranted {
            AccessibilityPermission.request()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        engine.shutdown()
        executor.restoreWindowLevels()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
        syncEngine()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "鼠标手势")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        image?.accessibilityDescription = "鼠标手势"
        item.button?.image = image
        item.button?.toolTip = "MouseGesture · 鼠标手势"

        let menu = NSMenu()
        menu.delegate = self

        let title = NSMenuItem(title: "鼠标手势", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let state = NSMenuItem(title: "手势已暂停", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        listenerStatusItem = state
        let recover = NSMenuItem(title: "恢复手势监听", action: #selector(recoverListener), keyEquivalent: "")
        recover.target = self
        menu.addItem(recover)
        recoverItem = recover

        let enabled = NSMenuItem(title: "已启用", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        menu.addItem(enabled)
        enabledItem = enabled

        let gestures = NSMenuItem(title: "手势设置…", action: #selector(showSettings), keyEquivalent: ",")
        gestures.target = self
        menu.addItem(gestures)

        let permission = NSMenuItem(
            title: "辅助功能权限",
            action: #selector(openAccessibilityPermission),
            keyEquivalent: ""
        )
        permission.target = self
        menu.addItem(permission)
        permissionItem = permission

        let screenRecording = NSMenuItem(
            title: "屏幕录制权限",
            action: #selector(openScreenRecordingPermission),
            keyEquivalent: ""
        )
        screenRecording.target = self
        menu.addItem(screenRecording)
        screenRecordingItem = screenRecording

        let launchAtLogin = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        launchAtLoginItem = launchAtLogin

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshMenuState()
    }

    private func observeSettings() {
        cancellable = store.$configuration
            .dropFirst()
            .sink { [weak self] _ in
                // @Published emits before the stored configuration changes.
                DispatchQueue.main.async {
                    self?.syncEngine()
                    self?.refreshMenuState()
                }
            }
    }

    private func syncEngine() {
        if !store.configuration.enabled { executor.cancelPendingShortcut() }
        engine.update(
            enabled: store.configuration.enabled,
            threshold: CGFloat(store.configuration.threshold)
        )
        if store.configuration.enabled {
            engine.start()
        }
    }

    private func refreshMenuState() {
        let message: String
        switch listenerStatus {
        case .running: message = "手势正常"
        case .paused: message = "手势已暂停"
        case .faulted: message = "手势已暂停：输入监听异常"
        case .permissionMissing: message = "手势已暂停：需要辅助功能权限"
        }
        listenerStatusItem?.title = message
        statusItem?.button?.toolTip = "MouseGesture · " + message
        recoverItem?.isHidden = listenerStatus != .faulted
        enabledItem?.state = listenerStatus == .running ? .on : .off
        permissionItem?.state = AccessibilityPermission.isGranted ? .on : .off
        screenRecordingItem?.state = ScreenRecordingPermission.isGranted ? .on : .off
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func recoverListener() {
        guard AccessibilityPermission.isGranted else { openAccessibilityPermission(); return }
        executor.cancelPendingShortcut()
        updateForegroundSnapshot()
        store.configuration.enabled = true
        engine.recover()
    }

    @objc private func toggleEnabled() {
        store.configuration.enabled.toggle()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "鼠标手势设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: settingsContent)
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAccessibilityPermission() {
        if !AccessibilityPermission.isGranted {
            AccessibilityPermission.request()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenRecordingPermission() {
        if !ScreenRecordingPermission.isGranted {
            _ = ScreenRecordingPermission.request()
        }
        ScreenRecordingPermission.openSystemSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更新登录启动设置"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshMenuState()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}
