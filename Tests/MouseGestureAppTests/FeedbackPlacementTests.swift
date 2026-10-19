import CoreGraphics
import Testing
@testable import MouseGestureApp

@MainActor
struct FeedbackPlacementTests {
    private let size = CGSize(width: 40, height: 18)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func verticalStrokeHintSitsRightOfCursor() {
        let frame = GestureFeedbackOverlay.frame(size: size, cursor: CGPoint(x: 500, y: 400),
                                                 placement: .beside, visible: screen)
        #expect(frame.minX == 524)
        #expect(frame.midY == 400)
    }

    @Test func horizontalStrokeHintSitsBelowCursor() {
        let frame = GestureFeedbackOverlay.frame(size: size, cursor: CGPoint(x: 500, y: 400),
                                                 placement: .below, visible: screen)
        #expect(frame.maxY == 376)
        #expect(frame.midX == 500)
    }

    @Test func hintFlipsAwayFromScreenEdges() {
        let left = GestureFeedbackOverlay.frame(size: size, cursor: CGPoint(x: 980, y: 400),
                                                placement: .beside, visible: screen)
        #expect(left.maxX == 956)
        let above = GestureFeedbackOverlay.frame(size: size, cursor: CGPoint(x: 500, y: 20),
                                                 placement: .below, visible: screen)
        #expect(above.minY == 44)
    }

    @Test func hintStaysOnSecondaryScreen() {
        let secondary = CGRect(x: -1200, y: 100, width: 1200, height: 700)
        let frame = GestureFeedbackOverlay.frame(size: size, cursor: CGPoint(x: -1190, y: 795),
                                                 placement: .beside, visible: secondary)
        #expect(secondary.contains(frame))
        #expect(frame.minX == -1166)
    }
}
