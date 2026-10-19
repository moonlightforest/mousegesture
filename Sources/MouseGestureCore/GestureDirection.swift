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
    /// Each direction accepts this many degrees either side of its axis,
    /// leaving a 10 degree gap on both sides of every diagonal. Recorded
    /// strokes stay within 13 degrees of their axis.
    public static let sectorHalfAngle: CGFloat = 40

    public var threshold: CGFloat

    public init(threshold: CGFloat) {
        self.threshold = max(1, threshold)
    }

    /// The same distance and angle rule for all four directions; a diagonal
    /// between two sectors is not a gesture.
    public func direction(from start: CGPoint, to end: CGPoint) -> GestureDirection? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard hypot(dx, dy) >= threshold else { return nil }

        let horizontal = abs(dx) >= abs(dy)
        let offAxis = atan2(horizontal ? abs(dy) : abs(dx), horizontal ? abs(dx) : abs(dy)) * 180 / .pi
        guard offAxis <= Self.sectorHalfAngle else { return nil }
        if horizontal { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
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
}
