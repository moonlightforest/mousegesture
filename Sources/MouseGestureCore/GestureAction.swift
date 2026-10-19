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
    /// Show a brief hint near the stroke once a gesture is recognized.
    public var showsFeedback: Bool
    /// Global shortcut that toggles `enabled`.
    public var toggleShortcut: RecordedShortcut
    /// Bundle identifiers of applications in which right-button input is
    /// left untouched while they are frontmost.
    public var excludedBundleIdentifiers: [String]

    public init(
        enabled: Bool = true,
        threshold: Double = 40,
        actions: [GestureDirection: GestureAction] = Self.betterTouchToolDefaults,
        showsFeedback: Bool = true,
        toggleShortcut: RecordedShortcut = Self.defaultToggleShortcut,
        excludedBundleIdentifiers: [String] = []
    ) {
        self.enabled = enabled
        self.threshold = threshold
        self.actions = actions
        self.showsFeedback = showsFeedback
        self.toggleShortcut = toggleShortcut
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, threshold, actions, showsFeedback, toggleShortcut, excludedBundleIdentifiers
    }

    /// Fields added after the first release fall back to their defaults so
    /// saved configurations keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        threshold = try container.decode(Double.self, forKey: .threshold)
        actions = try container.decode([GestureDirection: GestureAction].self, forKey: .actions)
        showsFeedback = try container.decodeIfPresent(Bool.self, forKey: .showsFeedback) ?? true
        toggleShortcut = try container.decodeIfPresent(RecordedShortcut.self, forKey: .toggleShortcut)
            ?? Self.defaultToggleShortcut
        excludedBundleIdentifiers = try container.decodeIfPresent(
            [String].self, forKey: .excludedBundleIdentifiers) ?? []
    }

    public func excludes(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedBundleIdentifiers.contains(bundleIdentifier)
    }

    public mutating func setExcluded(_ excluded: Bool, bundleIdentifier: String) {
        excludedBundleIdentifiers.removeAll { $0 == bundleIdentifier }
        if excluded { excludedBundleIdentifiers.append(bundleIdentifier) }
    }

    /// ⌃⌥⌘G, stored with `NSEvent.ModifierFlags` raw values like recorded shortcuts.
    public static let defaultToggleShortcut = RecordedShortcut(
        keyCode: 5, modifierRawValue: (1 << 18) | (1 << 19) | (1 << 20))

    public static let betterTouchToolDefaults: [GestureDirection: GestureAction] = [
        .up: GestureAction(kind: .copy),
        .down: GestureAction(kind: .paste),
        .left: GestureAction(kind: .toggleAlwaysOnTop),
        .right: GestureAction(kind: .previousWindow)
    ]
}
