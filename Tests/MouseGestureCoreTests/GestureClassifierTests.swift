import CoreGraphics
import Testing

@testable import MouseGestureCore

@Suite
struct GestureClassifierTests {
    private let classifier = GestureClassifier(threshold: 40)

    @Test
    func testMovementBelowThresholdIsClick() {
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 20, y: 20)) == nil)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 39, y: 0)) == nil)
    }

    @Test
    func testNarrowPasteAndSingleShortCopy() {
        let classifier = GestureClassifier(threshold: 8)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 3, y: 10)) == .down)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: -4, y: 10)) == nil)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 4, y: 10)) == .right)
        var copy = ShortVerticalStroke(start: .zero)
        copy.recordDrag(CGPoint(x: 0, y: -2))
        #expect(copy.direction(threshold: 8) == nil)
        copy.recordDrag(CGPoint(x: 1, y: -3))
        #expect(copy.direction(threshold: 8) == .up)
        var single = ShortVerticalStroke(start: .zero)
        single.recordDrag(CGPoint(x: 0, y: -3))
        #expect(single.direction(threshold: 8) == .up)
        var slantedPaste = ShortVerticalStroke(start: .zero)
        slantedPaste.recordDrag(CGPoint(x: 1, y: 2))
        slantedPaste.recordDrag(CGPoint(x: 2, y: 5))
        #expect(slantedPaste.direction(threshold: 8) == nil)
    }

    @Test
    func testFourDirections() {
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 0, y: -50)) == .up)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 0, y: 50)) == .down)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: -50, y: 0)) == .left)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 50, y: 0)) == .right)
    }

    @Test
    func testDiagonalMovementUsesDominantAxis() {
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 60, y: -45)) == .right)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: -45, y: 60)) == nil)
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
        stroke.record(CGPoint(x: 0, y: -20))
        stroke.record(.zero)
        #expect(stroke.direction(threshold: 21) == nil)
    }

    @Test
    func testTwoShortVerticalDragsTriggerBeforeOrdinaryThreshold() {
        var downward = ShortVerticalStroke(start: .zero)
        downward.recordDrag(CGPoint(x: 0, y: 2))
        #expect(downward.direction(threshold: 8) == nil)
        downward.recordDrag(CGPoint(x: 1, y: 5))
        #expect(downward.direction(threshold: 8) == .down)

        var upward = ShortVerticalStroke(start: .zero)
        upward.recordDrag(CGPoint(x: -1, y: -2))
        upward.recordDrag(CGPoint(x: -1, y: -6))
        #expect(upward.direction(threshold: 8) == .up)
    }

    @Test
    func testShortVerticalRuleRejectsJitterAndSidewaysMotion() {
        var singleMove = ShortVerticalStroke(start: .zero)
        singleMove.recordDrag(CGPoint(x: 0, y: 7))
        #expect(singleMove.direction(threshold: 8) == nil)

        var reversal = ShortVerticalStroke(start: .zero)
        reversal.recordDrag(CGPoint(x: 0, y: 3))
        reversal.recordDrag(CGPoint(x: 0, y: 1))
        #expect(reversal.direction(threshold: 8) == nil)

        var sideways = ShortVerticalStroke(start: .zero)
        sideways.recordDrag(CGPoint(x: 4, y: 2))
        sideways.recordDrag(CGPoint(x: 8, y: 4))
        #expect(sideways.direction(threshold: 8) == nil)

        var tooShort = ShortVerticalStroke(start: .zero)
        tooShort.recordDrag(CGPoint(x: 0, y: 2))
        tooShort.recordDrag(CGPoint(x: 0, y: 4))
        #expect(tooShort.direction(threshold: 8) == nil)

        var laterRightwardMotion = ShortVerticalStroke(start: .zero)
        laterRightwardMotion.recordDrag(CGPoint(x: 0, y: 2))
        laterRightwardMotion.recordDrag(CGPoint(x: 0, y: 6))
        laterRightwardMotion.recordDrag(CGPoint(x: 6, y: 6))
        #expect(laterRightwardMotion.direction(threshold: 8) == nil)
    }

    @Test
    func testInitialRightDirectionSurvivesModerateLaterVerticalDrift() {
        var stroke = GestureStroke(start: .zero)
        stroke.record(CGPoint(x: 20, y: 1))
        stroke.record(CGPoint(x: 0, y: 30))
        #expect(stroke.direction(threshold: 8) == .down)
        #expect(stroke.axisPeakDisplacement == CGPoint(x: 20, y: 30))
        #expect(stroke.direction(threshold: 8, preferring: .right) == .right)

        stroke.record(CGPoint(x: 0, y: 45))
        #expect(stroke.direction(threshold: 8, preferring: .right) == .down)
    }

    @Test
    func testPostReleaseRecoveryNeedsClearRightMotion() {
        #expect(!PostReleaseRightSwipe.isRecognized(
            axisPeak: .zero, moveCount: 0, ordinaryThreshold: 8
        ))
        #expect(!PostReleaseRightSwipe.isRecognized(
            axisPeak: CGPoint(x: 15, y: 0), moveCount: 1, ordinaryThreshold: 8
        ))
        #expect(PostReleaseRightSwipe.isRecognized(
            axisPeak: CGPoint(x: 18, y: 5), moveCount: 2, ordinaryThreshold: 8
        ))
        #expect(PostReleaseRightSwipe.isRecognized(
            axisPeak: CGPoint(x: 18, y: 14), moveCount: 2, ordinaryThreshold: 8
        ))
        #expect(!PostReleaseRightSwipe.isRecognized(
            axisPeak: CGPoint(x: 0, y: 35), moveCount: 3, ordinaryThreshold: 8
        ))
    }

    @Test
    func testDiagonalRightSwipeUsesSameRuleForFastAndOrdinaryInput() {
        let classifier = GestureClassifier(threshold: 8)
        for dy in [-12.0, -8.0, 8.0, 12.0] {
            let offset = CGPoint(x: 8, y: dy)
            #expect(classifier.direction(from: .zero, to: offset) == .right)
            #expect(PostReleaseRightSwipe.isRecognized(
                axisPeak: offset, moveCount: 2, ordinaryThreshold: 8
            ))
        }
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 8, y: 13)) == .right)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 8, y: -13)) == .up)
        #expect(PostReleaseRightSwipe.isRecognized(
            axisPeak: CGPoint(x: 8, y: 13), moveCount: 2, ordinaryThreshold: 8
        ))
        #expect(!PostReleaseRightSwipe.isRecognized(
            axisPeak: CGPoint(x: 4, y: 3), moveCount: 2, ordinaryThreshold: 8
        ))
    }

    @Test
    func testRightDownAndPasteSectorsMeetWithoutGap() {
        let classifier = GestureClassifier(threshold: 8)
        for degrees in [57.0, 60.0, 66.0, 69.9, 70.1, 75.0, 90.0] {
            let radians = degrees * .pi / 180
            let point = CGPoint(x: 20 * cos(radians), y: 20 * sin(radians))
            let expected: GestureDirection = degrees < 70 ? .right : .down
            #expect(classifier.direction(from: .zero, to: point) == expected)
            #expect(PostReleaseRightSwipe.isRecognized(
                axisPeak: point, moveCount: 2, ordinaryThreshold: 8
            ) == (expected == .right))
        }
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 8, y: -13)) == .up)
    }
}
