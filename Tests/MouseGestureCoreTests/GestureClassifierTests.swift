import CoreGraphics
import Foundation
import Testing

@testable import MouseGestureCore

@Suite
struct GestureClassifierTests {
    private let classifier = GestureClassifier(threshold: 8)

    private func point(degrees: CGFloat, length: CGFloat = 50) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: length * cos(radians), y: length * sin(radians))
    }

    @Test
    func testMovementBelowThresholdIsClick() {
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 0, y: -7)) == nil)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 5, y: 5)) == nil)
        #expect(GestureClassifier(threshold: 40).direction(from: .zero, to: CGPoint(x: 39, y: 0)) == nil)
    }

    @Test
    func testFourDirectionsShareOneDistance() {
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 0, y: -8)) == .up)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 0, y: 8)) == .down)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: -8, y: 0)) == .left)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 8, y: 0)) == .right)
    }

    @Test
    func testEverySectorIsFortyDegreesEitherSide() {
        // Screen y grows downward: 0° right, 90° down, 180° left, 270° up.
        for (axis, expected) in [(0.0, GestureDirection.right), (90, .down), (180, .left), (270, .up)] {
            for offset in [-39.5, -20, 0, 20, 39.5] {
                #expect(classifier.direction(from: .zero, to: point(degrees: axis + offset)) == expected)
            }
        }
    }

    @Test
    func testDiagonalsBetweenSectorsAreNotGestures() {
        for diagonal in [45.0, 135, 225, 315] {
            for offset in [-4.0, 0, 4] {
                #expect(classifier.direction(from: .zero, to: point(degrees: diagonal + offset)) == nil)
            }
        }
    }

    @Test
    func testRecordedNativeStrokesKeepTheirDirection() {
        // Real Deskflow strokes after the Windows gesture tool was disabled.
        for (offset, expected) in [
            (CGPoint(x: -2, y: -81), GestureDirection.up), (CGPoint(x: 8, y: -72), .up),
            (CGPoint(x: -3, y: -22), .up), (CGPoint(x: 2, y: -30), .up),
            (CGPoint(x: -17, y: 86), .down), (CGPoint(x: -15, y: 69), .down),
            (CGPoint(x: 0, y: 28), .down), (CGPoint(x: 18, y: 81), .down),
            (CGPoint(x: 149, y: 6), .right), (CGPoint(x: 144, y: 23), .right)
        ] {
            #expect(classifier.direction(from: .zero, to: offset) == expected)
        }
    }

    @Test
    func testGestureSurvivesMovementBackTowardStart() {
        var stroke = GestureStroke(start: .zero)
        stroke.record(CGPoint(x: 0, y: -30))
        stroke.record(CGPoint(x: 0, y: -8))
        #expect(stroke.direction(threshold: 21) == .up)

        var downwardStroke = GestureStroke(start: .zero)
        downwardStroke.record(CGPoint(x: 0, y: 30))
        downwardStroke.record(CGPoint(x: 0, y: 8))
        #expect(downwardStroke.direction(threshold: 21) == .down)
    }

    @Test
    func testShortMovementRemainsRightClick() {
        var stroke = GestureStroke(start: .zero)
        stroke.record(CGPoint(x: 0, y: -5))
        stroke.record(.zero)
        #expect(stroke.direction(threshold: 8) == nil)
    }
}

@Suite
struct ReplayedInputMonitorTests {
    @Test
    func nativeMouseNeverWarns() {
        var monitor = ReplayedInputMonitor()
        for second in 0..<10 {
            #expect(monitor.record(hold: 0, remoteSource: false, at: TimeInterval(second)) == nil)
        }
    }

    @Test
    func threeReplaysWarnAndARealPressClears() {
        var monitor = ReplayedInputMonitor()
        #expect(monitor.record(hold: 0.015, remoteSource: true, at: 1) == nil)
        #expect(monitor.record(hold: 0, remoteSource: true, at: 2) == nil)
        #expect(monitor.record(hold: 0.02, remoteSource: true, at: 3) == .warn(notify: true))
        #expect(monitor.record(hold: 0.01, remoteSource: true, at: 4) == nil)
        #expect(monitor.record(hold: 0.12, remoteSource: true, at: 5) == .clear)
        #expect(!monitor.isWarning)
    }

    @Test
    func spreadOutReplaysAndRealPressesDoNotWarn() {
        var monitor = ReplayedInputMonitor()
        #expect(monitor.record(hold: 0, remoteSource: true, at: 0) == nil)
        #expect(monitor.record(hold: 0, remoteSource: true, at: 100) == nil)
        #expect(monitor.record(hold: 0, remoteSource: true, at: 300) == nil)
        #expect(monitor.record(hold: 0.1, remoteSource: true, at: 301) == nil)
        #expect(monitor.record(hold: 0, remoteSource: true, at: 302) == nil)
    }

    @Test
    func repeatedWarningsNotifyAtMostEveryHalfHour() {
        var monitor = ReplayedInputMonitor()
        for time in [1.0, 2, 3] { _ = monitor.record(hold: 0, remoteSource: true, at: time) }
        _ = monitor.record(hold: 0.1, remoteSource: true, at: 4)
        for time in [5.0, 6] { _ = monitor.record(hold: 0, remoteSource: true, at: time) }
        #expect(monitor.record(hold: 0, remoteSource: true, at: 7) == .warn(notify: false))
        _ = monitor.record(hold: 0.1, remoteSource: true, at: 8)
        for time in [2_000.0, 2_001] { _ = monitor.record(hold: 0, remoteSource: true, at: time) }
        #expect(monitor.record(hold: 0, remoteSource: true, at: 2_002) == .warn(notify: true))
    }
}
