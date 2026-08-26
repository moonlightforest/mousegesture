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
    func testFourDirections() {
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 0, y: -50)) == .up)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 0, y: 50)) == .down)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: -50, y: 0)) == .left)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 50, y: 0)) == .right)
    }

    @Test
    func testDiagonalMovementUsesDominantAxis() {
        #expect(classifier.direction(from: .zero, to: CGPoint(x: 60, y: -45)) == .right)
        #expect(classifier.direction(from: .zero, to: CGPoint(x: -45, y: 60)) == .down)
    }
}
