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
    private let executor = ActionExecutor()
    var settingsContent: SettingsView { SettingsView(store: store) }
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var enabledItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var screenRecordingItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var cancellable: AnyCancellable?
    private var appActivationObserver: NSObjectProtocol?

    private lazy var engine = GestureEngine(captureShortcutTarget: { [weak self] in
        // GestureEngine's event source is installed on CFRunLoopGetMain().
        MainActor.assumeIsolated {
            guard let self else { return Task { nil } }
            return self.executor.captureShortcutTarget()
        }
    }) { [weak self] direction, location, target in
        guard let self else { return }
        let action = self.store.action(for: direction)
        self.executor.execute(action, gestureLocation: location, shortcutTarget: target)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.notice("Gesture input revision 11: late vertical motion and same-app focus recovery")
        appLogger.notice(
            "Permissions accessibility=\(AccessibilityPermission.isGranted) screenRecording=\(ScreenRecordingPermission.isGranted)"
        )
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        observeSettings()
        syncEngine()
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
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
        engine.stop()
        executor.restoreWindowLevels()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
        if AccessibilityPermission.isGranted { _ = engine.start() }
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
                self?.syncEngine()
                self?.refreshMenuState()
            }
    }

    private func syncEngine() {
        if !store.configuration.enabled { executor.cancelPendingShortcut() }
        engine.update(
            enabled: store.configuration.enabled,
            threshold: CGFloat(store.configuration.threshold)
        )
        if store.configuration.enabled, AccessibilityPermission.isGranted {
            _ = engine.start()
        }
    }

    private func refreshMenuState() {
        enabledItem?.state = store.configuration.enabled ? .on : .off
        permissionItem?.state = AccessibilityPermission.isGranted ? .on : .off
        screenRecordingItem?.state = ScreenRecordingPermission.isGranted ? .on : .off
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
