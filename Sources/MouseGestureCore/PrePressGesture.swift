import CoreGraphics
import Foundation

public struct MotionSample: Equatable, Sendable {
    public let time: TimeInterval
    public let point: CGPoint

    public init(time: TimeInterval, point: CGPoint) {
        self.time = time
        self.point = point
    }
}

/// Plain cursor movement seen while no right-button stroke is being tracked.
public struct RecentMotion: Sendable {
    public static let lookback: TimeInterval = 0.6
    private static let capacity = 128
    public private(set) var samples: [MotionSample] = []

    public init() {}

    public mutating func record(_ point: CGPoint, at time: TimeInterval) {
        samples.append(MotionSample(time: time, point: point))
        let oldest = time - Self.lookback
        if let keep = samples.firstIndex(where: { $0.time >= oldest }), keep > 0 {
            samples.removeFirst(keep)
        }
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    public mutating func removeAll() { samples.removeAll() }
}

/// Deskflow can deliver a held right-button stroke late: most of the motion
/// arrives as plain moves, then the press, a few drags and the release within
/// about 20 ms. The drags prove the button was held and give the direction;
/// the contiguous plain moves just before the press that continue that
/// direction supply the rest of the distance.
///
/// A short stroke can arrive with no drags at all: press and release in the
/// same millisecond right after the motion. An ordinary click arrives only
/// after the cursor has rested for the whole press (128 ms or more measured),
/// so a vertical run still moving within `maximumClickDelay` is a copy/paste.
/// Only a replayed click qualifies: its press and release arrive together
/// (0–3 ms measured). A real click is held far longer and stays a click.
///
/// Recovery applies only to replayed strokes (held 8–25 ms measured). A real
/// press is held 96 ms or more, and its own drags decide the gesture as on a
/// native mouse, so earlier positioning never lengthens it.
public enum PrePressGesture {
    /// Measured Deskflow pause between the last plain move and the press: 24–64 ms.
    public static let maximumPressDelay: TimeInterval = 0.1
    /// Deskflow forwards moves about every 8 ms; a longer pause ends the stroke.
    public static let maximumSampleGap: TimeInterval = 0.06
    /// Measured short Deskflow strokes without drags: 0–58 ms after the last move.
    public static let maximumClickDelay: TimeInterval = 0.07
    public static let maximumReplayedHold: TimeInterval = 0.01
    public static let maximumReplayedStroke: TimeInterval = 0.05
    private static let anchorSpan: TimeInterval = 0.05
    private static let minimumTailDistance: CGFloat = 3

    public static func direction(
        before samples: [MotionSample], pressedAt: TimeInterval, press: CGPoint,
        drags: [CGPoint], release: CGPoint, releasedAt: TimeInterval, threshold: CGFloat
    ) -> GestureDirection? {
        guard releasedAt - pressedAt <= maximumReplayedStroke else { return nil }
        let tailOffset: CGPoint
        if drags.isEmpty {
            // Direction from the final 50 ms of motion before the click.
            guard releasedAt - pressedAt <= maximumReplayedHold,
                  let last = samples.last(where: { $0.time <= pressedAt }),
                  pressedAt - last.time <= maximumClickDelay,
                  let anchor = samples.first(where: { $0.time >= last.time - anchorSpan && $0.time <= last.time })
            else { return nil }
            tailOffset = CGPoint(x: press.x - anchor.point.x, y: press.y - anchor.point.y)
            guard abs(tailOffset.y) > abs(tailOffset.x) else { return nil }
        } else {
            var tail = GestureStroke(start: press)
            for point in drags { tail.record(point) }
            tail.record(release)
            tailOffset = tail.furthestDisplacement
        }
        guard hypot(tailOffset.x, tailOffset.y) >= minimumTailDistance else { return nil }

        let vertical = abs(tailOffset.y) >= abs(tailOffset.x)
        let sign: CGFloat = (vertical ? tailOffset.y : tailOffset.x) < 0 ? -1 : 1
        func along(_ v: CGPoint) -> CGFloat { (vertical ? v.y : v.x) * sign }
        func across(_ v: CGPoint) -> CGFloat { abs(vertical ? v.x : v.y) }

        var start = press
        var newerTime = pressedAt
        var accepted: [CGPoint] = []
        for sample in samples.reversed() where sample.time <= pressedAt {
            let limit = accepted.isEmpty ? (drags.isEmpty ? maximumClickDelay : maximumPressDelay) : maximumSampleGap
            guard newerTime - sample.time <= limit,
                  pressedAt - sample.time <= RecentMotion.lookback else { break }
            let step = CGPoint(x: start.x - sample.point.x, y: start.y - sample.point.y)
            let forward = along(step)
            guard forward >= -1, across(step) <= max(forward, 0) + 1 else { break }
            accepted.append(sample.point)
            start = sample.point
            newerTime = sample.time
        }
        guard !accepted.isEmpty else { return nil }

        var stroke = GestureStroke(start: start)
        for point in accepted.reversed() { stroke.record(point) }
        stroke.record(press)
        for point in drags { stroke.record(point) }
        stroke.record(release)
        guard let direction = stroke.direction(threshold: threshold) else { return nil }
        let expected: GestureDirection = vertical ? (sign < 0 ? .up : .down) : (sign < 0 ? .left : .right)
        return direction == expected ? direction : nil
    }
}
