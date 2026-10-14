import CoreGraphics
import Testing
@testable import MouseGestureCore

struct RecoveryTests {
    @Test func lateMovementRecoversAllThreeActions() {
        for (points, expected) in [
            ([CGPoint(x: 0, y: -2), CGPoint(x: 0, y: -3)], GestureDirection.up),
            ([CGPoint(x: 0, y: 2), CGPoint(x: 1, y: 5)], .down),
            ([CGPoint(x: 5, y: 1), CGPoint(x: 9, y: 2)], .right)
        ] {
            var stroke = GestureStroke(start: .zero)
            var short = ShortVerticalStroke(start: .zero)
            for point in points { stroke.record(point); short.recordDrag(point) }
            #expect(PostReleaseGesture.direction(stroke: stroke, shortStroke: short,
                moveCount: 2, threshold: 8) == expected)
            #expect(PostReleaseGesture.direction(stroke: stroke, shortStroke: short,
                moveCount: 1, threshold: 8) == nil)
        }
    }
    @Test func lateRecoveryRejectsClickJitterAndLeftSwipe() {
        for points in [[CGPoint.zero, CGPoint.zero], [CGPoint(x: 0, y: -1), CGPoint(x: 0, y: -2)],
                       [CGPoint(x: -5, y: 0), CGPoint(x: -10, y: 0)]] {
            var stroke = GestureStroke(start: .zero)
            var short = ShortVerticalStroke(start: .zero)
            for point in points { stroke.record(point); short.recordDrag(point) }
            #expect(PostReleaseGesture.direction(stroke: stroke, shortStroke: short,
                moveCount: 2, threshold: 8) == nil)
        }
    }
    @Test func missingWindowRequiresStableOriginalApplication() {
        #expect(!ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 11,
            capturedWindowMatches: nil, recoveredWindowStable: true))
        #expect(!ClipboardFocusPolicy.canSend(originalPID: -1, currentPID: -1,
            capturedWindowMatches: true, recoveredWindowStable: true))
        #expect(!ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 10,
            capturedWindowMatches: nil, recoveredWindowStable: false))
        #expect(ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 10,
            capturedWindowMatches: nil, recoveredWindowStable: true))
        #expect(!ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 10,
            capturedWindowMatches: false, recoveredWindowStable: true))
        #expect(ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 10,
            capturedWindowMatches: true, recoveredWindowStable: false))
    }
}
