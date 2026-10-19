import AppKit
import MouseGestureCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var showingToggleRecorder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("手势设置")
                .font(.title2.bold())

            VStack(spacing: 12) {
                ForEach(GestureDirection.allCases) { direction in
                    ActionRow(store: store, direction: direction)
                }
            }

            Divider()

            HStack(spacing: 14) {
                Text("移动阈值")
                    .frame(width: 76, alignment: .leading)
                Slider(value: thresholdBinding, in: 8...100, step: 1)
                Text("\(Int(store.configuration.threshold)) pt")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }

            Text("按住右键移动达到阈值并释放后执行动作。四个方向使用相同的阈值，各自接受偏离方向左右 \(Int(GestureClassifier.sectorHalfAngle))° 以内的移动；斜向夹在两个方向之间时不触发。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("识别后在起点附近显示提示", isOn: showsFeedbackBinding)

            HStack(spacing: 14) {
                Text("暂停/启用快捷键")
                Button(ShortcutFormatter.display(store.configuration.toggleShortcut) ?? "录制…") {
                    showingToggleRecorder = true
                }
                .sheet(isPresented: $showingToggleRecorder) {
                    ShortcutRecorderSheet(
                        initialShortcut: store.configuration.toggleShortcut,
                        isPresented: $showingToggleRecorder
                    ) { store.configuration.toggleShortcut = $0 }
                }
                if store.configuration.toggleShortcut != GestureConfiguration.defaultToggleShortcut {
                    Button("恢复默认") {
                        store.configuration.toggleShortcut = GestureConfiguration.defaultToggleShortcut
                    }
                }
            }

            Divider()

            ExcludedApplicationsSection(store: store)
        }
        .padding(24)
        .frame(width: 560)
    }

    private var showsFeedbackBinding: Binding<Bool> {
        Binding(
            get: { store.configuration.showsFeedback },
            set: { store.configuration.showsFeedback = $0 }
        )
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { store.configuration.threshold },
            set: { store.configuration.threshold = $0 }
        )
    }
}

private struct ActionRow: View {
    @ObservedObject var store: SettingsStore
    let direction: GestureDirection

    private var showingShortcutRecorder = State(initialValue: false)

    var body: some View {
        HStack(spacing: 12) {
            Text(direction.symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 26)
            Text(direction.localizedName)
                .frame(width: 54, alignment: .leading)

            Picker("", selection: actionKindBinding) {
                ForEach(GestureActionKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .frame(minWidth: 220)

            accessory
                .frame(width: 145, alignment: .leading)
        }
    }

    @ViewBuilder
    private var accessory: some View {
        let action = store.action(for: direction)
        switch action.kind {
        case .launchApplication:
            Button(applicationName(action.applicationPath)) {
                chooseApplication()
            }
            .lineLimit(1)
        case .keyboardShortcut:
            Button(ShortcutFormatter.display(action.shortcut) ?? "录制…") {
                showingShortcutRecorder.wrappedValue = true
            }
            .sheet(isPresented: showingShortcutRecorder.projectedValue) {
                ShortcutRecorderSheet(
                    initialShortcut: action.shortcut,
                    isPresented: showingShortcutRecorder.projectedValue
                ) { shortcut in
                    var updated = store.action(for: direction)
                    updated.shortcut = shortcut
                    store.setAction(updated, for: direction)
                }
            }
        default:
            EmptyView()
        }
    }

    private var actionKindBinding: Binding<GestureActionKind> {
        Binding(
            get: { store.action(for: direction).kind },
            set: { kind in
                let oldAction = store.action(for: direction)
                let newAction: GestureAction
                if oldAction.kind == kind {
                    newAction = oldAction
                } else {
                    newAction = GestureAction(kind: kind)
                }
                store.setAction(newAction, for: direction)
            }
        )
    }

    private func applicationName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "选择 App…" }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择要启动的 App"
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var action = store.action(for: direction)
        action.applicationPath = url.path
        store.setAction(action, for: direction)
    }
}

private struct ShortcutRecorderSheet: View {
    private var shortcut: State<RecordedShortcut?>

    let isPresented: Binding<Bool>
    let onSave: (RecordedShortcut) -> Void

    init(
        initialShortcut: RecordedShortcut?,
        isPresented: Binding<Bool>,
        onSave: @escaping (RecordedShortcut) -> Void
    ) {
        shortcut = State(initialValue: initialShortcut)
        self.isPresented = isPresented
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("录制快捷键")
                .font(.headline)
            Text("直接按下要使用的组合键")
                .foregroundStyle(.secondary)

            Text(ShortcutFormatter.display(shortcut.wrappedValue) ?? "等待输入…")
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            KeyCaptureView { event in
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                shortcut.wrappedValue = RecordedShortcut(
                    keyCode: event.keyCode,
                    modifierRawValue: UInt64(modifiers.rawValue)
                )
            }
            .frame(width: 1, height: 1)

            HStack {
                Button("取消") { isPresented.wrappedValue = false }
                Spacer()
                Button("保存") {
                    if let shortcut = shortcut.wrappedValue { onSave(shortcut) }
                    isPresented.wrappedValue = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(shortcut.wrappedValue == nil)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onKeyDown = onKeyDown
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }
}

private final class CaptureNSView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }
}

enum ShortcutFormatter {
    static func display(_ shortcut: RecordedShortcut?) -> String? {
        guard let shortcut else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(shortcut.modifierRawValue))
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += keyName(for: shortcut.keyCode)
        return result
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
            17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=",
            25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U",
            33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K",
            41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥",
            49: "Space", 50: "`", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

/// Applications in which right-button input is passed through untouched.
private struct ExcludedApplicationsSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("停用手势的应用")
                Spacer()
                Button("添加应用…", action: addApplication)
            }
            if store.configuration.excludedBundleIdentifiers.isEmpty {
                Text("这些应用在前台时，右键保持原样，不识别手势。也可以在菜单栏选择“在「应用名」中停用手势”。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.configuration.excludedBundleIdentifiers, id: \.self) { bundleIdentifier in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(for: bundleIdentifier))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(Self.name(for: bundleIdentifier))
                        Spacer()
                        Button("移除") {
                            store.configuration.setExcluded(false, bundleIdentifier: bundleIdentifier)
                        }
                    }
                }
            }
        }
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "停用手势"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { continue }
            store.configuration.setExcluded(true, bundleIdentifier: bundleIdentifier)
        }
    }

    private static func applicationURL(for bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private static func name(for bundleIdentifier: String) -> String {
        guard let url = applicationURL(for: bundleIdentifier) else { return bundleIdentifier }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func icon(for bundleIdentifier: String) -> NSImage {
        guard let url = applicationURL(for: bundleIdentifier) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
