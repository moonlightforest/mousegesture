import Foundation

public enum GestureActionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case copy
    case paste
    case previousWindow
    case toggleAlwaysOnTop
    case appSwitcher
    case screenshotSelection
    case screenshotFull
    case launchApplication
    case keyboardShortcut

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .none: "无动作"
        case .copy: "复制"
        case .paste: "粘贴"
        case .previousWindow: "激活前一个窗口"
        case .toggleAlwaysOnTop: "切换窗口置顶"
        case .appSwitcher: "切换 App (⌘Tab)"
        case .screenshotSelection: "区域截图 (⇧⌘4)"
        case .screenshotFull: "全屏截图 (⇧⌘3)"
        case .launchApplication: "启动指定 App"
        case .keyboardShortcut: "自定义快捷键"
        }
    }
}

public struct RecordedShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifierRawValue: UInt64

    public init(keyCode: UInt16, modifierRawValue: UInt64) {
        self.keyCode = keyCode
        self.modifierRawValue = modifierRawValue
    }
}

public struct GestureAction: Codable, Equatable, Sendable {
    public var kind: GestureActionKind
    public var shortcut: RecordedShortcut?
    public var applicationPath: String?

    public init(
        kind: GestureActionKind,
        shortcut: RecordedShortcut? = nil,
        applicationPath: String? = nil
    ) {
        self.kind = kind
        self.shortcut = shortcut
        self.applicationPath = applicationPath
    }
}

public struct GestureConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var threshold: Double
    public var actions: [GestureDirection: GestureAction]

    public init(
        enabled: Bool = true,
        threshold: Double = 40,
        actions: [GestureDirection: GestureAction] = Self.betterTouchToolDefaults
    ) {
        self.enabled = enabled
        self.threshold = threshold
        self.actions = actions
    }

    public static let betterTouchToolDefaults: [GestureDirection: GestureAction] = [
        .up: GestureAction(kind: .copy),
        .down: GestureAction(kind: .paste),
        .left: GestureAction(kind: .toggleAlwaysOnTop),
        .right: GestureAction(kind: .previousWindow)
    ]
}
