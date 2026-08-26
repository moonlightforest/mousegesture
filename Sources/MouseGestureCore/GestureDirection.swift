import CoreGraphics
import Foundation

public enum GestureDirection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case up
    case down
    case left
    case right

    public var id: Self { self }

    public var symbol: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }

    public var localizedName: String {
        switch self {
        case .up: "上滑"
        case .down: "下滑"
        case .left: "左滑"
        case .right: "右滑"
        }
    }
}

public struct GestureClassifier: Sendable {
    public var threshold: CGFloat

    public init(threshold: CGFloat) {
        self.threshold = max(1, threshold)
    }

    /// Classifies the displacement into one of four 90-degree sectors. This
    /// deliberately accepts diagonal movement instead of demanding a perfectly
    /// horizontal or vertical stroke.
    public func direction(from start: CGPoint, to end: CGPoint) -> GestureDirection? {
        let dx = end.x - start.x
        let dy = end.y - start.y

        guard hypot(dx, dy) >= threshold else { return nil }

        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .down : .up
    }
}
