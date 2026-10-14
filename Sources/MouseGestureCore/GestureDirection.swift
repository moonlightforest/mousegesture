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

    /// Classifies displacement by its dominant axis, with a wider rightward
    /// sector for window switching (56 degrees upward, 70 degrees downward).
    public func direction(from start: CGPoint, to end: CGPoint) -> GestureDirection? {
        let dx = end.x - start.x
        let dy = end.y - start.y

        guard hypot(dx, dy) >= threshold else { return nil }

        // Rightward window switching accepts moderate diagonal drift. Keep
        // predominantly vertical strokes available for copy and paste.
        if dx > 0 {
            if dy >= 0, !Self.isWithinDownSector(dx: dx, dy: dy) { return .right }
            if dy < 0, dx * 1.5 >= abs(dy) { return .right }
        }

        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? (Self.isWithinDownSector(dx: dx, dy: dy) ? .down : nil) : .up
    }
    public static func isWithinDownSector(dx: CGFloat, dy: CGFloat) -> Bool {
        dy > 0 && abs(dx) <= dy * tan(20 * .pi / 180)
    }
}

/// Remembers the furthest point reached while the right button is held. A
/// short movement back toward the starting point must not erase a gesture.
public struct GestureStroke: Sendable {
    public let start: CGPoint
    private var furthest: CGPoint
    private var horizontalPeak: CGPoint
    private var verticalPeak: CGPoint

    public var furthestDisplacement: CGPoint {
        CGPoint(x: furthest.x - start.x, y: furthest.y - start.y)
    }

    public var axisPeakDisplacement: CGPoint {
        CGPoint(x: horizontalPeak.x - start.x, y: verticalPeak.y - start.y)
    }

    public init(start: CGPoint) {
        self.start = start
        self.furthest = start
        self.horizontalPeak = start
        self.verticalPeak = start
    }

    public mutating func record(_ point: CGPoint) {
        if abs(point.x - start.x) > abs(horizontalPeak.x - start.x) {
            horizontalPeak = point
        }
        if abs(point.y - start.y) > abs(verticalPeak.y - start.y) {
            verticalPeak = point
        }
        if hypot(point.x - start.x, point.y - start.y)
            > hypot(furthest.x - start.x, furthest.y - start.y)
        {
            furthest = point
        }
    }

    public func direction(threshold: CGFloat) -> GestureDirection? {
        GestureClassifier(threshold: threshold).direction(from: start, to: furthest)
    }

    /// Keep an early, clearly established axis when later drift only slightly
    /// exceeds it. A movement more than twice as large on the other axis can
    /// still correct an accidental initial direction.
    public func direction(threshold: CGFloat, preferring first: GestureDirection?) -> GestureDirection? {
        let ordinary = direction(threshold: threshold)
        guard let first, ordinary != nil else { return ordinary }
        let peak = axisPeakDisplacement
        switch first {
        case .left, .right:
            let sameSign = first == .right ? peak.x > 0 : peak.x < 0
            return sameSign && abs(peak.x) >= threshold && abs(peak.y) <= 2 * abs(peak.x)
                ? first : ordinary
        case .down:
            return ordinary
        case .up:
            let sameSign = first == .down ? peak.y > 0 : peak.y < 0
            return sameSign && abs(peak.y) >= threshold && abs(peak.x) <= 2 * abs(peak.y)
                ? first : ordinary
        }
    }
}

/// Allows a deliberately short vertical drag without making a single noisy
/// mouse movement count as a gesture. The ordinary classifier still takes
/// precedence when the configured threshold is reached.
public struct ShortVerticalStroke: Sendable {
    private let start: CGPoint
    private var previous: CGPoint
    private var streakDirection: GestureDirection?
    private var streakCount = 0
    private var candidateOffset = CGPoint.zero
    private var maximumHorizontalDistance: CGFloat = 0

    public init(start: CGPoint) {
        self.start = start
        self.previous = start
    }

    public static func minimumDistance(for threshold: CGFloat) -> CGFloat {
        min(max(5, threshold - 3), max(1, threshold))
    }

    public static func minimumUpDistance(for threshold: CGFloat) -> CGFloat {
        min(3, max(1, threshold))
    }

    public mutating func recordDrag(_ point: CGPoint) {
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        previous = point
        let offset = CGPoint(x: point.x - start.x, y: point.y - start.y)
        maximumHorizontalDistance = max(maximumHorizontalDistance, abs(offset.x))

        guard abs(dy) >= 1, abs(dy) >= abs(dx) else {
            streakDirection = nil
            streakCount = 0
            return
        }

        let direction: GestureDirection = dy < 0 ? .up : .down
        streakCount = direction == streakDirection ? streakCount + 1 : 1
        streakDirection = direction

        guard (direction == .up || streakCount >= 2), abs(offset.y) >= abs(offset.x),
              abs(offset.y) > abs(candidateOffset.y)
        else { return }
        candidateOffset = offset
    }

    public func direction(threshold: CGFloat) -> GestureDirection? {
        let minimum = candidateOffset.y < 0 ? Self.minimumUpDistance(for: threshold) : Self.minimumDistance(for: threshold)
        guard abs(candidateOffset.y) >= minimum,
              abs(candidateOffset.y) >= 1.5 * maximumHorizontalDistance
        else { return nil }
        if candidateOffset.y > 0, !GestureClassifier.isWithinDownSector(
            dx: maximumHorizontalDistance, dy: candidateOffset.y
        ) { return nil }
        return candidateOffset.y < 0 ? .up : .down
    }
}
